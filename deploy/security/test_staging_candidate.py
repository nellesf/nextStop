import copy
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("candidate", Path(__file__).with_name("validate-staging-candidate.py"))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
IMAGE = candidate.REGISTRY + "@sha256:" + "a" * 64
COMMIT = "b" * 40
TOKEN = "token" * 16


def fixtures():
    result = {}
    for name in candidate.SERVICES:
        env = [{"name": "HOST", "value": "0.0.0.0"}]
        for variable, secret in candidate.SECRET_NAMES.get(name, {}).items():
            env.append({"name": variable, "valueFrom": {"secretKeyRef": {
                "name": "nextstop-staging-" + secret, "key": "1"}}})
        service = {
            "metadata": {"name": "nextstop-" + name, "namespace": candidate.NUMBER,
                         "resourceVersion": "123", "annotations": {"run.googleapis.com/invoker-iam-disabled": "false"}},
            "spec": {"template": {"metadata": {"name": "nextstop-" + name + "-old",
                        "annotations": {"run.googleapis.com/cloudsql-instances": candidate.CONNECTION}},
                      "spec": {"serviceAccountName": f"nextstop-run-{name}@{candidate.PROJECT}.iam.gserviceaccount.com",
                               "containers": [{"image": candidate.REGISTRY + "@sha256:" + "c" * 64,
                                               "command": ["node"], "args": ["dist/src/server.js"], "env": env,
                                               "ports": [{"containerPort": 8080}]}]}}},
        }
        traffic = [{"revisionName": "nextstop-" + name + "-old", "percent": 100, "tag": "r-old"},
                   {"revisionName": "nextstop-" + name + "-retained", "percent": 0, "tag": "r-retained"}]
        service["spec"]["traffic"] = copy.deepcopy(traffic)
        service["status"] = {"traffic": copy.deepcopy(traffic), "latestReadyRevisionName": "nextstop-" + name + "-old"}
        result[name] = {"service": service, "iam": {"bindings": [{"role": "roles/run.invoker", "members": ["user:operator@example.invalid"]}]}}
    return result


