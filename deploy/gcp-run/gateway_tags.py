"""Retire release-owned routes on the verified public gateway after verification."""
import argparse
import http.client
import json
from pathlib import Path
import re
import sys
import time

import registry
import release
import render

REVISION = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"


def gateway_service(config, target):
    if (target is not render.TARGETS.get(config.get("environment")) or
            target not in (render.STAGING, render.PRODUCTION) or config.get("project") != target.project):
        raise release.ReleaseError("Gateway cleanup requires the selected, commissioned environment and project.")
    return f"projects/{target.project}/locations/{render.REGION}/services/nextstop-gateway"


def allocations(rows, key="revisionName"):
    shares = {}
    for row in rows:
        percent = row.get("percent", 0)
        if type(percent) is not int or not 0 <= percent <= 100:
            raise release.ReleaseError("Invalid gateway allocation.")
        if percent:
            revision = row.get(key)
            if not revision:
                raise release.ReleaseError("Traffic must resolve to explicit revisions.")
            shares[revision] = shares.get(revision, 0) + percent
    if sum(shares.values()) != 100:
        raise release.ReleaseError("Serving traffic must total 100 percent.")
    return shares


def cloud_run(method, path, token, body=None, *, v1=False):
    host = render.REGION + "-run.googleapis.com" if v1 else "run.googleapis.com"
    prefix = "/apis/serving.knative.dev/v1/" if v1 else "/v2/"
    conn = http.client.HTTPSConnection(host, timeout=30)
    try:
        conn.request(method, prefix + path, body=json.dumps(body) if body else None,
                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        response = conn.getresponse()
        if response.status not in (200, 201):
            raise release.ReleaseError("Gateway tag operation failed or conflicted; take a fresh verified snapshot.")
        raw = response.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise release.ReleaseError("Gateway metadata exceeds the expected size.")
        return json.loads(raw)
    except (OSError, ValueError, http.client.HTTPException):
        raise release.ReleaseError("Gateway tag operation could not be confirmed.") from None
    finally:
        conn.close()


def retained_routes(service, expected, owned, resource):
    if (service.get("name") != resource or not service.get("etag") or not service.get("generation")
            or service.get("generation") != service.get("observedGeneration") or service.get("reconciling")
            or service.get("terminalCondition", {}).get("state") != "CONDITION_SUCCEEDED"):
        raise release.ReleaseError("Public gateway is not in a settled, versioned state.")
    desired, actual = service.get("traffic", []), service.get("trafficStatuses", [])
    if allocations(desired, "revision") != expected or allocations(actual, "revision") != expected:
        raise release.ReleaseError("Public gateway allocation changed since verification.")
    def tags(rows):
        pairs = [(r["tag"], r.get("revision")) for r in rows if r.get("tag")]
        if len(dict(pairs)) != len(pairs):
            raise release.ReleaseError("Ambiguous gateway tag.")
        return dict(pairs)
    if tags(desired) != tags(actual):
        raise release.ReleaseError("Public gateway tag assignments have not settled.")
    # V2 can split a tag and percentage into separate desired rows for the
    # same revision; status can combine them. Retain *every* serving revision.
    return [r for r in desired if not (
        r.get("type") == REVISION and not r.get("percent") and r.get("revision") not in expected
        and (r.get("tag"), r.get("revision")) in owned)]


def retire(config, expected, *, target):
    resource = gateway_service(config, target)
    rid = render.release_id(config)
    original = config["retainedTraffic"].get("gateway", [])
    owned = {(row["tag"], row["revisionName"]) for row in original if
             re.fullmatch(r"r-[0-9a-f]{12}", row.get("tag", "")) and
             row["revisionName"] == "nextstop-gateway-" + row["tag"][2:]}
    owned.add(("r-" + rid, "nextstop-gateway-" + rid))
    token = registry.get_token()
    path = resource + "?fields=name,etag,generation,observedGeneration,reconciling,terminalCondition(state),traffic,trafficStatuses"
    before = cloud_run("GET", path, token)
    kept = retained_routes(before, expected, owned, resource)
    if kept == before["traffic"]:
        return
    # A successful pre-read alone cannot protect another release from removal.
    # The traffic-only PATCH must still match the version we actually inspected.
    op = cloud_run("PATCH", resource + "?updateMask=traffic", token,
                   {"name": resource, "etag": before["etag"], "traffic": kept})
    operation_name = op.get("name", "")
    region = resource.split("/services/")[0]
    if not re.fullmatch(re.escape(region) + r"/operations/[A-Za-z0-9_-]+", operation_name):
        raise release.ReleaseError("Unexpected gateway update operation.")
    deadline = time.monotonic() + 120
    while not op.get("done") and time.monotonic() < deadline:
        time.sleep(2)
        op = cloud_run("GET", operation_name + "?fields=name,done,error(code)", token)
    if not op.get("done") or "error" in op:
        raise release.ReleaseError("Gateway tag update did not complete successfully.")
    after = cloud_run("GET", path, token)
    retained_routes(after, expected, owned, resource)
    if sorted(map(render.canonical, after["traffic"])) != sorted(map(render.canonical, kept)):
        raise release.ReleaseError("Public gateway routes changed during retirement.")


def v1_routes(rows):
    if any(not r.get("revisionName") or r.get("latestRevision") for r in rows):
        raise release.ReleaseError("The gateway definition requires resolved, explicit revision targets.")
    tags = [(r["tag"], r["revisionName"]) for r in rows if r.get("tag")]
    if len(dict(tags)) != len(tags):
        raise release.ReleaseError("Gateway traffic has ambiguous tags.")
    return allocations(rows), dict(tags)


def apply_definition(manifest, original, target):
    if target is not render.STAGING and target is not render.PRODUCTION:
        raise release.ReleaseError("Unknown gateway definition target.")
    meta = manifest["metadata"]
    name = "nextstop-gateway"
    rid = meta.get("labels", {}).get("nextstop-release", "")
    if (meta.get("name") != name or str(meta.get("namespace")) not in {target.number, target.project}
            or meta.get("labels", {}).get("nextstop-environment") != target.environment
            or not re.fullmatch(r"[0-9a-f]{12}", rid)
            or manifest["spec"]["template"]["metadata"]["name"] != name + "-" + rid):
        raise release.ReleaseError("Gateway definition does not match the explicit target.")
    candidate = name + "-" + rid
    expected_shares, expected_tags = v1_routes(original) if original else ({candidate: 100}, {})
    if expected_tags.get("r-" + rid, candidate) != candidate:
        raise release.ReleaseError("A candidate tag cannot be repointed.")
    expected = expected_shares, {**expected_tags, "r-" + rid: candidate}
    if v1_routes(manifest["spec"]["traffic"]) != expected:
        raise release.ReleaseError("Gateway definition would alter existing allocations or routes.")
    base = "namespaces/" + target.project + "/services"
    path = base + "/" + name
    token = registry.get_token()
    if original:
        current = cloud_run("GET", path, token, v1=True)
        metadata, status = current["metadata"], current["status"]
        ready = next((r for r in status.get("conditions", []) if r.get("type") == "Ready"), {})
        if (metadata.get("name") != name or str(metadata.get("namespace")) not in {target.project, target.number}
                or not metadata.get("resourceVersion") or not metadata.get("generation")
                or metadata["generation"] != status.get("observedGeneration") or ready.get("status") != "True"
                or any(v1_routes(rows) != (expected_shares, expected_tags)
                       for rows in (current["spec"]["traffic"], status["traffic"]))):
            raise release.ReleaseError("Gateway traffic changed since the reviewed definition snapshot.")
        # gcloud services replace substitutes its own latest resourceVersion;
        # send this exact one to the regional API, without automatic conflict retries.
        meta["resourceVersion"] = metadata["resourceVersion"]
        meta.setdefault("annotations", {}).update({k: v for k, v in metadata.get("annotations", {}).items()
                                                  if k.startswith("serving.knative.dev/")})
        saved = cloud_run("PUT", path, token, manifest, v1=True)
    else:
        # A concurrent first deployment gets a conflict, never an implicit replace.
        saved = cloud_run("POST", base, token, manifest, v1=True)
    generation = saved.get("metadata", {}).get("generation")
    if not generation:
        raise release.ReleaseError("Conditional gateway definition returned no generation.")
    deadline = time.monotonic() + 540
    while time.monotonic() < deadline:
        current = cloud_run("GET", path, token, v1=True)
        metadata, status = current["metadata"], current.get("status", {})
        if metadata.get("generation") != generation:
            raise release.ReleaseError("Gateway was modified during candidate reconciliation.")
        if status.get("observedGeneration") == generation:
            ready = next((r for r in status.get("conditions", []) if r.get("type") == "Ready"), {})
            if ready.get("status") == "False":
                raise release.ReleaseError("Conditional gateway definition failed to reconcile.")
            if ready.get("status") == "True" and v1_routes(status["traffic"]) == expected:
                return
        time.sleep(2)
    raise release.ReleaseError("Conditional gateway definition did not settle.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Apply a reviewed gateway with optimistic concurrency control.")
    parser.add_argument("--project", required=True, choices=[t.project for t in render.TARGETS.values()])
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-traffic", required=True)
    args = parser.parse_args()
    try:
        target = next(t for t in render.TARGETS.values() if t.project == args.project)
        apply_definition(json.loads(args.manifest.read_text()), json.loads(args.expected_traffic), target)
    except (OSError, ValueError, KeyError, TypeError, release.ReleaseError):
        print("Conditional gateway definition failed; take a fresh snapshot before retrying.", file=sys.stderr)
        raise SystemExit(1) from None
