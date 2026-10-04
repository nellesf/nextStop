#!/usr/bin/env python3
"""Operator-run staging live-task gate. This deliberately causes one Swiss refresh.

Requires an idle queue, a cold Swiss cache, and root-supplied PG credentials for
the existing local Cloud SQL proxy. Never reads password files, changes IAM,
invokes jobs directly, or prints HTTP payloads, task IDs, routes or credentials.
Queue stats: cloud.google.com/tasks/docs/reference/rest/v2beta3/projects.locations.queues#QueueStats
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from urllib.parse import quote
import uuid

from render import CONNECTION, PROJECT, QUEUE, REGION, ConfigurationError, origin, release_id, validate
from verify import VerificationError, identity_provider, request_json, write_report

QUEUE_PATH = f"projects/{PROJECT}/locations/{REGION}/queues/{QUEUE}"
SOCKET = "/private/tmp/ns-sql/" + CONNECTION
# Only these literal operational messages may reach CLI diagnostics. Transport
# implementations (including injected VerificationError instances) are untrusted.
SAFE_DIAGNOSTICS = frozenset({
    "No eligible public fixture candidate was found.",
    "Required control timestamp is missing.",
    "Synthetic search lacks bounded demand availability candidates.",
    "Availability contract failed.",
    "Availability candidate identity changed.",
    "Availability counts changed the static candidate contract.",
    "Live task completion was not proven within three minutes; queued retries were left intact.",
    "Invalid control timestamp.",
    "Only the reviewed staging proxy/database/owner role is supported.",
    "Staging database credentials or proxy port are unavailable.",
    "Read-only Cloud metadata identity is unavailable.",
    "Read-only Cloud metadata query failed.",
    "Stable live task target is not the reviewed candidate release.",
    "Live queue statistics are unavailable or the queue is not running.",
    "Live queue is not isolated for the bounded gate.",
    "Live queue metadata pagination exceeded its four-page bound.",
    "Invalid or repeated live queue page token.",
    "Unexpected task metadata.",
    "Availability observations are not fresh.",
    "Gate requires an idle queue, no lease/cooldown and a cold Swiss cache; no reset was attempted.",
    "Private candidate token mint failed.",
    "DE-only fixture unexpectedly requested live refresh.",
    "Static searches or DE-only availability changed live state.",
    "Concurrent refresh was not accepted within one task window.",
    "Live task gate failed without exposing diagnostic payloads.",
    "Release binding or create-only evidence destination failed.",
    "Read-only live control query failed.",
    "Unexpected live control database identity.",
    "Live snapshot metadata is missing.",
    "Invalid live queue statistics.",
    "Candidate readiness or image binding failed.",
    "Synthetic static search failed.",
    "Nonblocking availability request failed or exceeded its bound.",
    "More than one task was observed for the concurrent requests.",
    "Concurrent requests caused multiple provider refreshes.",
    "Fresh shared cache did not suppress another enqueue.",
    "Final cache read changed the completed live state.",
})
SQL = """
BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s'; SET LOCAL lock_timeout = '500ms';
SELECT json_build_object(
 'database', current_database(), 'role', current_user,
 'now', clock_timestamp(),
 'control', (SELECT json_build_object('lastAttempt',last_attempt_at,'lastSuccess',last_success_at,
   'leaseActive',lease_until IS NOT NULL,'nextAllowed',next_allowed_at)
   FROM nextstop.live_refresh_control WHERE provider_id='ich_tanke_strom'),
 'snapshots', (SELECT json_build_object('active',count(*) FILTER(WHERE status='active'),
   'publishedRecently',count(*) FILTER(WHERE published_at > clock_timestamp()-interval '10 minutes'),
   'publishedAt',max(published_at) FILTER(WHERE status='active'),
   'observedAt',max(observed_at) FILTER(WHERE status='active'),
   'fetchedAt',max(fetched_at) FILTER(WHERE status='active'),
   'records',coalesce(max(record_count) FILTER(WHERE status='active'),0))
   FROM nextstop.availability_snapshots WHERE provider_id='ich_tanke_strom'));
