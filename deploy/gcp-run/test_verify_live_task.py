"""Synthetic only: no real provider, token, queue or database requests."""
import copy
from datetime import datetime, timezone
import json
import subprocess
import threading
import unittest
from unittest.mock import patch

from test_render import configuration
import verify_live_task as live


class Clock:
    def __init__(self):
        self.value = datetime(2026, 10, 4, 12, 0, 10, tzinfo=timezone.utc).timestamp()
    def now(self): return self.value
    def sleep(self, value): self.value += value
    def iso(self, seconds=0): return datetime.fromtimestamp(self.value + seconds, timezone.utc).isoformat()


def quiet():
    return {"estimatedPending": 0, "completedLastMinute": 0, "inFlight": 0, "names": set()}


class Fixture:
    def __init__(self):
        self.config = configuration()
        self.clock = Clock()
        self.calls = []
        self.lock = threading.Lock()
        self.ch_requests = 0
        self.db_reads = 0
        self.queue_reads = 0
        self.before = {"database": "nextstop", "role": "nextstop_app", "now": self.clock.iso(), "control": None,
                       "snapshots": {"active": 1, "publishedRecently": 0, "publishedAt": self.clock.iso(-3600),
                                     "observedAt": self.clock.iso(-3600), "fetchedAt": self.clock.iso(-3600), "records": 100}}
        self.success_time = self.clock.iso(3)
        self.after = copy.deepcopy(self.before)
        self.after["control"] = {"lastAttempt": self.success_time, "lastSuccess": self.success_time,
                                 "leaseActive": False, "nextAllowed": self.clock.iso(63)}
        self.after["snapshots"] = {"active": 1, "publishedRecently": 1, "publishedAt": self.success_time,
                                   "observedAt": self.success_time, "fetchedAt": self.success_time, "records": 101}

    def database(self):
        self.db_reads += 1
        value = copy.deepcopy(self.before if self.db_reads <= 2 else self.after)
        value["now"] = self.clock.iso()
        return value

    def queue(self):
        self.queue_reads += 1
        return {**quiet(), "completedLastMinute": 0 if self.queue_reads <= 2 else 1}

    def request(self, url, method, headers, payload=None, timeout=30):
        with self.lock:
            self.calls.append((url, method, headers, payload, timeout))
            if url.endswith("/token"):
                return 200, {"accessToken": "private-token" * 4, "tokenType": "Bearer", "expiresInSeconds": 900}, {}
            if url.endswith(("/ready", "/ready/auth")):
                return 200, {"status": "ready", "release": self.config["backendImage"].split("@", 1)[1]}, {}
            if url.endswith("/search"):
                swiss = payload["route"]["coordinates"][0][0] == 8.5417
                candidate = {"id": "00000000-0000-4000-8000-00000000000" + ("1" if swiss else "2"),
                             "sources": [{"id": "ich_tanke_strom" if swiss else "bundesnetzagentur"}],
                             "operators": ["Private-memory-public-operator"], "chargingPoints": 4}
                return 200, {"candidates": [candidate], "availabilityContext": "private-context-" + str(swiss)}, {}
            assert url.endswith("/availability")
            swiss = payload["context"].endswith("True")
            if swiss: self.ch_requests += 1
            values = {"knownAvailable": 0, "knownUnavailable": 0, "unknown": 4, "total": 4, "complete": False}
            if swiss and self.ch_requests >= 3:
                values = {"knownAvailable": 2, "knownUnavailable": 1, "unknown": 1, "total": 4,
                          "complete": False, "observedAt": self.success_time}
            return 200, {"context": payload["context"], "generatedAt": self.clock.iso(),
                         "expiresAt": self.clock.iso(3600), "refreshPending": swiss and self.ch_requests <= 2,
                         "candidates": [{**payload["candidates"][0], "availability": values}]}, {}

    def run(self, **overrides):
        args = {"config": self.config, "token_provider": lambda _: "private-identity" * 4,
                "database": self.database, "queue": self.queue, "request": self.request,
                "sleep": self.clock.sleep, "wall": self.clock.now, "monotonic": self.clock.now}
        return live.verify(**(args | overrides))


