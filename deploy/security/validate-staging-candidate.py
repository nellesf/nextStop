#!/usr/bin/env python3
"""Validate an old production security image on private, zero-traffic staging revisions.

Preparation is read-only. --apply requires the exact prepared plan hash. Only the
existing private API/auth service templates gain candidate revisions/tags; public
traffic, IAM, secrets, jobs, worker and migrations are never changed. Failure may
leave private zero-traffic candidates for inspection, never a success receipt.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid

PROJECT = "nextstop-tech-testing"
REGION = "europe-west1"
NUMBER = "353471052580"
CONNECTION = f"{PROJECT}:{REGION}:nextstop-staging"
REGISTRY = "europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend"
SERVICES = ("api", "auth", "gateway", "broker")
SECRET_NAMES = {
    "api": {"DATABASE_URL": "api-database-url", "SUPPORT_DATABASE_URL": "support-database-url",
            "SNAPSHOT_SIGNING_KEY": "snapshot-signing-key", "SEARCH_ACCESS_TOKEN_SIGNING_KEY": "access-token-signing-key"},
    "auth": {"AUTH_DATABASE_URL": "auth-database-url", "SEARCH_ACCESS_TOKEN_SIGNING_KEY": "access-token-signing-key"},
}
DB_ROLES = {"api": {"DATABASE_URL": "nextstop_api", "SUPPORT_DATABASE_URL": "nextstop_support"},
            "auth": {"AUTH_DATABASE_URL": "nextstop_auth"}}
NONSECRET = {"HOST", "PORT", "NEXTSTOP_RUNTIME", "NEXTSTOP_ENVIRONMENT", "DATABASE_TRANSPORT",
             "CLOUD_SQL_CONNECTION_NAME", "RELEASE_IMAGE_DIGEST", "ALLOW_LEGACY_STAGING_BEARER",
             "DEMAND_LIVE_AVAILABILITY_ENABLED", "LIVE_REFRESH_TRANSPORT", "LIVE_REFRESH_TASK_QUEUE",
             "LIVE_REFRESH_TASK_TARGET", "LIVE_REFRESH_TASK_SERVICE_ACCOUNT", "APP_ATTEST_APP_ID",
             "APP_ATTEST_ALLOW_DEVELOPMENT"}


class CandidateError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def run(argv, timeout=120):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise CandidateError("Operator command unavailable or timed out.") from None
    if result.returncode:
        raise CandidateError("Operator command failed; private output suppressed.")
    return result.stdout


def cloud(*args):
    return ["gcloud", *args, f"--project={PROJECT}", "--quiet", "--verbosity=error"]


def json_run(argv):
    try:
        return json.loads(run(argv))
    except ValueError:
        raise CandidateError("Operator command returned invalid JSON.") from None


def snapshot():
    return {name: {
        "service": json_run(cloud("run", "services", "describe", "nextstop-" + name,
                                   "--region=" + REGION, "--format=json")),
        "iam": json_run(cloud("run", "services", "get-iam-policy", "nextstop-" + name,
                               "--region=" + REGION, "--format=json")),
    } for name in SERVICES}


def traffic(service, status=False):
    rows = service.get("status" if status else "spec", {}).get("traffic", [])
    result = []
    for row in rows:
        if row.get("latestRevision") or not re.fullmatch(r"nextstop-[a-z0-9-]+", row.get("revisionName", "")):
            raise CandidateError("Every traffic allocation must pin an explicit revision.")
        percent = row.get("percent", 0)
        if type(percent) is not int or not 0 <= percent <= 100:
            raise CandidateError("Invalid traffic allocation.")
        value = {"revisionName": row["revisionName"], "percent": percent}
        if "tag" in row:
            if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", row["tag"]):
                raise CandidateError("Invalid traffic tag.")
            value["tag"] = row["tag"]
        result.append(value)
    if not result or sum(row["percent"] for row in result) != 100 or len(result) > 12:
        raise CandidateError("Expected bounded existing traffic totaling 100 percent.")
    tags = [row["tag"] for row in result if "tag" in row]
    if len(tags) != len(set(tags)):
        raise CandidateError("Duplicate traffic tags.")
    return sorted(result, key=canonical)


def traffic_signature(service, status=False):
    # Cloud Run may combine a tag-only spec row with the weighted allocation
    # for that same revision in status. Compare routing semantics, not row shape.
    allocations, tags = {}, {}
    for row in traffic(service, status):
        if row["percent"]:
            revision = row["revisionName"]
            allocations[revision] = allocations.get(revision, 0) + row["percent"]
        if "tag" in row:
            tags[row["tag"]] = row["revisionName"]
    return {"allocations": allocations, "tags": tags}


def iam_value(policy):
    return sorted([{**row, "members": sorted(row.get("members", []))}
                   for row in policy.get("bindings", [])], key=canonical)


def require_private(service, policy):
    if service.get("metadata", {}).get("annotations", {}).get("run.googleapis.com/invoker-iam-disabled", "false") != "false":
        raise CandidateError("Candidate service must enforce invoker IAM.")
    for row in policy.get("bindings", []):
        if set(row.get("members", [])) & {"allUsers", "allAuthenticatedUsers"}:
            raise CandidateError("Candidate service must not grant public IAM access.")


def wrapper(name):
    roles = canonical(DB_ROLES[name])
    entrypoint = "server" if name == "api" else "auth-server"
    # Catch URL parser errors too: they can otherwise print a secret DSN.
    return f'''try {{
  const roles = {roles};
  for (const [key, role] of Object.entries(roles)) {{
    const value = process.env[key];
    if (!value) throw new Error();
    const url = new URL(value);
    if (!['postgres:', 'postgresql:'].includes(url.protocol) || url.hostname !== 'localhost' ||
        url.port || url.pathname !== '/nextstop' || url.search || url.hash ||
        url.username !== role || !url.password) throw new Error();
    url.searchParams.set('host', '/cloudsql/{CONNECTION}');
    process.env[key] = url.toString();
  }}
}} catch {{ process.stderr.write('Invalid private staging database configuration.\\n'); process.exit(1); }}
await import('/app/dist/src/{entrypoint}.js');'''


def candidate(source, policy, name, image, tag):
    require_private(source, policy)
    metadata = source.get("metadata", {})
    if metadata.get("name") != "nextstop-" + name or str(metadata.get("namespace")) not in {PROJECT, NUMBER}:
        raise CandidateError("Unexpected staging service identity.")
    template = source.get("spec", {}).get("template", {})
    if template.get("metadata", {}).get("annotations", {}).get("run.googleapis.com/cloudsql-instances") != CONNECTION:
        raise CandidateError("Expected the existing staging Cloud SQL socket mount.")
    spec = template.get("spec", {})
    if spec.get("serviceAccountName") != f"nextstop-run-{name}@{PROJECT}.iam.gserviceaccount.com":
        raise CandidateError("Unexpected staging service account.")
    containers = spec.get("containers", [])
    if len(containers) != 1:
        raise CandidateError("Expected exactly one application container.")
    env = containers[0].get("env", [])
    if len({row.get("name") for row in env}) != len(env):
        raise CandidateError("Duplicate environment names.")
    values = {row.get("name"): row for row in env}
    for variable, secret in SECRET_NAMES[name].items():
        ref = values.get(variable, {}).get("valueFrom", {}).get("secretKeyRef", {})
        if (ref.get("name") != "nextstop-staging-" + secret or
                not re.fullmatch(r"[1-9][0-9]*", str(ref.get("key", ""))) or "value" in values[variable]):
            raise CandidateError("Expected numeric existing staging secret references.")
    for variable, row in values.items():
        if variable not in SECRET_NAMES[name] and (variable not in NONSECRET or set(row) != {"name", "value"}):
            raise CandidateError("Unreviewed staging environment variable.")
    if values.get("HOST", {}).get("value") != "0.0.0.0":
        raise CandidateError("Staging server must bind the container interface.")
    revision = "nextstop-" + name + "-" + tag
    retained = traffic(source)
    if any(row.get("tag") == tag or row["revisionName"] == revision for row in retained):
        raise CandidateError("Candidate already exists; inspect it before a separate retry.")
    if traffic_signature(source, status=True) != traffic_signature(source):
        raise CandidateError("Staging traffic is not settled.")
    result = {"apiVersion": "serving.knative.dev/v1", "kind": "Service",
              "metadata": {key: copy.deepcopy(metadata[key]) for key in
                           ("name", "namespace", "resourceVersion", "labels", "annotations") if key in metadata},
              "spec": copy.deepcopy(source["spec"])}
    result["spec"]["template"]["metadata"]["name"] = revision
    container = result["spec"]["template"]["spec"]["containers"][0]
    container["image"] = image
    container["command"] = ["node"]
    container["args"] = ["--input-type=module", "-e", wrapper(name)]
    container["env"] = [row for row in container["env"] if row["name"] != "RELEASE_IMAGE_DIGEST"]
    container["env"].append({"name": "RELEASE_IMAGE_DIGEST", "value": image.split("@", 1)[1]})
    # Preserve every original allocation/tag as written; normalization is only
    # for comparisons and must not rewrite the serving service's traffic rows.
    result["spec"]["traffic"] = copy.deepcopy(source["spec"]["traffic"]) + [
        {"revisionName": revision, "tag": tag, "percent": 0}]
    return result


def stable_service(value):
    service = value["service"]
    return {"spec": service.get("spec"), "annotations": service.get("metadata", {}).get("annotations", {}),
            "iam": iam_value(value["iam"])}


def plan(before, image, commit):
    if not re.fullmatch(re.escape(REGISTRY) + r"@sha256:[0-9a-f]{64}", image) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise CandidateError("Expected the approved immutable registry image and full source commit.")
    tag = "sec-" + commit[:12] + "-" + image.rsplit(":", 1)[1][:12]
    manifests = {name: candidate(before[name]["service"], before[name]["iam"], name, image, tag)
                 for name in ("api", "auth")}
    return {"mode": "private-candidate-validation", "project": PROJECT, "region": REGION,
            "image": image, "commit": commit, "tag": tag, "manifests": manifests,
            "baselineSHA256": {name: digest(stable_service(value)) for name, value in before.items()}}


def verify_unchanged(before, after, manifests, applied):
    for name in SERVICES:
        if iam_value(before[name]["iam"]) != iam_value(after[name]["iam"]):
            raise CandidateError("Service IAM changed during validation.")
        if name not in applied:
            if stable_service(before[name]) != stable_service(after[name]):
                raise CandidateError("An unrelated staging service changed during validation.")
            continue
        actual, expected = after[name]["service"], manifests[name]
        require_private(actual, after[name]["iam"])
        if (traffic_signature(actual) != traffic_signature(expected)
                or traffic_signature(actual, status=True) != traffic_signature(expected)):
            raise CandidateError("Existing traffic or candidate zero-percent allocation changed.")
        revision = expected["spec"]["template"]["metadata"]["name"]
        if actual.get("status", {}).get("latestReadyRevisionName") != revision:
            raise CandidateError("Candidate revision did not become ready.")
        actual_spec = actual.get("spec", {}).get("template", {}).get("spec", {})
        expected_spec = expected["spec"]["template"]["spec"]
        if actual_spec != expected_spec:
            raise CandidateError("Candidate runtime configuration differs from the prepared plan.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(url, method, headers, payload=None):
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    query = urllib.request.Request(url, method=method, headers=headers,
                                   data=None if payload is None else json.dumps(payload).encode())
    try:
        with client.open(query, timeout=45) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
            if response.status != 200 or len(raw) > 2 * 1024 * 1024:
                raise CandidateError("Private candidate response failed its bounds.")
            return json.loads(raw)
    except (OSError, ValueError, urllib.error.URLError):
        raise CandidateError("Private candidate request failed; payload suppressed.") from None


def origin(name):
    return f"https://nextstop-{name}-{NUMBER}.{REGION}.run.app"


def anonymous_rejected(url):
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with client.open(url + "/health", timeout=30):
            raise CandidateError("Candidate unexpectedly permits an anonymous request.")
    except urllib.error.HTTPError as error:
        code = error.code
        error.close()
        if code not in (401, 403):
            raise CandidateError("Anonymous candidate probe returned an unexpected status.") from None
    except (OSError, urllib.error.URLError):
        raise CandidateError("Anonymous candidate probe failed.") from None


def smoke(after, proposed, token, http=request, private_probe=anonymous_rejected):
    minted = http(origin("broker") + "/token", "POST", {"Authorization": "Bearer " + token})
    if (not isinstance(minted, dict) or set(minted) != {"accessToken", "expiresInSeconds", "tokenType"}
            or minted.get("tokenType") != "Bearer" or type(minted.get("expiresInSeconds")) is not int
            or not 60 <= minted["expiresInSeconds"] <= 900
            or not re.fullmatch(r"[A-Za-z0-9_.-]{32,4096}", minted.get("accessToken", ""))):
        raise CandidateError("Existing broker returned an invalid token contract.")
    urls = {}
    for name in ("api", "auth"):
        matches = [row for row in after[name]["service"]["status"]["traffic"] if row.get("tag") == proposed["tag"]]
        if len(matches) != 1:
            raise CandidateError("Candidate tag URL missing or ambiguous.")
        url = matches[0].get("url", "")
        base = after[name]["service"]["status"].get("url", "")
        if (not re.fullmatch(r"https://nextstop-" + re.escape(name) + r"-[a-z0-9.-]+\.run\.app", base)
                or url != "https://" + proposed["tag"] + "---" + base.removeprefix("https://")):
            raise CandidateError("Unexpected candidate tag URL.")
        urls[name] = url
        private_probe(url)
        value = http(url + "/ready", "GET", {"X-Serverless-Authorization": "Bearer " + token})
        if value != {"status": "ready", "release": proposed["image"].split("@", 1)[1]}:
            raise CandidateError("Candidate readiness or exact digest mismatch.")
    fixture = {"requestId": str(uuid.uuid4()), "route": {"type": "LineString",
               "coordinates": [[8.68, 50.11], [9.12, 49.9], [9.57, 49.77]]},
               "criteria": {"distanceRangeMeters": {"minimum": 15000, "maximum": 50000},
                            "minimumChargingPoints": 2, "minimumPowerKW": 11}}
    value = http(urls["api"] + "/v1/charging-parks/search", "POST",
                 {"X-Serverless-Authorization": "Bearer " + token,
                  "Authorization": "Bearer " + minted["accessToken"], "Content-Type": "application/json"}, fixture)
    if (not isinstance(value, dict) or not isinstance(value.get("candidates"), list)
            or not 1 <= len(value["candidates"]) <= 100
            or any(not isinstance(row, dict) for row in value["candidates"])
            or not isinstance(value.get("snapshotToken"), str) or not value["snapshotToken"]):
        raise CandidateError("Authenticated synthetic search returned invalid candidates.")
    return {"apiReady": True, "authReady": True, "syntheticSearchPassed": True,
            "anonymousRequestsRejected": True}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".candidate-", delete=False) as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        temporary = Path(output.name)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-plan-sha256")
    args = parser.parse_args()
    receipt = {"mode": "private-candidate-validation", "passed": False, "image": args.image, "commit": args.commit}
    try:
        before = snapshot()
        proposed = plan(before, args.image, args.commit)
        tagged = json_run(["gcloud", "artifacts", "docker", "images", "describe", REGISTRY + ":" + args.commit,
                           "--project=nextstop-tech-staging", "--format=json", "--quiet", "--verbosity=error"])
        if tagged.get("image_summary", {}).get("digest") != args.image.split("@", 1)[1]:
            raise CandidateError("Registry commit tag does not match the selected image.")
        plan_hash = digest(proposed)
        receipt.update(planSHA256=plan_hash, commitTagMatches=True)
        if args.apply and args.expected_plan_sha256 != plan_hash:
            raise CandidateError("Apply requires the unchanged prepared plan SHA-256.")
        save(args.output.with_suffix(".plan.json"), proposed)
        if not args.apply:
            receipt["phase"] = "prepared-read-only"
            save(args.output, receipt)
            print(canonical(receipt))
            return
        applied = []
        with tempfile.TemporaryDirectory(prefix="nextstop-private-candidate-") as temporary:
            for name in ("api", "auth"):
                verify_unchanged(before, snapshot(), proposed["manifests"], applied)
                path = Path(temporary) / (name + ".json")
                save(path, proposed["manifests"][name])
                run(cloud("run", "services", "replace", str(path), "--region=" + REGION), timeout=600)
                applied.append(name)
            after = snapshot()
            verify_unchanged(before, after, proposed["manifests"], applied)
            token = run(["gcloud", "auth", "print-identity-token", "--quiet", "--verbosity=error"], timeout=30).strip()
            if not re.fullmatch(r"[A-Za-z0-9_.-]{32,8192}", token):
                raise CandidateError("Operator identity token unavailable.")
            checks = smoke(after, proposed, token)
            del token
            verify_unchanged(before, snapshot(), proposed["manifests"], applied)
        receipt.update(passed=True, phase="private-candidates-verified", verifiedAt=datetime.now(timezone.utc).isoformat(),
                       checks={**checks, "existingTrafficPreserved": True, "privateIAMPreserved": True,
                               "gatewayAndBrokerUnchanged": True},
                       candidateRevisions={name: proposed["manifests"][name]["spec"]["template"]["metadata"]["name"] for name in applied},
                       scope="API/auth private candidates only; no public staging promotion, worker, jobs or migrations")
        save(args.output, receipt)
        print(canonical(receipt))
    except (CandidateError, KeyError, TypeError, ValueError, OSError) as error:
        reason = str(error) if isinstance(error, CandidateError) else "Invalid operator data or local I/O failure."
        receipt.update(phase="failed", error=reason,
                       recovery="Inspect current private revisions and traffic before retry; no public promotion was requested.")
        save(args.output, receipt)
        print(canonical(receipt))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