ROLLBACK;
"""


def instant(value):
    if not isinstance(value, str):
        raise VerificationError("Required control timestamp is missing.")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.timestamp()
    except ValueError:
        raise VerificationError("Invalid control timestamp.") from None


class Database:
    def __init__(self, psql, environment=None):
        supplied = os.environ if environment is None else environment
        if (supplied.get("PGHOST"), supplied.get("PGDATABASE"), supplied.get("PGUSER")) != (SOCKET, "nextstop", "nextstop_app"):
            raise VerificationError("Only the reviewed staging proxy/database/owner role is supported.")
        if not supplied.get("PGPASSWORD") or supplied.get("PGPORT", "5432") != "5432":
            raise VerificationError("Staging database credentials or proxy port are unavailable.")
        # Discard ambient libpq target overrides and options, without reading any
        # secret file. The supplied password exists only in child process memory.
        self.environment = {k: v for k, v in supplied.items() if not k.startswith("PG")}
        self.environment.update({k: supplied[k] for k in ("PGHOST", "PGDATABASE", "PGUSER", "PGPASSWORD")})
        self.environment.update(PGPORT="5432", PGCONNECT_TIMEOUT="10", PGAPPNAME="nextstop-live-gate",
                                PGOPTIONS="-c default_transaction_read_only=on")
        self.psql = str(psql)

    def __call__(self):
        try:
            result = subprocess.run([self.psql, "-XqAt", "--no-password", "-v", "ON_ERROR_STOP=1"],
                input=SQL, env=self.environment, capture_output=True, text=True, timeout=20)
            if result.returncode or len(result.stdout) > 8192:
                raise VerificationError("Read-only live control query failed.")
            value = json.loads(result.stdout)
            if value.get("database") != "nextstop" or value.get("role") != "nextstop_app":
                raise VerificationError("Unexpected live control database identity.")
            instant(value.get("now"))
            if not isinstance(value.get("snapshots"), dict):
                raise VerificationError("Live snapshot metadata is missing.")
            return value
        except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
            raise VerificationError("Read-only live control query failed.") from None


class CloudMetadata:
    def __init__(self, config, request=request_json):
        self.config, self.request = config, request
        result = subprocess.run(["gcloud", "auth", "print-access-token", "--quiet", "--verbosity=error"],
                                capture_output=True, text=True, timeout=30)
        token = result.stdout.strip()
        if result.returncode or not re.fullmatch(r"[A-Za-z0-9_.~-]{32,8192}", token):
            raise VerificationError("Read-only Cloud metadata identity is unavailable.")
        self.headers = {"Authorization": "Bearer " + token}

    def get(self, url):
        status, body, _ = self.request(url, "GET", self.headers, timeout=15)
        if status != 200:
            raise VerificationError("Read-only Cloud metadata query failed.")
        return body

    def verify_live_target(self):
        service = self.get(f"https://{REGION}-run.googleapis.com/apis/serving.knative.dev/v1/namespaces/{PROJECT}/services/nextstop-live"
                           "?fields=status(traffic),spec(template(metadata(name),spec(containers(image))))")
        expected = "nextstop-live-" + release_id(self.config)
        traffic = service.get("status", {}).get("traffic", [])
        serving = [row for row in traffic if row.get("percent", 0) > 0]
        template = service.get("spec", {}).get("template", {})
        if (sum(row.get("percent", 0) for row in serving) != 100
                or any(row.get("revisionName") != expected for row in serving)
                or template.get("metadata", {}).get("name") != expected
                or [row.get("image") for row in template.get("spec", {}).get("containers", [])] != [self.config["backendImage"]]):
            raise VerificationError("Stable live task target is not the reviewed candidate release.")

    def __call__(self):
        value = self.get("https://cloudtasks.googleapis.com/v2beta3/" + QUEUE_PATH + "?readMask=state,stats")
        if value.get("state") != "RUNNING" or not isinstance(value.get("stats"), dict):
            raise VerificationError("Live queue statistics are unavailable or the queue is not running.")
        stats = value["stats"]
        result = {}
        for source, destination in (("tasksCount", "estimatedPending"), ("executedLastMinuteCount", "completedLastMinute"),
                                    ("concurrentDispatchesCount", "inFlight")):
            raw = stats.get(source, "0")
            if not re.fullmatch(r"[0-9]{1,9}", str(raw)):
                raise VerificationError("Invalid live queue statistics.")
            result[destination] = int(raw)
        # BASIC response with an explicit field mask cannot retrieve task bodies,
        # authorization headers, routes, or provider response contents.
        base = ("https://cloudtasks.googleapis.com/v2/" + QUEUE_PATH +
                "/tasks?responseView=BASIC&pageSize=10&fields=tasks(name),nextPageToken")
        names, seen_tokens, token = set(), set(), ""
        # ListTasks may return partial or empty pages with a continuation token.
        # Only an empty token ends enumeration. A bounded scan is sufficient for
        # this isolated one-task gate; a larger/unstable queue fails closed.
        for _ in range(4):
            listing = self.get(base + ("&pageToken=" + quote(token, safe="") if token else ""))
            rows = listing.get("tasks", [])
            if not isinstance(rows, list) or len(rows) > 10:
                raise VerificationError("Live queue is not isolated for the bounded gate.")
            page_names = {row.get("name") for row in rows if isinstance(row, dict)}
            if len(page_names) != len(rows) or any(not isinstance(name, str) or not name.startswith(QUEUE_PATH + "/tasks/") for name in page_names):
                raise VerificationError("Unexpected task metadata.")
            names.update(page_names)
            if len(names) > 10:
                raise VerificationError("Live queue is not isolated for the bounded gate.")
            token = listing.get("nextPageToken", "")
            if not isinstance(token, str) or len(token) > 4096 or token in seen_tokens:
                raise VerificationError("Invalid or repeated live queue page token.")
            if not token:
                return {**result, "names": names}
            seen_tokens.add(token)
        raise VerificationError("Live queue metadata pagination exceeded its four-page bound.")


def quiet(queue):
    return not queue["names"] and all(queue[name] == 0 for name in ("estimatedPending", "completedLastMinute", "inFlight"))


def stable_database(first, second):
    return first["control"] == second["control"] and first["snapshots"] == second["snapshots"]


def selection(body, swiss):
    candidates = body.get("candidates")
    if not isinstance(candidates, list) or not 1 <= len(candidates) <= 100 or not isinstance(body.get("availabilityContext"), str):
        raise VerificationError("Synthetic search lacks bounded demand availability candidates.")
    for candidate in candidates:
        sources = candidate.get("sources", [])
        operators = candidate.get("operators", [])
        if (any(source.get("id") == "ich_tanke_strom" for source in sources) is swiss
                and 1 <= len(operators) <= 20 and len(set(operators)) == len(operators)
                and all(isinstance(name, str) and 1 <= len(name) <= 200 for name in operators)
                and type(candidate.get("chargingPoints")) is int and candidate["chargingPoints"] > 0):
            uuid.UUID(candidate["id"])
            return {"context": body["availabilityContext"], "candidates": [{"id": candidate["id"], "operatorNames": operators}]}, candidate["chargingPoints"]
    raise VerificationError("No eligible public fixture candidate was found.")


def validate_availability(body, payload, total):
    values = body.get("candidates")
    if (body.get("context") != payload["context"] or type(body.get("refreshPending")) is not bool
            or not isinstance(values, list) or len(values) != 1):
        raise VerificationError("Availability contract failed.")
    requested = payload["candidates"][0]
    value = values[0]
    if value.get("id") != requested["id"] or value.get("operatorNames") != requested["operatorNames"]:
        raise VerificationError("Availability candidate identity changed.")
    available = value.get("availability", {})
    if (any(type(available.get(name)) is not int or available[name] < 0 for name in ("total", "knownAvailable", "knownUnavailable", "unknown"))
            or available["total"] != total or sum(available[name] for name in ("knownAvailable", "knownUnavailable", "unknown")) != total
            or available.get("complete") is not (available["unknown"] == 0)):
        raise VerificationError("Availability counts changed the static candidate contract.")
    if available["knownAvailable"] + available["knownUnavailable"]:
        age = instant(body.get("generatedAt")) - instant(available.get("observedAt"))
        if not 0 <= age <= 300:
            raise VerificationError("Availability observations are not fresh.")
    return body["refreshPending"]


def verify(config, token_provider, database, queue, request=request_json, sleep=time.sleep,
           wall=time.time, monotonic=time.monotonic):
    """Two fixed searches, one DE availability, two concurrent CH requests, one final cache read."""
    validate(config)
    try:
        before = database()
        now = instant(before["now"])
        control = before["control"]
        snapshots = before["snapshots"]
        if (not quiet(queue()) or snapshots["publishedRecently"] != 0 or snapshots["active"] > 1
                or (snapshots["observedAt"] is not None and now - instant(snapshots["observedAt"]) < 600)
                or (control is not None and (control["leaseActive"] or instant(control["nextAllowed"]) > now))):
            raise VerificationError("Gate requires an idle queue, no lease/cooldown and a cold Swiss cache; no reset was attempted.")
        tag = "r-" + release_id(config)
        gateway = origin("gateway", tag)
        status, minted, _ = request(origin("broker", tag) + "/token", "POST",
                                   {"Authorization": "Bearer " + token_provider(origin("broker"))})
        token = minted.get("accessToken")
        if status != 200 or minted.get("tokenType") != "Bearer" or not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{32,4096}", token):
            raise VerificationError("Private candidate token mint failed.")
        headers = {"Authorization": "Bearer " + token, "X-Serverless-Authorization": "Bearer " + token_provider(origin("gateway")),
                   "Content-Type": "application/json"}
        for path in ("/ready", "/ready/auth"):
            status, body, _ = request(gateway + path, "GET", headers)
            if status != 200 or body != {"status": "ready", "release": config["backendImage"].split("@", 1)[1]}:
                raise VerificationError("Candidate readiness or image binding failed.")
        selections = []
        for swiss, coordinates in ((False, [[8.68, 50.11], [9.12, 49.9], [9.57, 49.77]]),
                                   (True, [[8.5417, 47.3769], [8.7242, 47.4988], [9.3762, 47.4245]])):
            payload = {"requestId": str(uuid.uuid4()), "route": {"type": "LineString", "coordinates": coordinates},
                       "criteria": {"distanceRangeMeters": {"minimum": 15000, "maximum": 50000}, "minimumChargingPoints": 2, "minimumPowerKW": 11}}
            status, body, _ = request(gateway + "/v1/charging-parks/search", "POST", headers, payload)
            if status != 200:
                raise VerificationError("Synthetic static search failed.")
            selections.append(selection(body, swiss))
        def availability(item):
            payload, total = item
            started = monotonic()
            status, body, _ = request(gateway + "/v1/charging-parks/availability", "POST", headers, payload, timeout=20)
            if status != 200 or monotonic() - started >= 20:
                raise VerificationError("Nonblocking availability request failed or exceeded its bound.")
            return validate_availability(body, payload, total)
        if availability(selections[0]):
            raise VerificationError("DE-only fixture unexpectedly requested live refresh.")
        sleep(3)
        if not quiet(queue()) or not stable_database(before, database()):
            raise VerificationError("Static searches or DE-only availability changed live state.")
        # Keep both enqueue attempts comfortably inside the same deterministic
        # minute window. Never change cache/lease state to force a refresh.
        offset = wall() % 60
        if not 5 <= offset <= 25:
            sleep((65 - offset) if offset > 25 else (5 - offset))
        window = int(wall() // 60)
        task = QUEUE_PATH + "/tasks/" + hashlib.sha256(("ich_tanke_strom\0" + QUEUE_PATH + "\0" + str(window)).encode()).hexdigest()
        started = monotonic()
        barrier = threading.Barrier(2)
        def concurrent():
            barrier.wait(timeout=5)
            return availability(selections[1])
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(concurrent) for _ in range(2)]
            pending = [future.result(timeout=25) for future in futures]
        if not any(pending) or int(wall() // 60) != window:
            raise VerificationError("Concurrent refresh was not accepted within one task window.")
        attempts = set()
        while monotonic() - started < 180:
            metadata = queue()
            current = database()
            if metadata["names"] - {task} or any(metadata[key] > 1 for key in ("estimatedPending", "completedLastMinute", "inFlight")):
                raise VerificationError("More than one task was observed for the concurrent requests.")
            current_control = current["control"]
            if current_control is not None and current_control["lastAttempt"] != (control or {}).get("lastAttempt"):
                attempts.add(current_control["lastAttempt"])
            if len(attempts) > 1 or current["snapshots"]["publishedRecently"] > 1:
                raise VerificationError("Concurrent requests caused multiple provider refreshes.")
            if (current_control is not None and not current_control["leaseActive"] and len(attempts) == 1
                    and current_control["lastSuccess"] is not None
                    and instant(current_control["lastSuccess"]) >= instant(current_control["lastAttempt"])
                    and current["snapshots"]["publishedRecently"] == 1
                    and current["snapshots"]["active"] == 1 and current["snapshots"]["records"] > 0
                    and instant(current["snapshots"]["publishedAt"]) >= instant(current_control["lastAttempt"])
                    and 0 <= instant(current["now"]) - instant(current["snapshots"]["observedAt"]) <= 60
                    and metadata["completedLastMinute"] == 1 and metadata["inFlight"] == 0 and not metadata["names"]):
                if availability(selections[1]):
                    raise VerificationError("Fresh shared cache did not suppress another enqueue.")
                sleep(3)
                final_queue = queue()
                after = database()
                if (not stable_database(current, after) or final_queue["names"] or final_queue["inFlight"] != 0
                        or final_queue["completedLastMinute"] != 1):
                    raise VerificationError("Final cache read changed the completed live state.")
                return {"release": release_id(config), "image": config["backendImage"], "commit": config["commit"],
                        "verifiedAt": datetime.fromtimestamp(wall(), timezone.utc).isoformat(), "liveTaskCompatibilityPassed": True,
                        "searchRequests": 2, "availabilityRequests": 4, "concurrentSwissRequests": 2,
                        "observedCompletedDispatches": 1, "observedProviderAttempts": 1, "newPublications": 1,
                        "deTaskCount": 0, "leaseReleased": True, "freshCacheReused": True,
                        "lastAttemptAt": current_control["lastAttempt"], "lastSuccessAt": current_control["lastSuccess"],
                        "publishedAt": current["snapshots"]["publishedAt"], "providerObservedAt": current["snapshots"]["observedAt"]}
            sleep(5)
        raise VerificationError("Live task completion was not proven within three minutes; queued retries were left intact.")
    except VerificationError:
        raise
    except Exception:
        raise VerificationError("Live task gate failed without exposing diagnostic payloads.") from None


def failure_report(error):
    message = str(error) if isinstance(error, VerificationError) else ""
    return {"status": "failed",
            "reason": "Live task gate did not pass; no success evidence written. Any accepted task remains under its bounded queue retry policy.",
            "fixedDiagnostic": message if message in SAFE_DIAGNOSTICS else "Live task gate failed without exposing diagnostic payloads."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-release", required=True)
    parser.add_argument("--psql", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--impersonate-service-account")
    args = parser.parse_args()
    try:
        config = validate(json.loads(args.config.read_text()))
        if release_id(config) != args.expected_release or args.output.exists():
            raise VerificationError("Release binding or create-only evidence destination failed.")
        database = Database(args.psql)
        metadata = CloudMetadata(config)
        metadata.verify_live_target()
        report = verify(config, identity_provider(args.impersonate_service_account), database, metadata)
        write_report(args.output, report)
        print(json.dumps(report, sort_keys=True))
    except Exception as error:
        print(json.dumps(failure_report(error), sort_keys=True), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
