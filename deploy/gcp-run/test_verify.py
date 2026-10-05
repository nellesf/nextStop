"""Synthetic HTTP/control-plane tests; no token mint, network, provider or database activity."""
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

import render
from test_render import configuration
import verify


class SyntheticHTTP:
    def __init__(self, config, public=False):
        self.config, self.public = config, public
        self.calls = []
        self.probes = 0
        self.limiter = True
        self.digest = config["backendImage"].split("@", 1)[1]

    def __call__(self, url, method, headers, payload=None, timeout=30):
        self.calls.append((url, method, headers, payload, timeout))
        tag = "r-" + render.release_id(self.config)
        if url == render.origin("broker", tag) + "/token":
            assert method == "POST" and payload is None
            assert headers == {"Authorization": "Bearer " + "private-identity" * 3}
            return 200, {"accessToken": "private-app-token" * 3, "expiresInSeconds": 900, "tokenType": "Bearer"}, {}
        base = "https://api-staging.nextstop.tech" if self.public else render.origin("gateway", tag)
        assert url.startswith(base + "/")
        assert headers["Authorization"] == "Bearer " + "private-app-token" * 3
        assert ("X-Serverless-Authorization" in headers) is not self.public
        if url.endswith(("/ready", "/ready/auth")):
            return 200, {"status": "ready", "release": self.digest}, {}
        if url.endswith("/v1/charging-parks/search"):
            assert payload["route"]["coordinates"] == [[8.68, 50.11], [9.12, 49.9], [9.57, 49.77]]
            assert "profile" not in payload
            return 200, {"candidates": [{"id": "synthetic-public-location"}], "snapshotToken": "private-snapshot"}, {}
        assert url.endswith("/v1/auth/app-attest/challenge")
        assert payload == {"syntheticInvalidField": True} and timeout == 3
        assert headers["X-Forwarded-For"] == f"192.0.2.{self.probes + 1}, 198.51.100.{self.probes + 1}"
        self.probes += 1
        if self.limiter and self.probes >= 6:
            return 429, {"type": "urn:nextstop:error:rate-limited"}, {"retry-after": "5"}
        return 400, {"type": "urn:nextstop:error:invalid-request"}, {"x-request-id": "synthetic"}


def identity(_audience):
    return "private-identity" * 3


