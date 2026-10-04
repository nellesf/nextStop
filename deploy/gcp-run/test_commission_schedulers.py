"""Synthetic scheduler commissioning tests; no Cloud operations."""
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

import commission_schedulers as schedules
from test_render import configuration
from verify import VerificationError

NOW = datetime(2026, 10, 4, 12, 20, tzinfo=timezone.utc)


class API:
    def __init__(self, existing=False):
        self.jobs = {value["name"]: value | {"state": "PAUSED"} for value in schedules.definitions()} if existing else {}
        self.calls = []
        self.create_timeout = False
        self.pause_failures = 0

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if method == "GET":
            return (200, copy.deepcopy(self.jobs[path])) if path in self.jobs else (404, {})
        if path == schedules.COLLECTION:
            self.assert_create(body)
            self.jobs[body["name"]] = copy.deepcopy(body) | {"state": "ENABLED"}
            if self.create_timeout:
                self.create_timeout = False
                raise VerificationError("Synthetic redacted timeout")
            return 200, copy.deepcopy(self.jobs[body["name"]])
        assert path.endswith(":pause") and body == {}
        if self.pause_failures:
            self.pause_failures -= 1
            return 503, {}
        self.jobs[path.removesuffix(":pause")]["state"] = "PAUSED"
        return 200, copy.deepcopy(self.jobs[path.removesuffix(":pause")])

    def assert_create(self, body):
        assert body in schedules.definitions() and "state" not in body
        assert body["name"] not in self.jobs


