#!/usr/bin/env python3
"""Commission exactly four staging schedules, ending PAUSED. Default: local plan only.

Cloud Scheduler cannot atomically create a paused job: state is output-only.
Apply only during UTC minute 10..49, away from every approved minute-zero cron.
Each absent job is created once, immediately paused, then read back. No job is
resumed, run, patched or deleted. Existing definitions must match and be PAUSED.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import re
import signal
import subprocess
import sys

from render import PROJECT, REGION, SCHEDULES, ConfigurationError, canonical, release_id, scheduler, validate
from verify import VerificationError, request_json

JOBS = ("monthly", "cleanup", "report-purge", "backup")
COLLECTION = f"projects/{PROJECT}/locations/{REGION}/jobs"
OUTPUT_FIELDS = {"state", "status", "scheduleTime", "lastAttemptTime", "userUpdateTime", "satisfiesPzs"}
DEFAULT_RETRY = {"retryCount": 0, "maxRetryDuration": "0s", "minBackoffDuration": "5s",
                 "maxBackoffDuration": "3600s", "maxDoublings": 5}


class CommissionError(RuntimeError):
    pass


def safe_window(now):
    if now.tzinfo is None:
        raise CommissionError("A timezone-aware clock is required.")
    return 10 <= now.astimezone(timezone.utc).minute <= 49


def definitions():
    # Fail closed if the renderer later adds jobs or changes minute-zero timing;
    # this commissioning helper is deliberately not a generic cron editor.
    if set(SCHEDULES) != set(JOBS) or any(not schedule.startswith("0 ") for schedule in SCHEDULES.values()):
        raise CommissionError("Scheduler set/timing changed and requires a new commissioning review.")
    values = [scheduler(name) for name in JOBS]
    if any("state" in value for value in values):
        raise CommissionError("Create definitions must not contain output-only state.")
    return values


def seconds(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]{1,9})?s", value):
        raise CommissionError("Scheduler duration metadata differs from the reviewed definition.")
    try:
        return Decimal(value[:-1])
    except InvalidOperation:
        raise CommissionError("Invalid scheduler duration.") from None


def matches(value, expected):
    """Compare every writable field, allowing only documented server defaults."""
    if not isinstance(value, dict) or set(value) - set(expected) - OUTPUT_FIELDS - {"description"}:
        raise CommissionError("Existing scheduler has unexpected metadata; no changes made to it.")
    if value.get("description", "") != "":
        raise CommissionError("Existing scheduler description differs from the reviewed definition.")
    if any(value.get(key) != expected[key] for key in ("name", "schedule", "timeZone")):
        raise CommissionError("Existing scheduler target or timing differs from the reviewed definition.")
    if seconds(value.get("attemptDeadline")) != seconds(expected["attemptDeadline"]):
        raise CommissionError("Existing scheduler deadline differs from the reviewed definition.")
    retry = value.get("retryConfig", {})
    if not isinstance(retry, dict) or set(retry) - set(DEFAULT_RETRY):
        raise CommissionError("Existing scheduler retry metadata differs from the reviewed definition.")
    for key, default in DEFAULT_RETRY.items():
        actual = retry.get(key, default)
        wanted = expected["retryConfig"].get(key, default)
        equal = (type(actual) is int and actual == wanted) if isinstance(default, int) else seconds(actual) == seconds(wanted)
        if not equal:
            raise CommissionError("Existing scheduler retry policy differs from the reviewed definition.")
    target = value.get("httpTarget")
    wanted = expected["httpTarget"]
    if not isinstance(target, dict) or set(target) != set(wanted):
        raise CommissionError("Existing scheduler HTTP target differs from the reviewed definition.")
    if any(target[key] != wanted[key] for key in ("uri", "httpMethod", "body", "oauthToken")):
        raise CommissionError("Existing scheduler body or invocation identity differs from the reviewed definition.")
    headers = target["headers"]
    if not isinstance(headers, dict) or len({key.lower() for key in headers}) != len(headers):
        raise CommissionError("Existing scheduler headers are invalid.")
    headers = {key.lower(): val for key, val in headers.items()}
    # Google may materialize these documented computed/default headers.
    computed = {"user-agent": "Google-Cloud-Scheduler", "host": "run.googleapis.com", "content-length": "2",
                "x-cloudscheduler": "true", "x-cloudscheduler-jobname": expected["name"]}
    for key, val in computed.items():
        if key in headers:
            if headers.pop(key) != val:
                raise CommissionError("Unexpected scheduler-generated header metadata.")
    if headers != {"content-type": "application/json"}:
        raise CommissionError("Existing scheduler headers differ from the reviewed definition.")


class SchedulerAPI:
    def __init__(self, request=request_json):
        result = subprocess.run(["gcloud", "auth", "print-access-token", "--quiet", "--verbosity=error"],
                                capture_output=True, text=True, timeout=30)
        token = result.stdout.strip()
        if result.returncode or not re.fullmatch(r"[A-Za-z0-9_.~-]{32,8192}", token):
            raise CommissionError("Operator scheduler identity is unavailable.")
        self.headers, self.request = {"Authorization": "Bearer " + token}, request

    def __call__(self, method, path, body=None):
        names = {value["name"] for value in definitions()}
        if not ((method == "GET" and path in names and body is None)
                or (method == "POST" and path in {name + ":pause" for name in names} and body == {})
                or (method == "POST" and path == COLLECTION and body in definitions())):
            raise CommissionError("Unapproved scheduler operation was refused.")
        return self.request("https://cloudscheduler.googleapis.com/v1/" + path, method,
                            {**self.headers, "Content-Type": "application/json"}, body, timeout=15)[:2]


def read(api, expected):
    status, value = api("GET", expected["name"])
    if status == 404:
        return None
    if status != 200:
        raise CommissionError("Scheduler metadata could not be read; only HTTP404 means absent.")
    matches(value, expected)
    return value


def require_paused(value):
    if value.get("state") != "PAUSED":
        raise CommissionError("Existing scheduler is not paused; it was left unchanged.")


def pause_created(api, expected):
    # Only called after our successful create, or an ambiguous create followed by
    # an exact metadata match. Retry pause/readback, never retry create or run.
    for _ in range(3):
        try:
            api("POST", expected["name"] + ":pause", {})
            status, current = api("GET", expected["name"])
            if status != 200:
                continue
            matches(current, expected)
            if current.get("state") == "PAUSED":
                if current.get("lastAttemptTime"):
                    raise CommissionError("New scheduler unexpectedly attempted execution; it is now paused and requires inspection.")
                return
        except VerificationError:
            continue
    raise CommissionError("New scheduler could not be confirmed paused; stop and inspect the four staging schedules immediately.")


@contextmanager
def finish_before_interrupt():
    """Defer Ctrl-C/SIGTERM only through one bounded create/readback/pause cycle."""
    interrupted = []
    previous = {}
    def defer(signum, _frame):
        if not interrupted:
            interrupted.append(signum)
    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, defer)
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    if interrupted:
        raise CommissionError("Commissioning interrupted after confirming the current new job paused; remaining jobs were not created.")


def create_and_pause(api, definition):
    conflict = False
    try:
        status = None
        try:
            status, _ = api("POST", COLLECTION, definition)
        except VerificationError:
            pass  # Unknown outcome: get the exact name, never repeat create.
        if status == 409:
            conflict = True
            current = read(api, definition)
            if current is None:
                raise CommissionError("Concurrent scheduler creation could not be verified.")
            require_paused(current)
            return False
        if status not in (200, 201):
            if status is not None and status not in (408, 429) and status < 500:
                raise CommissionError("Scheduler creation was rejected; no retry was performed.")
            current = read(api, definition)
            if current is None:
                raise CommissionError("Scheduler create outcome was not confirmed; no retry was performed.")
        pause_created(api, definition)
        return True
    except KeyboardInterrupt:
        # Covers an already-raised interrupt from an injected transport as well
        # as normal signals deferred by finish_before_interrupt. Never adopt a
        # known competing 409 create. Exact metadata must match before cleanup.
        if not conflict:
            current = read(api, definition)
            if current is not None:
                pause_created(api, definition)
        raise


def commission(config, api, now=lambda: datetime.now(timezone.utc)):
    validate(config)
    expected = definitions()
    if not safe_window(now()):
        raise CommissionError("Use UTC minute10 through49, at least ten minutes away from any due time.")
    # Read all four before the first mutation. An unexpected existing job blocks
    # all creation, rather than silently modifying its ownership or schedule.
    initial = [read(api, value) for value in expected]
    for value in initial:
        if value is not None:
            require_paused(value)
    created = 0
    for definition, previous in zip(expected, initial):
        if previous is not None:
            continue
        if not safe_window(now()):
            raise CommissionError("Safe commissioning window ended; all previously created jobs remain paused.")
        current = read(api, definition)
        if current is not None:
            require_paused(current)
            continue
        with finish_before_interrupt():
            created += int(create_and_pause(api, definition))
    for definition in expected:
        value = read(api, definition)
        if value is None:
            raise CommissionError("A commissioned scheduler is missing.")
        require_paused(value)
    return {"status": "paused", "release": release_id(config), "project": PROJECT,
            "created": created, "preserved": len(expected) - created, "verifiedPaused": 4,
            "definitionsSha256": hashlib.sha256(canonical(expected).encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-release", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        config = validate(json.loads(args.config.read_text()))
        if args.expected_release != release_id(config):
            raise CommissionError("Release does not match the reviewed configuration.")
        if args.apply:
            result = commission(config, SchedulerAPI())
        else:
            result = {"mode": "local-plan-only", "release": release_id(config), "project": PROJECT,
                      "safeWindowUTC": "minute10..49", "currentWindowSafe": safe_window(datetime.now(timezone.utc)),
                      "newJobsBrieflyEnabledUntilImmediatePause": True, "expectedFinalState": "PAUSED",
                      "definitions": definitions()}
        print(json.dumps(result, sort_keys=True, indent=2))
    except (CommissionError, ConfigurationError, VerificationError, OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, CommissionError) else "Scheduler commissioning failed; raw diagnostic payloads withheld."
        print(json.dumps({"status": "failed", "reason": message}), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