class VerificationTests(unittest.TestCase):
    def test_candidate_is_release_bound_and_runs_one_search_without_live_refresh_or_auth_mutations(self):
        config = configuration()
        client = SyntheticHTTP(config)
        gates = verify.verify(config, identity, request=client, monotonic=lambda: 0)
        self.assertEqual(gates, {gate: True for gate in verify.SMOKE_GATES})
        self.assertNotIn("clientIPIsolationPassed", gates)
        self.assertEqual(len(client.calls), 12)
        self.assertEqual(sum(url.endswith("/search") for url, *_ in client.calls), 1)
        self.assertEqual(client.probes, 8)
        report = verify.smoke_report(config, gates, datetime(2026, 10, 4, tzinfo=timezone.utc))
        self.assertEqual(report["release"], render.release_id(config))
        self.assertEqual(report["image"], config["backendImage"])
        self.assertNotIn("private", json.dumps(report))
        self.assertNotIn("coordinates", json.dumps(report))

    def test_public_postcheck_has_fixed_origin_and_never_repeats_auth_limiter_probe(self):
        config = configuration()
        client = SyntheticHTTP(config, public=True)
        self.assertEqual(verify.verify_public(config, identity, request=client),
                         {gate: True for gate in verify.SMOKE_GATES if gate != "xffPrefixResistancePassed"})
        self.assertEqual(len(client.calls), 4)
        self.assertEqual(client.probes, 0)

    def test_missing_throttle_slow_probe_or_wrong_limiter_cannot_be_reported_as_success(self):
        config = configuration()
        client = SyntheticHTTP(config)
        client.limiter = False
        with self.assertRaisesRegex(verify.VerificationError, "not demonstrated"):
            verify.verify(config, identity, request=client, monotonic=lambda: 0)
        with self.assertRaisesRegex(verify.VerificationError, "inconclusive"):
            verify.prove_prefix_resistance("https://synthetic", {}, client, iter([0, 11]).__next__)
        for body, headers in [({"type": "urn:nextstop:error:auth-capacity-exhausted"}, {"retry-after": "5"}),
                              ({"type": "urn:nextstop:error:rate-limited"}, {"retry-after": "5", "x-request-id": "upstream"})]:
            with self.assertRaisesRegex(verify.VerificationError, "Unexpected limiter"):
                verify.prove_prefix_resistance("https://synthetic", {}, lambda *a, **kw: (429, body, headers), lambda: 0)

    def test_wrong_release_empty_search_and_malformed_mint_fail_without_printing_payload(self):
        config = configuration()
        for fault in ("release", "search", "token", "exception"):
            with self.subTest(fault=fault):
                client = SyntheticHTTP(config)
                if fault == "release":
                    client.digest = "sha256:" + "c" * 64
                def request(url, *args, **kwargs):
                    if fault == "search" and url.endswith("/search"):
                        return 200, {"candidates": [], "snapshotToken": "private-snapshot"}, {}
                    if fault == "token":
                        return 200, {"private-token": "secret"}, {}
                    if fault == "exception":
                        raise RuntimeError("sensitive subprocess stdout or route")
                    return client(url, *args, **kwargs)
                with self.assertRaises(verify.VerificationError) as caught:
                    verify.verify(config, identity, request=request, monotonic=lambda: 0)
                self.assertNotIn("sensitive", str(caught.exception))
                self.assertNotIn("private-token", str(caught.exception))

    def test_identity_stdout_is_captured_and_impersonation_cannot_target_production(self):
        with self.assertRaises(verify.VerificationError):
            verify.identity_provider("nextstop-run-deploy@nextstop-tech-staging.iam.gserviceaccount.com")
        account = render.account("deploy")
        completed = subprocess.CompletedProcess([], 0, "synthetic-identity-token" * 3 + "\n", "")
        with patch.object(verify.subprocess, "run", return_value=completed) as execute:
            tokens = verify.identity_provider(account)
            self.assertEqual(tokens(render.origin("gateway")), completed.stdout.strip())
            tokens(render.origin("gateway"))
            self.assertEqual(execute.call_count, 1)
            command = execute.call_args.args[0]
            self.assertIn("--audiences=" + render.origin("gateway"), command)
            self.assertIn("--impersonate-service-account=" + account, command)
            self.assertNotIn(completed.stdout.strip(), command)
        completed = subprocess.CompletedProcess([], 1, "private-stdout", "private-stderr")
        with patch.object(verify.subprocess, "run", return_value=completed), self.assertRaises(verify.VerificationError) as caught:
            verify.identity_provider()(render.origin("gateway"))
        self.assertNotIn("private", str(caught.exception))

    def test_transport_rejects_redirect_html_compression_and_excessive_bytes(self):
        class Response(io.BytesIO):
            status = 200
            headers = {}
        for response in [Response(b"<html>private error</html>"), Response(b"x" * (verify.MAXIMUM_RESPONSE_BYTES + 1))]:
            with patch.object(verify.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                with self.assertRaises(verify.VerificationError):
                    verify.request_json("https://synthetic.run.app/ready", "GET", {})
                self.assertTrue(response.closed)
        response = Response(b'{}'); response.headers = {"Content-Encoding": "gzip"}
        with patch.object(verify.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaises(verify.VerificationError):
                verify.request_json("https://synthetic.run.app/ready", "GET", {})
        self.assertIsNone(verify.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://private.example"))

    def test_partial_report_is_private_create_only_and_never_synthesizes_manual_gates(self):
        config = configuration()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "smoke.json"
            report = verify.smoke_report(config, {gate: True for gate in verify.SMOKE_GATES})
            verify.write_report(path, report)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                verify.write_report(path, report)
            self.assertNotIn("clientIPIsolationPassed", json.loads(path.read_text()))
        with self.assertRaises(verify.VerificationError):
            verify.smoke_report(config, {gate: gate != "apiReady" for gate in verify.SMOKE_GATES})


if __name__ == "__main__":
    unittest.main()