def applied(before, proposed):
    after = copy.deepcopy(before)
    for name in ("api", "auth"):
        service = copy.deepcopy(proposed["manifests"][name])
        service["status"] = {"latestReadyRevisionName": service["spec"]["template"]["metadata"]["name"],
                             "url": candidate.origin(name),
                             "traffic": copy.deepcopy(service["spec"]["traffic"])}
        for row in service["status"]["traffic"]:
            if row.get("tag") == proposed["tag"]:
                row["url"] = f"https://{proposed['tag']}---nextstop-{name}-{candidate.NUMBER}.{candidate.REGION}.run.app"
        after[name]["service"] = service
    return after


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.before = fixtures()
        self.proposed = candidate.plan(self.before, IMAGE, COMMIT)
        self.after = applied(self.before, self.proposed)

    def test_prepare_requires_selected_child_for_both_index_and_direct_commit_tags(self):
        parent = candidate.REGISTRY + "@sha256:" + "d" * 64
        for tag_image, requested in ((parent, IMAGE), (IMAGE, IMAGE), (parent, parent),
                                     (parent, candidate.REGISTRY + "@sha256:" + "e" * 64)):
            with self.subTest(tag_image=tag_image, requested=requested), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "candidate.json"
                arguments = ["candidate.py", "--commit", COMMIT, "--image", requested, "--output", str(output)]
                selected = {"commit": COMMIT, "tagImage": tag_image, "image": IMAGE,
                            "manifestAndConfigHashesVerified": True, "platform": "linux/amd64"}
                with patch("sys.argv", arguments), patch("sys.stdout", new=io.StringIO()), \
                        patch.object(candidate, "snapshot", return_value=self.before), \
                        patch.object(candidate, "select_image", return_value=selected), \
                        patch.object(candidate, "run") as mutation:
                    if requested == IMAGE:
                        candidate.main()
                    else:
                        with self.assertRaises(SystemExit):
                            candidate.main()
                    mutation.assert_not_called()
                receipt = json.loads(output.read_text())
                if requested == IMAGE:
                    self.assertEqual(receipt["phase"], "prepared-read-only")
                    self.assertEqual(receipt["registryIdentity"], selected)
                else:
                    self.assertEqual(receipt["phase"], "failed")
                    self.assertFalse(output.with_suffix(".plan.json").exists())

    def test_plan_retains_every_old_traffic_entry_and_secret_pin(self):
        for name in ("api", "auth"):
            actual = self.proposed["manifests"][name]
            self.assertEqual(actual["spec"]["traffic"][:-1], self.before[name]["service"]["spec"]["traffic"])
            self.assertEqual(actual["spec"]["traffic"][-1]["percent"], 0)
            self.assertEqual(actual["spec"]["template"]["spec"]["containers"][0]["image"], IMAGE)
            original = self.before[name]["service"]["spec"]["template"]["spec"]["containers"][0]["env"]
            proposed = actual["spec"]["template"]["spec"]["containers"][0]["env"]
            self.assertEqual([row for row in original if "valueFrom" in row], [row for row in proposed if "valueFrom" in row])
        self.assertEqual(set(self.proposed["manifests"]), {"api", "auth"})
        candidate.verify_unchanged(self.before, self.after, self.proposed["manifests"], ["api", "auth"])

    def split_spec(self):
        before = copy.deepcopy(self.before)
        for name in ("api", "auth"):
            original = before[name]["service"]["spec"]["traffic"][0]
            before[name]["service"]["spec"]["traffic"] = [
                {"revisionName": original["revisionName"], "percent": 100},
                {"revisionName": original["revisionName"], "tag": original["tag"]},
                before[name]["service"]["spec"]["traffic"][1],
            ]
        return before

    def test_split_spec_and_combined_status_preserve_original_rows(self):
        before = self.split_spec()
        proposed = candidate.plan(before, IMAGE, COMMIT)
        after = applied(before, proposed)
        for name in ("api", "auth"):
            self.assertEqual(proposed["manifests"][name]["spec"]["traffic"][:-1], before[name]["service"]["spec"]["traffic"])
            # The platform consolidates the existing tag into the weighted row.
            existing_status = copy.deepcopy(before[name]["service"]["status"]["traffic"])
            after[name]["service"]["status"]["traffic"] = existing_status + [after[name]["service"]["status"]["traffic"][-1]]
        candidate.verify_unchanged(before, after, proposed["manifests"], ["api", "auth"])

    def test_semantic_comparison_rejects_weight_tag_and_candidate_traffic_drift(self):
        before = self.split_spec()
        proposed = candidate.plan(before, IMAGE, COMMIT)
        for drift in ("weight", "tag", "candidate"):
            after = applied(before, proposed)
            rows = after["api"]["service"]["status"]["traffic"]
            if drift == "weight":
                rows[0]["percent"] = 90
                rows[2]["percent"] = 10
            elif drift == "tag":
                rows[1]["revisionName"] = "nextstop-api-retained"
            else:
                rows[0]["percent"] = 99
                rows[-1]["percent"] = 1
            with self.subTest(drift=drift), self.assertRaises(candidate.CandidateError):
                candidate.verify_unchanged(before, after, proposed["manifests"], ["api", "auth"])

    def test_public_iam_is_rejected_even_if_conditional(self):
        for public in ("allUsers", "allAuthenticatedUsers"):
            with self.subTest(public=public):
                before = copy.deepcopy(self.before)
                before["api"]["iam"]["bindings"][0]["members"].append(public)
                with self.assertRaises(candidate.CandidateError):
                    candidate.plan(before, IMAGE, COMMIT)

    def test_invoker_check_cannot_be_disabled(self):
        self.before["auth"]["service"]["metadata"]["annotations"]["run.googleapis.com/invoker-iam-disabled"] = "true"
        with self.assertRaises(candidate.CandidateError):
            candidate.plan(self.before, IMAGE, COMMIT)

    def test_unpinned_or_unsettled_traffic_cannot_be_replaced(self):
        for change in ("latest", "status"):
            before = copy.deepcopy(self.before)
            if change == "latest":
                before["api"]["service"]["spec"]["traffic"][0]["latestRevision"] = True
            else:
                before["api"]["service"]["status"]["traffic"][0]["revisionName"] = "nextstop-api-other"
            with self.assertRaises(candidate.CandidateError):
                candidate.plan(before, IMAGE, COMMIT)

    def test_unknown_plaintext_secret_and_mutable_secret_pin_fail(self):
        for mode in ("unknown", "latest", "plaintext", "role", "socket"):
            before = copy.deepcopy(self.before)
            spec = before["api"]["service"]["spec"]["template"]["spec"]
            env = spec["containers"][0]["env"]
            if mode == "unknown":
                env.append({"name": "UNREVIEWED_SECRET", "value": "sensitive"})
            elif mode == "latest":
                env[1]["valueFrom"]["secretKeyRef"]["key"] = "latest"
            elif mode == "plaintext":
                env[1] = {"name": "DATABASE_URL", "value": "sensitive"}
            elif mode == "role":
                spec["serviceAccountName"] = "wrong@example.invalid"
            else:
                before["api"]["service"]["spec"]["template"]["metadata"]["annotations"]["run.googleapis.com/cloudsql-instances"] = "other"
            with self.subTest(mode=mode), self.assertRaises(candidate.CandidateError):
                candidate.plan(before, IMAGE, COMMIT)

    def test_existing_candidate_is_not_repointed(self):
        with self.assertRaises(candidate.CandidateError):
            candidate.plan(self.after, IMAGE, COMMIT)

    def test_traffic_gateway_iam_or_candidate_runtime_drift_blocks_receipt(self):
        for mode in ("traffic", "gateway", "iam", "image", "unready"):
            after = copy.deepcopy(self.after)
            if mode == "traffic":
                after["api"]["service"]["spec"]["traffic"][0]["percent"] = 99
            elif mode == "gateway":
                after["gateway"]["service"]["spec"]["template"]["spec"]["containers"][0]["image"] = IMAGE
            elif mode == "iam":
                after["auth"]["iam"]["bindings"][0]["members"].append("user:unexpected@example.invalid")
            elif mode == "image":
                after["api"]["service"]["spec"]["template"]["spec"]["containers"][0]["image"] = "wrong"
            else:
                after["api"]["service"]["status"]["latestReadyRevisionName"] = "nextstop-api-old"
            with self.subTest(mode=mode), self.assertRaises(candidate.CandidateError):
                candidate.verify_unchanged(self.before, after, self.proposed["manifests"], ["api", "auth"])

    def response(self, url, method, headers, payload=None):
        if url.endswith("/token"):
            return {"accessToken": TOKEN, "expiresInSeconds": 300, "tokenType": "Bearer"}
        if url.endswith("/ready"):
            return {"status": "ready", "release": IMAGE.split("@", 1)[1]}
        self.assertEqual(headers["Authorization"], "Bearer " + TOKEN)
        self.assertIn("X-Serverless-Authorization", headers)
        self.assertEqual(payload["route"]["coordinates"][0], [8.68, 50.11])
        return {"candidates": [{"id": "synthetic"}], "snapshotToken": "fixture"}

    def test_smoke_requires_both_readiness_checks_and_authenticated_search(self):
        calls = []
        def request(*args):
            calls.append(args[0])
            return self.response(*args)
        checks = candidate.smoke(self.after, self.proposed, TOKEN, request, lambda url: None)
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(checks.values()))
        self.assertEqual(sum(url.endswith("/ready") for url in calls), 2)

    def test_bad_broker_digest_empty_search_and_http_failure_never_pass(self):
        for mode in ("broker", "digest", "search", "network"):
            def request(url, method, headers, payload=None):
                if mode == "broker" and url.endswith("/token"):
                    return {"accessToken": "bad"}
                if mode == "digest" and "---nextstop-auth-" in url:
                    return {"status": "ready", "release": "sha256:wrong"}
                if mode == "search" and url.endswith("/search"):
                    return {"candidates": [], "snapshotToken": "fixture"}
                if mode == "network":
                    raise candidate.CandidateError("Network unavailable")
                return self.response(url, method, headers, payload)
            with self.subTest(mode=mode), self.assertRaises(candidate.CandidateError):
                candidate.smoke(self.after, self.proposed, TOKEN, request, lambda url: None)

    def test_wrong_candidate_tag_host_cannot_receive_tokens(self):
        self.after["api"]["service"]["status"]["traffic"][-1]["url"] = "https://example.invalid"
        with self.assertRaises(candidate.CandidateError):
            candidate.smoke(self.after, self.proposed, TOKEN, self.response, lambda url: None)

    def test_anonymous_access_check_is_required_before_candidate_requests(self):
        def public_candidate(url):
            raise candidate.CandidateError("Anonymous access was unexpectedly permitted")
        with self.assertRaises(candidate.CandidateError):
            candidate.smoke(self.after, self.proposed, TOKEN, self.response, public_candidate)

    @unittest.skipUnless(shutil.which("node"), "Node is needed to execute the staging-only wrapper")
    def test_wrapper_uses_fixed_socket_without_modifying_secrets_or_leaking_failures(self):
        wrapper = candidate.wrapper("api").replace("await import('/app/dist/src/server.js');", "console.log(JSON.stringify({api:process.env.DATABASE_URL,support:process.env.SUPPORT_DATABASE_URL}));")
        base = {"DATABASE_URL": "postgresql://nextstop_api:synthetic%40pass@localhost/nextstop",
                "SUPPORT_DATABASE_URL": "postgresql://nextstop_support:synthetic@localhost/nextstop"}
        result = subprocess.run([shutil.which("node"), "--input-type=module", "-e", wrapper], env=base, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        value = json.loads(result.stdout)
        self.assertIn("host=%2Fcloudsql%2Fnextstop-tech-testing%3Aeurope-west1%3Anextstop-staging", value["api"])
        self.assertIn("synthetic%40pass", value["api"])
        for invalid in ("postgresql://nextstop_api:sensitive@remote.example/nextstop", "not-a-url-sensitive",
                        base["DATABASE_URL"] + "?host=/arbitrary", "postgresql://nextstop_auth:sensitive@localhost/nextstop"):
            result = subprocess.run([shutil.which("node"), "--input-type=module", "-e", wrapper], env={**base, "DATABASE_URL": invalid}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("sensitive", result.stdout + result.stderr)
            self.assertNotIn("synthetic", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