class LiveGateTests(unittest.TestCase):
    def test_full_gate_binds_release_and_observes_one_publish_without_logging_private_payloads(self):
        fixture = Fixture()
        report = fixture.run()
        self.assertTrue(report["liveTaskCompatibilityPassed"])
        self.assertEqual(report["release"], live.release_id(fixture.config))
        self.assertEqual(report["observedCompletedDispatches"], 1)
        self.assertEqual(sum(url.endswith("/search") for url, *_ in fixture.calls), 2)
        self.assertEqual(sum(url.endswith("/availability") for url, *_ in fixture.calls), 4)
        self.assertEqual(fixture.ch_requests, 3)
        text = json.dumps(report)
        for private in ("private", "operator", "coordinates", "availabilityContext", "00000000", "tasks/"):
            self.assertNotIn(private, text)

    def test_busy_queue_fresh_cache_and_cooldown_abort_before_token_mint(self):
        for fault in ("queue", "fresh", "lease", "cooldown"):
            with self.subTest(fault=fault):
                fixture = Fixture()
                if fault == "fresh": fixture.before["snapshots"]["observedAt"] = fixture.clock.iso()
                if fault in ("lease", "cooldown"):
                    fixture.before["control"] = {"leaseActive": fault == "lease", "nextAllowed": fixture.clock.iso(60)}
                with self.assertRaises(live.VerificationError):
                    fixture.run(**({"queue": lambda: {**quiet(), "inFlight": 1}} if fault == "queue" else {}))
                self.assertEqual(fixture.calls, [])

    def test_de_side_effect_aborts_before_any_swiss_refresh(self):
        fixture = Fixture()
        def queue():
            fixture.queue_reads += 1
            return {**quiet(), "completedLastMinute": int(fixture.queue_reads > 1)}
        with self.assertRaisesRegex(live.VerificationError, "DE-only"):
            fixture.run(queue=queue)
        self.assertEqual(fixture.ch_requests, 0)

    def test_multiple_dispatches_or_publications_and_wrong_task_fail_closed(self):
        for fault in ("dispatches", "publications", "task"):
            with self.subTest(fault=fault):
                fixture = Fixture()
                if fault == "publications": fixture.after["snapshots"]["publishedRecently"] = 2
                def queue():
                    result = fixture.queue()
                    if fixture.queue_reads >= 3:
                        if fault == "dispatches": result["completedLastMinute"] = 2
                        if fault == "task": result["names"] = {live.QUEUE_PATH + "/tasks/unrelated"}
                    return result
                with self.assertRaises(live.VerificationError): fixture.run(queue=queue)
                self.assertEqual(fixture.ch_requests, 2)

    def test_missing_success_or_publish_does_not_become_success_and_never_retriggers(self):
        for field in ("lastSuccess", "publishedRecently"):
            fixture = Fixture()
            if field == "lastSuccess": fixture.after["control"][field] = None
            else: fixture.after["snapshots"][field] = 0
            with self.assertRaisesRegex(live.VerificationError, "three minutes"):
                fixture.run()
            self.assertEqual(fixture.ch_requests, 2)
            self.assertLessEqual(fixture.queue_reads, 39)

    def test_bad_response_and_injected_private_error_are_redacted(self):
        for fault in ("total", "private_error", "wrong_release"):
            fixture = Fixture()
            def request(url, *args, **kwargs):
                if fault == "private_error": raise RuntimeError("private credentials and precise route")
                status, body, headers = fixture.request(url, *args, **kwargs)
                if fault == "total" and url.endswith("/availability"):
                    body["candidates"][0]["availability"]["total"] = 5
                if fault == "wrong_release" and url.endswith("/ready"):
                    body["release"] = "sha256:" + "0" * 64
                return status, body, headers
            with self.assertRaises(live.VerificationError) as caught: fixture.run(request=request)
            self.assertNotIn("credentials", str(caught.exception))
            self.assertNotIn("precise", str(caught.exception))

    def test_database_target_and_read_only_subprocess_are_strict_without_secret_file_access(self):
        environment = {"PGHOST": live.SOCKET, "PGUSER": "nextstop_app", "PGDATABASE": "nextstop", "PGPASSWORD": "private-password"}
        for key, value in (("PGHOST", "/production"), ("PGDATABASE", "postgres"), ("PGUSER", "postgres"), ("PGPORT", "5433")):
            with self.assertRaises(live.VerificationError): live.Database("/psql", environment | {key: value})
        fixture = Fixture()
        with patch.object(live.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(fixture.before), "private-stderr")) as run:
            database = live.Database("/psql", environment | {"PGSERVICE": "production", "PGOPTIONS": "unsafe"})
            database()
            self.assertIn("BEGIN READ ONLY", run.call_args.kwargs["input"])
            self.assertIn("ROLLBACK", run.call_args.kwargs["input"])
            self.assertNotIn("PGSERVICE", run.call_args.kwargs["env"])
            self.assertEqual(run.call_args.kwargs["env"]["PGOPTIONS"], "-c default_transaction_read_only=on")
            self.assertNotIn("private-password", str(run.call_args.args))

    def test_cloud_adapter_only_gets_fixed_staging_metadata_and_excludes_task_payloads(self):
        config = configuration()
        calls = []
        def request(url, method, headers, timeout=30):
            calls.append(url)
            self.assertEqual(method, "GET")
            if "-run.googleapis.com" in url:
                expected = "nextstop-live-" + live.release_id(config)
                return 200, {"status": {"traffic": [{"revisionName": expected, "percent": 100}]},
                             "spec": {"template": {"metadata": {"name": expected}, "spec": {"containers": [{"image": config["backendImage"]}]}}}}, {}
            if "/tasks?" in url: return 200, {}, {}
            return 200, {"state": "RUNNING", "stats": {}}, {}
        with patch.object(live.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "private-access-token" * 3, "")):
            metadata = live.CloudMetadata(config, request=request)
        metadata.verify_live_target()
        self.assertTrue(live.quiet(metadata()))
        self.assertIn("responseView=BASIC", calls[-1])
        self.assertIn("fields=tasks(name),nextPageToken", calls[-1])
        self.assertTrue(all(live.PROJECT in url for url in calls))


if __name__ == "__main__": unittest.main()