class SchedulerTests(unittest.TestCase):
    def test_create_exact_four_then_pause_immediately_and_read_back(self):
        api = API()
        result = schedules.commission(configuration(), api, lambda: NOW)
        self.assertEqual(result["created"], 4)
        self.assertEqual(result["verifiedPaused"], 4)
        self.assertEqual(len(api.jobs), 4)
        self.assertEqual({job["state"] for job in api.jobs.values()}, {"PAUSED"})
        for index, (method, path, body) in enumerate(api.calls):
            if method == "POST" and path == schedules.COLLECTION:
                self.assertNotIn("state", body)
                self.assertEqual(api.calls[index + 1], ("POST", body["name"] + ":pause", {}))
        self.assertFalse(any(path.endswith(":run") or path.endswith(":resume") or method in {"PATCH", "DELETE"} for method, path, _ in api.calls))

    def test_existing_exact_paused_jobs_are_preserved_without_mutation(self):
        api = API(existing=True)
        for row in api.jobs.values():
            row["retryConfig"] = schedules.DEFAULT_RETRY.copy()
            row["attemptDeadline"] = "180.000s"
            row["httpTarget"]["headers"]["User-Agent"] = "Google-Cloud-Scheduler"
            row["httpTarget"]["headers"]["Content-Length"] = "2"
        result = schedules.commission(configuration(), api, lambda: NOW)
        self.assertEqual(result["preserved"], 4)
        self.assertTrue(all(method == "GET" for method, *_ in api.calls))

    def test_all_existing_metadata_is_checked_before_any_creation(self):
        for fault in ("state", "body", "scope", "schedule", "timeZone", "retry", "deadline", "unknown", "headers"):
            with self.subTest(fault=fault):
                api = API(existing=True)
                del api.jobs[schedules.definitions()[0]["name"]]
                row = api.jobs[schedules.definitions()[-1]["name"]]
                if fault == "state": row["state"] = "ENABLED"
                elif fault == "body": row["httpTarget"]["body"] = "eyJvdmVycmlkZXMiOnt9fQ=="
                elif fault == "scope": row["httpTarget"]["oauthToken"]["scope"] = "different"
                elif fault == "schedule": row["schedule"] = "* * * * *"
                elif fault == "timeZone": row["timeZone"] = "Europe/Berlin"
                elif fault == "retry": row["retryConfig"]["maxRetryDuration"] = "10s"
                elif fault == "deadline": row["attemptDeadline"] = "600s"
                elif fault == "unknown": row["unreviewed"] = True
                elif fault == "headers": row["httpTarget"]["headers"]["Authorization"] = "private-unexpected"
                with self.assertRaises(schedules.CommissionError): schedules.commission(configuration(), api, lambda: NOW)
                self.assertTrue(all(method == "GET" for method, *_ in api.calls))

    def test_only_http404_means_absent(self):
        for status in (401, 403, 429, 500, 503):
            calls = []
            def api(method, path, body=None):
                calls.append(method)
                return status, {"message": "private platform detail"}
            with self.assertRaises(schedules.CommissionError) as caught:
                schedules.commission(configuration(), api, lambda: NOW)
            self.assertEqual(calls, ["GET"])
            self.assertNotIn("private", str(caught.exception))

    def test_unsafe_time_aborts_before_cloud_reads_and_window_is_rechecked(self):
        for minute in (0, 9, 50, 59):
            api = API()
            with self.assertRaises(schedules.CommissionError):
                schedules.commission(configuration(), api, lambda: NOW.replace(minute=minute))
            self.assertEqual(api.calls, [])
        api = API()
        clock = iter([NOW, NOW, NOW.replace(minute=50)])
        with self.assertRaises(schedules.CommissionError):
            schedules.commission(configuration(), api, lambda: next(clock))
        self.assertEqual(len(api.jobs), 1)
        self.assertEqual(next(iter(api.jobs.values()))["state"], "PAUSED")

    def test_unknown_create_outcome_is_read_back_and_paused_without_second_create(self):
        api = API(); api.create_timeout = True
        result = schedules.commission(configuration(), api, lambda: NOW)
        self.assertEqual(result["created"], 4)
        self.assertEqual(sum(path == schedules.COLLECTION for _, path, _ in api.calls), 4)
        self.assertEqual({row["state"] for row in api.jobs.values()}, {"PAUSED"})

    def test_pause_transient_failure_retries_bounded_and_failure_demands_attention(self):
        api = API(); api.pause_failures = 1
        schedules.commission(configuration(), api, lambda: NOW)
        self.assertEqual({row["state"] for row in api.jobs.values()}, {"PAUSED"})
        api = API(); api.pause_failures = 10
        with self.assertRaisesRegex(schedules.CommissionError, "immediately"):
            schedules.commission(configuration(), api, lambda: NOW)
        self.assertEqual(sum(path.endswith(":pause") for _, path, _ in api.calls), 3)
        self.assertEqual(len(api.jobs), 1)

    def test_concurrent_enabled_creation_is_not_silently_modified(self):
        api = API()
        original = api.__call__
        def raced(method, path, body=None):
            if method == "POST" and path == schedules.COLLECTION:
                api.jobs[body["name"]] = body | {"state": "ENABLED"}
                return 409, {}
            return original(method, path, body)
        with self.assertRaisesRegex(schedules.CommissionError, "left unchanged"):
            schedules.commission(configuration(), raced, lambda: NOW)
        self.assertFalse(any(path.endswith(":pause") for _, path, _ in api.calls))

    def test_new_job_that_ran_is_paused_but_never_reported_successful(self):
        api = API()
        original = api.__call__
        def attempted(method, path, body=None):
            status, value = original(method, path, body)
            if method == "POST" and path == schedules.COLLECTION:
                api.jobs[body["name"]]["lastAttemptTime"] = NOW.isoformat()
            return status, value
        with self.assertRaisesRegex(schedules.CommissionError, "unexpectedly attempted"):
            schedules.commission(configuration(), attempted, lambda: NOW)
        self.assertEqual(next(iter(api.jobs.values()))["state"], "PAUSED")

    def test_keyboard_interrupt_after_remote_create_still_pauses_only_that_exact_job(self):
        api = API()
        original = api.__call__
        def interrupted(method, path, body=None):
            result = original(method, path, body)
            if method == "POST" and path == schedules.COLLECTION:
                raise KeyboardInterrupt()
            return result
        with self.assertRaises(KeyboardInterrupt):
            schedules.commission(configuration(), interrupted, lambda: NOW)
        self.assertEqual(len(api.jobs), 1)
        self.assertEqual(next(iter(api.jobs.values()))["state"], "PAUSED")
        self.assertEqual(sum(path.endswith(":pause") for _, path, _ in api.calls), 1)

    def test_sigterm_and_sigint_are_deferred_until_pause_then_stop_without_next_create(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            api = API()
            original = api.__call__
            previous = signal.getsignal(signum)
            def signalled(method, path, body=None):
                result = original(method, path, body)
                if method == "POST" and path == schedules.COLLECTION:
                    os.kill(os.getpid(), signum)
                return result
            with self.assertRaisesRegex(schedules.CommissionError, "interrupted after confirming"):
                schedules.commission(configuration(), signalled, lambda: NOW)
            self.assertEqual(signal.getsignal(signum), previous)
            self.assertEqual(len(api.jobs), 1)
            self.assertEqual(next(iter(api.jobs.values()))["state"], "PAUSED")

    def test_interrupt_during_conflict_read_never_adopts_another_enabled_job(self):
        expected = schedules.definitions()[0]
        calls = []
        def api(method, path, body=None):
            calls.append((method, path))
            if method == "POST": return 409, {}
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt): schedules.create_and_pause(api, expected)
        self.assertFalse(any(path.endswith(":pause") for _, path in calls))

    def test_transport_allows_only_fixed_four_get_create_pause_operations(self):
        with patch.object(schedules.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "synthetic-private-access" * 3, "")):
            api = schedules.SchedulerAPI(request=lambda *args, **kwargs: (200, {}, {}))
        expected = schedules.definitions()[0]
        for method, path, body in (("DELETE", expected["name"], None), ("POST", expected["name"] + ":run", {}),
                                   ("POST", expected["name"] + ":resume", {}), ("GET", "projects/production/jobs/other", None),
                                   ("POST", schedules.COLLECTION, expected | {"state": "PAUSED"})):
            with self.assertRaises(schedules.CommissionError): api(method, path, body)

    def test_default_cli_only_renders_local_plan(self):
        with tempfile.TemporaryDirectory() as folder:
            config = configuration(); path = Path(folder) / "config.json"
            path.write_text(json.dumps(config))
            result = subprocess.run([sys.executable, str(Path(schedules.__file__)), "--config", str(path),
                                     "--expected-release", schedules.release_id(config)], capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0)
            plan = json.loads(result.stdout)
            self.assertEqual(plan["mode"], "local-plan-only")
            self.assertEqual(plan["expectedFinalState"], "PAUSED")
            self.assertEqual(len(plan["definitions"]), 4)


if __name__ == "__main__": unittest.main()
