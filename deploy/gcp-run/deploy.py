#!/usr/bin/env python3
"""Release the already commissioned staging Cloud Run installation, failing closed.

No IAM, secret, DNS, SQL-instance or scheduler creation. Tokens and HTTP payloads
stay in memory. Initial seed, restore/performance acceptance and first public
cutover remain explicit operator operations; this is the subsequent CI path.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.parse

import registry
import release
import render

ROOT = Path(__file__).resolve().parents[2]
DEPLOY_ACCOUNT = "nextstop-staging-deploy@nextstop-tech-testing.iam.gserviceaccount.com"
OPERATOR_GATES = {
    "clientIPIsolationPassed": ["backend/src/api/cloud-gateway.ts", "backend/src/gateway-server.ts", "backend/src/runtime/cloud-identity-tokens.ts"],
    "filteredBackupRestorePassed": ["backend/src/jobs/database-backup.ts", "backend/operations/*.sql", "backend/migrations/*.sql", "backend/src/persistence/database.ts", "deploy/gcp-run/database-*.sql"],
    "jobsBudgetVerified": ["backend/src/jobs/*.ts", "backend/src/providers/**/*.ts", "backend/migrations/0018_monthly_import_budget.sql"],
    "liveTaskCompatibilityPassed": ["backend/src/application/cloud-tasks-refresh-signal.ts", "backend/src/jobs/cloud-live-refresh.ts", "backend/src/live-refresh-server.ts", "backend/src/persistence/live-refresh-control.ts"],
    "idleScaleToZeroPassed": ["backend/src/server.ts", "backend/src/auth-server.ts", "backend/src/runtime/*.ts", "backend/src/jobs/*.ts"],
    "databasePerformancePassed": ["backend/src/persistence/*.ts", "backend/migrations/*.sql", "backend/src/jobs/*.ts", "backend/src/providers/**/*.ts"],
}
COMMON_SOURCES = ["backend/package.json", "backend/package-lock.json", "backend/Dockerfile", "deploy/gcp-run/render.py"]
MAX_EVIDENCE_BYTES = 64 * 1024


def acceptance_hashes(config, root=ROOT):
    """Bind long-running real-world checks to relevant sources and stable config.

    Exclude source commit/image identity so a docs-only build can reuse real
    evidence. Every release still independently verifies its exact OCI image.
    Numeric secret pins and infrastructure configuration are included.
    """
    render.validate(config)
    context = {k: v for k, v in config.items() if k not in {"commit", "backendImage", "retainedTraffic", "acceptanceEvidence"}}
    hashes = {}
    for gate, patterns in OPERATOR_GATES.items():
        files = set()
        for pattern in COMMON_SOURCES + patterns:
            matches = [p for p in root.glob(pattern) if p.is_file() and not p.is_symlink()]
            if not matches:
                raise release.ReleaseError("A critical acceptance source is missing; review the evidence scope.")
            files.update(matches)
        sources = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(files)}
        hashes[gate] = hashlib.sha256(render.canonical({"context": context, "sources": sources}).encode()).hexdigest()
    return hashes


def read_acceptance(config):
    """Fixed Google HTTPS host, no redirect, exact object generation and SHA256."""
    reference = config["acceptanceEvidence"]
    path = "/storage/v1/b/" + config["backupBucket"] + "/o/" + urllib.parse.quote(reference["object"], safe="")
    path += "?alt=media&generation=" + reference["generation"]
    connection = http.client.HTTPSConnection("storage.googleapis.com", timeout=30)
    try:
        connection.request("GET", path, headers={"Authorization": "Bearer " + registry.get_token(), "Accept-Encoding": "identity"})
        response = connection.getresponse()
        if response.status != 200:
            raise release.ReleaseError("Pinned operator acceptance evidence is unavailable.")
        raw = response.read(MAX_EVIDENCE_BYTES + 1)
        if len(raw) > MAX_EVIDENCE_BYTES or hashlib.sha256(raw).hexdigest() != reference["sha256"]:
            raise release.ReleaseError("Operator evidence size or digest does not match its pin.")
        value = json.loads(raw, object_pairs_hook=registry.unique_object)
        if not isinstance(value, dict):
            raise release.ReleaseError("Invalid operator evidence document.")
        return value
    except (OSError, http.client.HTTPException, ValueError):
        raise release.ReleaseError("Operator evidence retrieval failed.") from None
    finally:
        connection.close()


def verify_acceptance(config, value, root=ROOT, now=None):
    expected_keys = {"version", "environment", "project", "verifiedAt", "checks"}
    if (not isinstance(value, dict) or set(value) != expected_keys or value.get("version") != 1
            or value.get("environment") != "staging" or value.get("project") != render.PROJECT
            or not isinstance(value.get("checks"), dict) or set(value["checks"]) != set(OPERATOR_GATES)):
        raise release.ReleaseError("Operator evidence is not a complete staging acceptance record.")
    try:
        stamp = datetime.fromisoformat(value["verifiedAt"].replace("Z", "+00:00"))
        if ((now or datetime.now(timezone.utc)) - stamp).total_seconds() < 0:
            raise ValueError("future")
    except (TypeError, AttributeError, ValueError):
        raise release.ReleaseError("Invalid operator acceptance timestamp.") from None
    hashes = acceptance_hashes(config, root)
    for gate, expected_hash in hashes.items():
        entry = value["checks"][gate]
        if not isinstance(entry, dict) or set(entry) != {"passed", "sourceSha256"} or entry["passed"] is not True or entry["sourceSha256"] != expected_hash:
            raise release.ReleaseError("Critical runtime/config changed or acceptance is missing; repeat the affected real check.")
    return {gate: True for gate in OPERATOR_GATES}


def identity_token(audience):
    if audience not in {render.origin(name) for name in render.SERVICES}:
        raise release.ReleaseError("Unexpected private service token audience.")
    # gcloud print-identity-token rejects WIF external_account credentials for
    # --audiences/--include-email. Use its existing access token only to request
    # an ID token for this exact same CI account. No generateAccessToken,
    # signBlob, credential file or arbitrary target account is needed.
    connection = http.client.HTTPSConnection("iamcredentials.googleapis.com", timeout=30)
    try:
        connection.request("POST", "/v1/projects/-/serviceAccounts/" + DEPLOY_ACCOUNT + ":generateIdToken",
                           body=json.dumps({"audience": audience, "includeEmail": True}),
                           headers={"Authorization": "Bearer " + registry.get_token(), "Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            raise release.ReleaseError("Could not obtain the private service invocation token.")
        raw = response.read(16_385)
        if len(raw) > 16_384:
            raise release.ReleaseError("Invalid private service invocation token response.")
        value = json.loads(raw)
        token = value.get("token") if isinstance(value, dict) else None
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", token):
            raise release.ReleaseError("Invalid private service invocation token response.")
        return token
    except (OSError, http.client.HTTPException, ValueError):
        raise release.ReleaseError("Could not obtain the private service invocation token.") from None
    finally:
        connection.close()


def schedule_snapshot():
    values = release.json_command(release.gcloud("scheduler", "jobs", "list", "--location=" + render.REGION, "--format=json(name,state)"))
    names = {"nextstop-" + name for name in render.SCHEDULES}
    result = {row.get("name", "").rsplit("/", 1)[-1]: row.get("state") for row in values
              if row.get("name", "").rsplit("/", 1)[-1] in names}
    if set(result) != names or any(state not in {"ENABLED", "PAUSED"} for state in result.values()):
        raise release.ReleaseError("All four staging schedules must already be commissioned; initial setup is an operator action.")
    return result


def set_schedules(snapshot, action):
    current = schedule_snapshot()
    for name, state in snapshot.items():
        if state == "ENABLED" and current[name] == ("ENABLED" if action == "pause" else "PAUSED"):
            release.run(release.gcloud("scheduler", "jobs", action, name, "--location=" + render.REGION))


def event(phase, state="completed"):
    print(json.dumps({"phase": phase, "state": state}), flush=True)


def rollback_plan(config):
    result = []
    # Restore the public gateway first. Its old private targets remain pinned.
    for name in ("gateway", "api", "auth", "live", "broker"):
        allocations = {}
        for row in config["retainedTraffic"][name]:
            if row["percent"]:
                allocations[row["revisionName"]] = allocations.get(row["revisionName"], 0) + row["percent"]
        result.append(release.gcloud("run", "services", "update-traffic", "nextstop-" + name,
                                    "--region=" + render.REGION,
                                    "--to-revisions=" + ",".join(f"{revision}={percent}" for revision, percent in sorted(allocations.items()))))
    return result


def deploy(config, *, root=ROOT):
    import verify  # Shared checked-in HTTP gates; no HTTP side effects on import.

    render.validate(config)
    if release.run(["git", "-C", str(root), "rev-parse", "HEAD"]).strip() != config["commit"]:
        raise release.ReleaseError("Checked-out source does not match the requested application commit.")
    if release.run(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all", "--", "backend", "deploy/gcp-run"]).strip():
        raise release.ReleaseError("Critical deployment sources must match the clean tested checkout.")
    account = release.run(["gcloud", "config", "get-value", "account"], timeout=30).strip()
    if account != DEPLOY_ACCOUNT:
        raise release.ReleaseError("Cloud Run CI requires the exact staging deploy identity.")
    operator_gates = verify_acceptance(config, read_acceptance(config), root)
    registry.verify(registry.RegistryReader(registry.get_token()), config["backendImage"].split("@", 1)[1], config["commit"])
    event("artifact-and-acceptance")
    # This path is for the existing installation. Root's first migration/cutover
    # establishes the services, bindings, real evidence and four schedules.
    config = dict(config, retainedTraffic=release.service_snapshot(release.current_services()))
    if set(config["retainedTraffic"]) != set(render.SERVICES):
        raise release.ReleaseError("Every staging service must already be commissioned before automated releases.")
    schedules = schedule_snapshot()
    paused = False
    mutated_definitions = False
    traffic_started = False
    try:
        paused = True
        set_schedules(schedules, "pause")
        release.preflight(config, queue_exists=True)
        event("preflight")
        with tempfile.TemporaryDirectory(prefix="nextstop-run-release-") as temporary:
            directory = Path(temporary)
            render.write_rendered(config, directory)
            # Expand and apply role grants before any candidate service is changed.
            release.run(release.gcloud("run", "jobs", "replace", str(directory / "migrate.json"), "--region=" + render.REGION), timeout=180)
            mutated_definitions = True
            release.run(release.gcloud("run", "jobs", "execute", "nextstop-migrate", "--region=" + render.REGION, "--wait"), timeout=1000)
            event("compatible-migrations-and-grants")
            for command in release.definitions_plan(config, directory, True)["commands"]:
                release.run(command, timeout=600)
            release.preflight(config, queue_exists=True, candidates_applied=True)
            event("candidate-definitions")
            smoke = verify.verify(config, identity_token)
            receipt = {"release": render.release_id(config), "image": config["backendImage"], "commit": config["commit"],
                       "verifiedAt": datetime.now(timezone.utc).isoformat(), **operator_gates, **smoke,
                       "artifactVerified": True, "loggingExclusionVerified": True, "privateIAMVerified": True}
            release.verify_receipt(config, receipt)
            event("candidate-gates")
            # Re-read traffic after the HTTP gates so concurrent handoffs cannot
            # silently replace the traffic snapshot we are about to promote.
            release.preflight(config, queue_exists=True, candidates_applied=True)
            traffic_started = True
            for command in release.promotion_plan(config):
                release.run(command, timeout=180)
            event("promotion")
            # The real XFF probe exhausts this client's auth bucket. At12/min,
            # allow two tokens to refill for public /ready/auth; no retry burst.
            time.sleep(10)
            verify.verify_public(config, identity_token)
            event("public-ready-and-search")
        set_schedules(schedules, "resume")
        paused = False
        event("schedules-restored")
    except Exception:
        if mutated_definitions:
            try:
                set_schedules(schedules, "pause")
            except release.ReleaseError:
                event("scheduler-pause-recovery", "attention")
        if traffic_started:
            rollback_ok = True
            for command in rollback_plan(config):
                try:
                    release.run(command, timeout=180)
                except release.ReleaseError:
                    rollback_ok = False
            event("original-traffic-restoration", "completed" if rollback_ok else "attention")
        raise
    finally:
        if paused and not mutated_definitions:
            # No job definition changed: restore exactly the original scheduler
            # states. Once jobs changed, failure leaves schedules paused for review.
            set_schedules(schedules, "resume")
        elif paused:
            event("schedules-remain-paused-after-failure", "attention")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--image")
    parser.add_argument("--commit")
    parser.add_argument("--acceptance-hashes", action="store_true")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        if args.image is not None:
            config["backendImage"] = args.image
        if args.commit is not None:
            config["commit"] = args.commit
        render.validate(config)
        if args.acceptance_hashes:
            print(json.dumps({"sourceHashes": acceptance_hashes(config)}, indent=2))
        else:
            deploy(config)
        return 0
    except Exception:
        # Includes transport/library errors; never reflect a URL, token, payload,
        # SQL error or private GCS object identifier into CI output.
        print("Cloud Run staging release stopped; inspect sanitized phase status. Schedules may remain paused.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
