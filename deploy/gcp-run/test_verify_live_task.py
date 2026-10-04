"""Synthetic only: no real provider, token, queue or database requests."""
import copy
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

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
        # A fast task can finish before the first list; do not invent identity evidence.
        self.assertEqual(report["observedUniqueTaskNames"], 0)
        self.assertFalse(report["expectedTaskSeen"])
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
        diagnostics = {"dispatches": "More than one completed dispatch was observed for the concurrent requests.",
                       "in_flight": "More than one in-flight dispatch was observed for the concurrent requests.",
                       "publications": "Concurrent requests caused multiple provider refreshes.",
                       "task": "An unexpected task identity was observed for the concurrent requests."}
        for fault, diagnostic in diagnostics.items():
            with self.subTest(fault=fault):
                fixture = Fixture()
                if fault == "publications": fixture.after["snapshots"]["publishedRecently"] = 2
                def queue():
                    result = fixture.queue()
                    if fixture.queue_reads >= 3:
                        if fault == "dispatches": result["completedLastMinute"] = 2
                        if fault == "in_flight": result["inFlight"] = 2
                        if fault == "task": result["names"] = {live.QUEUE_PATH + "/tasks/unrelated"}
                    return result
                with self.assertRaises(live.VerificationError) as caught: fixture.run(queue=queue)
                report = live.failure_report(caught.exception)
                self.assertEqual(report["fixedDiagnostic"], diagnostic)
                self.assertEqual(report["counters"]["observedProviderAttempts"], 1)
                self.assertEqual(report["counters"]["unexpectedTaskNameCount"], int(fault == "task"))
                self.assertNotIn("unrelated", json.dumps(report))
                self.assertNotIn("tasks/", json.dumps(report))
                self.assertTrue(all(type(value) in (bool, int) for value in report["counters"].values()))
                self.assertEqual(fixture.ch_requests, 2)

    def test_pending_estimate_can_exceed_one_but_must_settle_before_cache_reuse(self):
        fixture = Fixture()
        def queue():
            result = fixture.queue()
            if fixture.queue_reads == 3: result["estimatedPending"] = 2
            return result
        report = fixture.run(queue=queue)
        self.assertTrue(report["liveTaskCompatibilityPassed"])
        self.assertEqual(fixture.queue_reads, 5)
        self.assertEqual(report["observedUniqueTaskNames"], 0)
        self.assertFalse(report["expectedTaskSeen"])
        self.assertEqual(fixture.ch_requests, 3)

    def test_nonzero_pending_estimate_never_satisfies_first_or_final_completion(self):
        for final in (False, True):
            with self.subTest(final=final):
                fixture = Fixture()
                def queue():
                    result = fixture.queue()
                    if fixture.queue_reads >= (4 if final else 3): result["estimatedPending"] = 2
                    return result
                with self.assertRaises(live.VerificationError) as caught:
                    fixture.run(queue=queue)
                report = live.failure_report(caught.exception)
                self.assertIn("Final cache read" if final else "three minutes", report["fixedDiagnostic"])
                self.assertEqual(report["counters"]["estimatedPending"], 2)
                self.assertEqual(report["counters"]["maximumEstimatedPending"], 2)
                self.assertEqual(report["counters"]["observedUniqueTaskNames"], 0)
                self.assertFalse(report["counters"]["expectedTaskSeen"])
                self.assertEqual(fixture.ch_requests, 3 if final else 2)

    def test_expected_task_identity_is_reported_only_if_it_was_actually_listed(self):
        fixture = Fixture()
        def queue():
            result = fixture.queue()
            if fixture.queue_reads == 3:
                window = int(fixture.clock.now() // 60)
                task = live.QUEUE_PATH + "/tasks/" + hashlib.sha256(
                    ("ich_tanke_strom\0" + live.QUEUE_PATH + "\0" + str(window)).encode()).hexdigest()
                result.update(names={task}, estimatedPending=2, completedLastMinute=0, inFlight=1)
            return result
        report = fixture.run(queue=queue)
        self.assertTrue(report["liveTaskCompatibilityPassed"])
        self.assertEqual(report["observedUniqueTaskNames"], 1)
        self.assertTrue(report["expectedTaskSeen"])
        self.assertNotIn("tasks/", json.dumps(report))

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

    def paged_metadata(self, pages):
        calls = []
        remaining = iter(pages)
        def request(url, method, headers, timeout=30):
            calls.append(url)
            self.assertEqual(method, "GET")
            if "/tasks?" not in url:
                return 200, {"state": "RUNNING", "stats": {}}, {}
            query = parse_qs(urlsplit(url).query)
            self.assertEqual(query["responseView"], ["BASIC"])
            self.assertEqual(query["fields"], ["tasks(name),nextPageToken"])
            self.assertEqual(urlsplit(url).hostname, "cloudtasks.googleapis.com")
            return 200, next(remaining), {}
        with patch.object(live.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "synthetic-private-token" * 3, "")):
            metadata = live.CloudMetadata(configuration(), request=request)
        return metadata, calls

    def test_actual_partial_page_then_empty_terminal_page_is_one_task(self):
        name = live.QUEUE_PATH + "/tasks/synthetic"
        token = "opaque+/=&fields=private%20value"
        metadata, calls = self.paged_metadata([{"tasks": [{"name": name}], "nextPageToken": token}, {}])
        self.assertEqual(metadata()["names"], {name})
        self.assertEqual(parse_qs(urlsplit(calls[-1]).query)["pageToken"], [token])
        self.assertEqual(len(calls), 3)

    def test_empty_intermediate_pages_and_reordered_duplicate_names_remain_bounded(self):
        name = live.QUEUE_PATH + "/tasks/synthetic"
        metadata, calls = self.paged_metadata([{"nextPageToken": "first"}, {"tasks": [{"name": name}], "nextPageToken": "second"},
                                               {"tasks": [{"name": name}]}])
        self.assertEqual(metadata()["names"], {name})
        self.assertEqual(len(calls), 4)

    def test_page_cycles_overlength_invalid_tokens_and_page_bound_fail_closed(self):
        for pages in ([{"nextPageToken": "repeat"}, {"nextPageToken": "repeat"}],
                      [{"nextPageToken": "x" * 4097}], [{"nextPageToken": 123}],
                      [{"nextPageToken": str(index)} for index in range(4)]):
            metadata, calls = self.paged_metadata(pages)
            with self.assertRaises(live.VerificationError): metadata()
            self.assertLessEqual(len(calls), 5)

    def test_more_than_ten_unique_tasks_across_pages_still_fails_isolation(self):
        metadata, _ = self.paged_metadata([
            {"tasks": [{"name": live.QUEUE_PATH + "/tasks/" + str(index)} for index in range(10)], "nextPageToken": "next"},
            {"tasks": [{"name": live.QUEUE_PATH + "/tasks/extra"}]}])
        with self.assertRaisesRegex(live.VerificationError, "not isolated"):
            metadata()

    def test_only_allowlisted_fixed_diagnostics_are_exposed_not_injected_verification_errors(self):
        message = "Live queue metadata pagination exceeded its four-page bound."
        self.assertEqual(live.failure_report(live.VerificationError(message))["fixedDiagnostic"], message)
        for error in (live.VerificationError("private task token and route"), RuntimeError("private auth payload"),
                      live.VerificationError(message + " private token")):
            report = live.failure_report(error)
            self.assertNotIn("private", json.dumps(report))
            self.assertEqual(report["fixedDiagnostic"], "Live task gate failed without exposing diagnostic payloads.")

    def test_failure_counters_are_strictly_typed_and_untrusted_exception_attributes_are_ignored(self):
        error = live.GateFailure("private task and token", {})
        error.counters = {"estimatedPending": 2, "maximumEstimatedPending": 3, "expectedTaskSeen": False,
                          "elapsedSeconds": 5, "privateToken": "private token", "inFlight": "private body",
                          "completedLastMinute": True, "unexpectedTaskNameCount": -1,
                          "newPublications": float("nan"), "observedUniqueTaskNames": 10**30,
                          "observedProviderAttempts": ["private route"]}
        report = live.failure_report(error)
        self.assertEqual(report["counters"], {"estimatedPending": 2, "maximumEstimatedPending": 3,
                                               "expectedTaskSeen": False, "elapsedSeconds": 5})
        self.assertNotIn("private", json.dumps(report))
        injected = live.VerificationError("private transport details")
        injected.counters = {"estimatedPending": "private token"}
        self.assertNotIn("counters", live.failure_report(injected))
        fixture = Fixture()
        def request(*_args, **_kwargs): raise injected
        with self.assertRaises(live.VerificationError) as caught:
            fixture.run(request=request)
        self.assertNotIn("private", json.dumps(live.failure_report(caught.exception)))


if __name__ == "__main__": unittest.main()
