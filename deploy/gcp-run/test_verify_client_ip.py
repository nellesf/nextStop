"""Local protocol/limiter tests. The remote Python is never given a probe command here."""
import json
import subprocess
import sys
import unittest

import verify
import verify_client_ip as probe


def sample(kind):
    return {"kind": kind, "status": 400 if kind == "schema_rejected" else 429, "latencyMs": 1.0}


class IsolationTests(unittest.TestCase):
    def test_separate_buckets_and_prefix_resistance_require_A429_B400_A429(self):
        calls = []
        def first(sequence):
            calls.append(("operator", sequence))
            return sample("schema_rejected" if sequence < 6 else "gateway_rate_limited")
        def second(sequence):
            calls.append(("staging-vm", sequence))
            return sample("schema_rejected")
        result = probe.prove_isolation(first, second, lambda: 0)
        self.assertTrue(result["clientIPIsolationPassed"])
        self.assertTrue(result["xffPrefixResistancePassed"])
        self.assertEqual(calls[-3:], [("operator", 6), ("staging-vm", 2), ("operator", 20)])
        self.assertEqual(len(result["samples"]), 9)
        self.assertNotIn("192.0.2", json.dumps(result))

    def test_global_bucket_is_not_mistaken_for_distinct_real_client_isolation(self):
        calls = 0
        def shared(_sequence):
            nonlocal calls
            calls += 1
            return sample("schema_rejected" if calls <= 5 else "gateway_rate_limited")
        with self.assertRaisesRegex(verify.VerificationError, "separate source"):
            probe.prove_isolation(shared, shared, lambda: 0)

    def test_trusting_spoofed_prefixes_never_passes_and_stops_after_bounded_requests(self):
        calls = 0
        def unbounded(_sequence):
            nonlocal calls
            calls += 1
            return sample("schema_rejected")
        with self.assertRaisesRegex(verify.VerificationError, "did not exhaust"):
            probe.prove_isolation(unbounded, unbounded, lambda: 0)
        self.assertEqual(calls, 10)

    def test_refill_during_round_trip_cannot_forge_success(self):
        def first(sequence):
            return sample("gateway_rate_limited" if sequence == 6 else "schema_rejected")
        with self.assertRaisesRegex(verify.VerificationError, "refilled or changed"):
            probe.prove_isolation(first, lambda _: sample("schema_rejected"), lambda: 0)

    def test_transport_errors_preexisting_limit_or_slow_exhaustion_fail_closed(self):
        with self.assertRaisesRegex(verify.VerificationError, "independently ready"):
            probe.prove_isolation(lambda _: sample("schema_rejected"), lambda _: sample("gateway_rate_limited"))
        with self.assertRaisesRegex(verify.VerificationError, "probe failed"):
            probe.prove_isolation(lambda _: sample("schema_rejected"), lambda _: {"kind": "failed"})
        with self.assertRaisesRegex(verify.VerificationError, "time budget"):
            probe.prove_isolation(lambda _: sample("schema_rejected"), lambda _: sample("schema_rejected"), iter([0, 11]).__next__)

    def test_local_http_uses_only_fixed_invalid_schema_and_redacts_all_response_fields(self):
        token = "synthetic-private-identity" * 3
        def request(url, method, headers, payload, timeout):
            self.assertEqual(url, "https://r-1c907fe7c046---nextstop-gateway-353471052580.europe-west1.run.app/v1/auth/app-attest/challenge")
            self.assertEqual(method, "POST"); self.assertEqual(timeout, 3)
            self.assertEqual(payload, {"syntheticInvalidField": True})
            self.assertEqual(headers["X-Serverless-Authorization"], "Bearer " + token)
            self.assertEqual(headers["X-Forwarded-For"], "192.0.2.2, 198.51.100.2")
            return 400, {"type": "urn:nextstop:error:invalid-app-attest-request", "private": "discard"}, {"x-request-id": "synthetic"}
        result = probe.local_probe("1c907fe7c046", token, 2, request, lambda: 0)
        self.assertEqual(result, {"kind": "schema_rejected", "status": 400, "latencyMs": 0})
        self.assertNotIn(token, json.dumps(result))

    def test_remote_command_is_exact_staging_target_with_no_dynamic_credential_argument(self):
        command = probe.remote_command()
        self.assertEqual(command[:4], ["gcloud", "compute", "ssh", "nextstop-backend"])
        self.assertIn("--project=nextstop-tech-testing", command)
        self.assertIn("--zone=europe-west3-a", command)
        self.assertIn("--tunnel-through-iap", command)
        self.assertIn("--ssh-flag=-T", command)
        self.assertNotIn("sudo", " ".join(command))
        self.assertNotIn("nextstop-tech-staging", " ".join(command))

    def test_real_remote_protocol_starts_and_stops_locally_without_any_network_request(self):
        token = "synthetic-private-identity" * 3
        for public in (False, True):
            result = subprocess.run([sys.executable, "-u", "-c", probe.REMOTE_SCRIPT],
                input=json.dumps({"release": "1c907fe7c046", "identityToken": None if public else token, "public": public}) + '\n{"operation":"stop"}\n',
                capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, "")
            self.assertEqual(result.stdout.splitlines(), ['NEXTSTOP_IP_PROBE:{"kind":"ready"}', 'NEXTSTOP_IP_PROBE:{"kind":"configured"}'])
            self.assertNotIn(token, result.stdout)

    def test_public_mode_is_fixed_and_sends_no_private_iam_token(self):
        def request(url, method, headers, payload, timeout):
            self.assertEqual(url, "https://api-staging.nextstop.tech/v1/auth/app-attest/challenge")
            self.assertNotIn("X-Serverless-Authorization", headers)
            return 400, {"type": "urn:nextstop:error:invalid-app-attest-request"}, {"x-request-id": "synthetic"}
        self.assertEqual(probe.local_probe("1c907fe7c046", None, 1, request, lambda: 0, public=True)["kind"], "schema_rejected")
        for revision, public in (("https://arbitrary.example", False), ("1c907fe7c046", "https://arbitrary.example"),
                                 ("1c907fe7c046", 1)):
            with self.assertRaises(verify.VerificationError): probe.gateway_origin(revision, public)

    def test_remote_public_and_private_target_selection_with_mock_http_has_no_arbitrary_origin(self):
        for public in (False, True):
            # Execute the actual remote parser/URL builder in an isolated local
            # process with a fake opener. No DNS or HTTP operation is performed.
            prelude = '''
import urllib.request
class Response:
    status=400
    headers={"X-Request-ID":"synthetic"}
    def read(self,n): return b'{"type":"urn:nextstop:error:invalid-app-attest-request"}'
    def close(self): pass
class Client:
    def open(self,request,timeout):
        assert request.full_url==EXPECTED
        assert (request.get_header("X-serverless-authorization") is None)==PUBLIC
        return Response()
urllib.request.build_opener=lambda *args:Client()
'''
            prelude = "EXPECTED=" + repr(probe.gateway_origin("1c907fe7c046", public) + "/v1/auth/app-attest/challenge") + "\nPUBLIC=" + repr(public) + "\n" + prelude
            result = subprocess.run([sys.executable, "-u", "-c", prelude + probe.REMOTE_SCRIPT],
                input=json.dumps({"release": "1c907fe7c046", "identityToken": None if public else "synthetic-token" * 4, "public": public}) +
                    '\n{"operation":"probe","sequence":1}\n{"operation":"stop"}\n',
                capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"kind":"schema_rejected"', result.stdout)


if __name__ == "__main__":
    unittest.main()
