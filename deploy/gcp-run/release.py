#!/usr/bin/env python3
"""Plan/apply staging definitions, then separately promote a verified revision.

Never creates IAM, secrets, a database, buckets, DNS or enabled schedules. The
operator owns those prerequisites. Output contains phase results, never cloud
responses, HTTP payloads or credentials. Existing production release tooling is
not imported or modified.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from render import (CONNECTION, JOBS, LOG_EXCLUSION, PROJECT, PROJECT_NUMBER,
                    QUEUE, REGION, SCHEDULES, SERVICES, ConfigurationError, account,
                    canonical, release_id, render, validate, write_rendered)


class ReleaseError(RuntimeError):
    pass


SQL_LOG_FLAGS = {
    "log_connections": "off", "log_disconnections": "off",
    "log_min_duration_statement": "-1", "log_min_error_statement": "panic",
    "log_parameter_max_length": "0", "log_parameter_max_length_on_error": "0",
    "log_statement": "none",
}


def verify_sql_security(settings):
    ip = settings.get("ipConfiguration", {})
    # A connector may use the instance's public IP. That does not authorize
    # direct client networks; sslMode is the authoritative TLS policy field.
    if (settings.get("connectorEnforcement") != "REQUIRED"
            or not isinstance(ip, dict) or ip.get("authorizedNetworks", []) != []
            or ip.get("sslMode") != "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"):
        raise ReleaseError("Database connector, authorized-network or TLS policy differs from the reviewed boundary.")
    if settings.get("storageAutoResize") is not False:
        raise ReleaseError("Automatic database storage growth differs from the approved fixed-storage cost policy.")
    rows = settings.get("databaseFlags")
    if (not isinstance(rows, list) or any(not isinstance(row, dict)
            or not isinstance(row.get("name"), str) or not isinstance(row.get("value"), str) for row in rows)):
        raise ReleaseError("Database logging policy metadata is missing or malformed.")
    flags = {row["name"]: row["value"] for row in rows}
    if len(flags) != len(rows) or any(flags.get(name) != value for name, value in SQL_LOG_FLAGS.items()):
        raise ReleaseError("Database logging redaction differs from the reviewed privacy policy.")
    # PostgreSQL's default disables sampled statements; reject an explicit
    # override without requiring Cloud SQL to serialize the unset default.
    if flags.get("log_min_duration_sample", "-1") != "-1":
        raise ReleaseError("Database sampled-statement logging would expose request data.")


def gcloud(*args):
    return ["gcloud", *args, "--project=" + PROJECT, "--quiet", "--verbosity=error"]


def run(command, timeout=90):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ReleaseError("Cloud operation failed or timed out; inspect sanitized platform status before retrying.") from None
    if result.returncode != 0:
        raise ReleaseError("Cloud operation failed; raw command output is deliberately withheld.")
    return result.stdout


def json_command(command):
    try:
        return json.loads(run(command))
    except (ValueError, TypeError):
        raise ReleaseError("Cloud metadata response was not valid JSON.") from None


def service_snapshot(rows):
    result = {}
    for row in rows:
        name = row.get("metadata", {}).get("name", "")
        short = name.removeprefix("nextstop-")
        if short not in SERVICES:
            continue
        traffic = []
        for target in row.get("status", {}).get("traffic", []):
            entry = {"revisionName": target.get("revisionName"), "percent": target.get("percent", 0)}
            if "tag" in target:
                entry["tag"] = target["tag"]
            traffic.append(entry)
        if not traffic:
            raise ReleaseError("Existing service has no stable resolved traffic snapshot.")
        result[short] = traffic
    return result


def current_services():
    return json_command(gcloud("run", "services", "list", "--region=" + REGION, "--format=json"))


def same_traffic(left, right):
    normalize = lambda values: {name: sorted((canonical(row) for row in rows)) for name, rows in values.items()}
    return normalize(left) == normalize(right)


def definitions_plan(config, output, queue_exists):
    validate(config)
    queue = render(config)["queue"]
    commands = [gcloud("tasks", "queues", "update" if queue_exists else "create", QUEUE,
                       "--location=" + REGION, "--max-concurrent-dispatches=1", "--max-dispatches-per-second=0.1",
                       "--max-attempts=3", "--max-retry-duration=0s", "--min-backoff=660s", "--max-backoff=660s",
                       "--max-doublings=0", "--log-sampling-ratio=0")]
    for name in ("api", "auth", "live", "broker", "gateway"):
        commands.append(gcloud("run", "services", "replace", str(output / (name + ".json")), "--region=" + REGION))
    for name in JOBS:
        commands.append(gcloud("run", "jobs", "replace", str(output / (name + ".json")), "--region=" + REGION))
    result = {"project": PROJECT, "region": REGION, "release": release_id(config),
              "image": config["backendImage"], "commit": config["commit"], "commands": commands,
              "queueRetry": queue["retryConfig"],
              "prerequisites": ["OCI revision/platform verification for the exact image and commit",
                                "g1-small PostgreSQL17 with 50 GiB SSD, separate role/secret grants and seeded public corpus",
                                "all non-gateway services IAM-private; gateway identity has no secret or SQL access",
                                "raw Cloud Run request-log exclusion active before any request",
                                "all four schedules absent or paused and no unfinished maintenance execution",
                                "monthly job's persistent total three-attempt / 24-hour budget tested",
                                "filtered backup has passed a private restore rehearsal; report data excluded",
                                "retainedTraffic is a fresh resolved snapshot of these exact services"],
              "doesNotPerform": ["IAM changes", "secret creation", "database creation or migrations", "DNS changes",
                                 "scheduler creation or resume", "job execution", "existing gateway traffic promotion"]}
    result["planSha256"] = hashlib.sha256(canonical({"plan": result, "manifests": render(config)}).encode()).hexdigest()
    return result


def verify_private_iam(rows):
    for row in rows:
        name = row.get("metadata", {}).get("name", "")
        if name.removeprefix("nextstop-") not in SERVICES or name == "nextstop-gateway":
            continue
        if str(row.get("metadata", {}).get("annotations", {}).get("run.googleapis.com/invoker-iam-disabled", "false")).lower() == "true":
            raise ReleaseError("A private runtime service has disabled the IAM invoker check.")
        policy = json_command(gcloud("run", "services", "get-iam-policy", name, "--region=" + REGION, "--format=json(bindings)"))
        if any(member in {"allUsers", "allAuthenticatedUsers"}
               for binding in policy.get("bindings", []) for member in binding.get("members", [])):
            raise ReleaseError("A private runtime service has a public IAM binding.")


def verify_candidates(config):
    """Read immutable candidate metadata, without accessing environment values in secrets."""
    manifests = render(config)
    for name in SERVICES:
        expected = manifests[name]["spec"]["template"]
        row = json_command(gcloud("run", "revisions", "describe", expected["metadata"]["name"],
                                  "--region=" + REGION, "--format=json(metadata,spec,status)"))
        spec, status = row.get("spec", {}), row.get("status", {})
        containers = spec.get("containers", [])
        expected_container = expected["spec"]["containers"][0]
        annotations = row.get("metadata", {}).get("annotations", {})
        if (row.get("metadata", {}).get("name") != expected["metadata"]["name"]
                or spec.get("serviceAccountName") != account(name) or len(containers) != 1
                or not any(c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions", []))):
            raise ReleaseError("A candidate revision is missing, not ready or has the wrong identity.")
        container = containers[0]
        digest = status.get("imageDigest", container.get("image"))
        actual_env = {e.get("name"): e for e in container.get("env", [])}
        expected_env = {e["name"]: e for e in expected_container["env"]}
        limits = container.get("resources", {}).get("limits", {})
        if (digest != config["backendImage"]
                or container.get("command") != expected_container["command"]
                or container.get("args") != expected_container["args"] or actual_env != expected_env
                or any(annotations.get(key) != value for key, value in expected["metadata"]["annotations"].items())
                or limits.get("cpu") not in {"1", "1000m"} or limits.get("memory") not in {"512Mi", "536870912"}
                or spec.get("containerConcurrency") != expected["spec"]["containerConcurrency"]
                or spec.get("timeoutSeconds") != expected["spec"]["timeoutSeconds"]):
            raise ReleaseError("Candidate image, command or pinned environment differs from the reviewed release.")


def preflight(config, queue_exists, candidates_applied=False):
    project = json_command(gcloud("projects", "describe", PROJECT, "--format=json(projectNumber,projectId)"))
    if (project.get("projectId"), str(project.get("projectNumber"))) != (PROJECT, PROJECT_NUMBER):
        raise ReleaseError("Project identity does not match the isolated staging project.")
    rows = current_services()
    actual = service_snapshot(rows)
    expected = ({name: render(config)[name]["spec"]["traffic"] for name in SERVICES}
                if candidates_applied else config["retainedTraffic"])
    if not same_traffic(actual, expected):
        raise ReleaseError("Serving traffic changed; capture a fresh snapshot and review a new plan.")
    verify_private_iam(rows)
    if candidates_applied:
        verify_candidates(config)
    sql = json_command(gcloud("sql", "instances", "describe", CONNECTION.rsplit(":", 1)[1],
                              "--format=json(databaseVersion,region,settings.tier,settings.dataDiskSizeGb,settings.dataDiskType,settings.availabilityType,settings.backupConfiguration,settings.connectorEnforcement,settings.ipConfiguration,settings.databaseFlags,settings.storageAutoResize)"))
    settings = sql.get("settings", {})
    if (sql.get("databaseVersion"), sql.get("region"), settings.get("tier"), str(settings.get("dataDiskSizeGb")), settings.get("dataDiskType"), settings.get("availabilityType")) != (
        "POSTGRES_17", REGION, "db-g1-small", "50", "PD_SSD", "ZONAL",
    ):
        raise ReleaseError("Database sizing differs from the approved staging cost plan.")
    backup = settings.get("backupConfiguration", {})
    if backup.get("enabled") or backup.get("pointInTimeRecoveryEnabled"):
        raise ReleaseError("Managed full backups or PITR conflict with the filtered report-data backup policy.")
    verify_sql_security(settings)
    sink = json_command(gcloud("logging", "sinks", "describe", "_Default", "--format=json(exclusions)"))
    if not any(row.get("name") == LOG_EXCLUSION["name"] and row.get("filter") == LOG_EXCLUSION["filter"]
               and not row.get("disabled", False) for row in sink.get("exclusions", [])):
        raise ReleaseError("The required raw-request-log exclusion is not active.")
    queues = json_command(gcloud("tasks", "queues", "list", "--location=" + REGION, "--format=json(name)"))
    found = any(row.get("name", "").rsplit("/", 1)[-1] == QUEUE for row in queues)
    if found != (queue_exists or candidates_applied):
        raise ReleaseError("Queue existence changed; review an updated plan.")
    schedules = json_command(gcloud("scheduler", "jobs", "list", "--location=" + REGION, "--format=json(name,state)"))
    ours = {"nextstop-" + name for name in SCHEDULES}
    if any(row.get("name", "").rsplit("/", 1)[-1] in ours and row.get("state") != "PAUSED" for row in schedules):
        raise ReleaseError("Pause this release's schedules before replacing job definitions.")
    executions = json_command(gcloud("run", "jobs", "executions", "list", "--region=" + REGION, "--format=json(metadata.labels,status)"))
    for row in executions:
        name = row.get("metadata", {}).get("labels", {}).get("run.googleapis.com/job")
        if name in {"nextstop-" + job for job in JOBS} and not row.get("status", {}).get("completionTime"):
            raise ReleaseError("An unfinished maintenance execution must complete before release.")


def verify_receipt(config, receipt, now=None):
    now = now or datetime.now(timezone.utc)
    required = {"release", "image", "commit", "verifiedAt", "apiReady", "authReady", "syntheticSearchPassed",
                "clientIPIsolationPassed", "loggingExclusionVerified", "jobsBudgetVerified", "privateIAMVerified",
                "artifactVerified", "filteredBackupRestorePassed", "liveTaskCompatibilityPassed",
                "xffPrefixResistancePassed", "idleScaleToZeroPassed", "databasePerformancePassed"}
    if not isinstance(receipt, dict) or set(receipt) != required or (receipt["release"], receipt["image"], receipt["commit"]) != (
        release_id(config), config["backendImage"], config["commit"],
    ):
        raise ReleaseError("Verification receipt is not bound to this exact release.")
    try:
        stamp = datetime.fromisoformat(receipt["verifiedAt"].replace("Z", "+00:00"))
        seconds = (now - stamp).total_seconds()
    except (ValueError, TypeError, AttributeError):
        raise ReleaseError("Invalid verification timestamp.") from None
    if not 0 <= seconds <= 3600 or any(receipt[key] is not True for key in required - {"release", "image", "commit", "verifiedAt"}):
        raise ReleaseError("All candidate gates must pass within the last hour.")


def promotion_plan(config):
    # Older gateways use immutable API/auth tags. Private default transitions do
    # not redirect their API calls; shared live-task wire compatibility is a gate.
    return [gcloud("run", "services", "update-traffic", "nextstop-" + name, "--region=" + REGION,
                   "--to-revisions=nextstop-" + name + "-" + release_id(config) + "=100")
            for name in ("live", "broker", "api", "auth", "gateway")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("snapshot", "plan", "apply-definitions", "promote"))
    parser.add_argument("--project", required=True, choices=(PROJECT,))
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--queue-exists", action="store_true")
    parser.add_argument("--expected-plan-sha256")
    parser.add_argument("--verification", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "snapshot":
            print(json.dumps({"retainedTraffic": service_snapshot(current_services())}, indent=2))
            return
        if args.config is None or args.output is None:
            raise ReleaseError("--config and --output are required.")
        config = validate(json.loads(args.config.read_text()))
        output = args.output.resolve()
        plan = definitions_plan(config, output, args.queue_exists)
        if args.mode == "plan":
            write_rendered(config, output)
            print(json.dumps(plan, indent=2))
            return
        if args.expected_plan_sha256 != plan["planSha256"]:
            raise ReleaseError("The applied configuration must match the reviewed plan hash.")
        preflight(config, args.queue_exists, candidates_applied=args.mode == "promote")
        if args.mode == "apply-definitions":
            write_rendered(config, output)
            commands = plan["commands"]
        else:
            if args.verification is None:
                raise ReleaseError("A local candidate verification receipt is required.")
            verify_receipt(config, json.loads(args.verification.read_text()))
            commands = promotion_plan(config)
        for index, command in enumerate(commands, 1):
            print(json.dumps({"phase": args.mode, "step": index, "state": "starting"}), flush=True)
            run(command, timeout=900)
            print(json.dumps({"phase": args.mode, "step": index, "state": "completed"}), flush=True)
    except (ReleaseError, ConfigurationError, OSError, ValueError, TypeError, KeyError) as error:
        # Known messages are fixed, not provider error text or secret-bearing config.
        message = str(error) if isinstance(error, (ReleaseError, ConfigurationError)) else "Invalid local release input."
        print(json.dumps({"status": "failed", "reason": message}), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
