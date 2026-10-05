"""Only an exact missing immutable tag may trigger an artifact build."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from common import configuration

spec = importlib.util.spec_from_file_location("build_artifact", Path(__file__).with_name("build-artifact.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
CONFIG = configuration("staging")
COMMIT = "b" * 40
DIGEST = "sha256:" + "a" * 64
IMAGE = CONFIG["registry"] + "@" + DIGEST
HOST, REPOSITORY, PACKAGE = build.registry_resources(CONFIG)
TAG = {"name": PACKAGE + "/tags/" + COMMIT, "version": PACKAGE + "/versions/" + DIGEST}
IMMUTABLE = {"name": REPOSITORY, "format": "DOCKER", "dockerConfig": {"immutableTags": True}}


class BuildArtifactTests(unittest.TestCase):
    def test_central_registry_project_is_independent_of_staging_compute(self):
        split = {**CONFIG, "project": "nextstop-tech-testing", "registryProject": "nextstop-tech-staging"}
        self.assertEqual(build.registry_resources(split), (HOST, REPOSITORY, PACKAGE))
        self.assertIn("projects/nextstop-tech-staging/", REPOSITORY)
        with self.assertRaises(build.BuildArtifactError):
            build.registry_resources({**split, "registryProject": "nextstop-tech-testing"})
        with self.assertRaises(KeyError):
            build.registry_resources({key: value for key, value in split.items() if key != "registryProject"})

    def runner(self, *, revision=COMMIT, head=COMMIT):
        def run(arguments, **kwargs):
            if arguments[0] == "git":
                return head + "\n"
            if "inspect" in arguments:
                return revision + "\n"
            return "ignored subprocess output\n"
        return Mock(side_effect=run)

    def test_existing_tag_reuses_exact_digest_without_build_or_push(self):
        registry = Mock()
        registry.get.side_effect = [IMMUTABLE, TAG]
        run = self.runner()
        self.assertEqual(build.build_artifact(COMMIT, CONFIG, run=run, registry=registry), IMAGE)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["docker", "pull", IMAGE], commands)
        self.assertFalse(any("build" in command or "push" in command for command in commands))
        self.assertEqual(registry.get.call_args_list[1].args, (TAG["name"],))
        self.assertTrue(registry.get.call_args_list[1].kwargs["missing_ok"])

    def test_missing_tag_builds_labels_pushes_and_rechecks_exact_digest(self):
        registry = Mock()
        registry.get.side_effect = [IMMUTABLE, None, IMMUTABLE, TAG]
        run = self.runner()
        self.assertEqual(build.build_artifact(COMMIT, CONFIG, run=run, registry=registry), IMAGE)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["docker", "build", "--pull", "--label", "org.opencontainers.image.revision=" + COMMIT,
                       "--tag", CONFIG["registry"] + ":" + COMMIT, "backend"], commands)
        self.assertIn(["docker", "push", CONFIG["registry"] + ":" + COMMIT], commands)
        self.assertIn(["docker", "pull", IMAGE], commands)

    def test_security_gate_runs_for_reuse_and_fresh_and_failure_never_selects_release(self):
        for fresh in (False, True):
            with self.subTest(fresh=fresh):
                registry, run = Mock(), self.runner()
                registry.get.side_effect = [IMMUTABLE, None, IMMUTABLE, TAG] if fresh else [IMMUTABLE, TAG]
                build.build_artifact(COMMIT, CONFIG, run=run, registry=registry)
                commands = [call.args[0] for call in run.call_args_list]
                scans = [c for c in commands if any('scan-image.py' in arg for arg in c)]
                self.assertEqual(len(scans), 2 if fresh else 1)
                self.assertIn(IMAGE, scans[-1])
                if fresh:
                    self.assertLess(commands.index(scans[0]), next(i for i,c in enumerate(commands) if 'push' in c))
        registry, run = Mock(), self.runner()
        registry.get.side_effect = [IMMUTABLE, None]
        real_runner = run.side_effect
        def fail_scan(arguments, **kwargs):
            if any('scan-image.py' in arg for arg in arguments):
                raise build.BuildArtifactError('scan failed')
            return real_runner(arguments, **kwargs)
        run.side_effect = fail_scan
        with self.assertRaises(build.BuildArtifactError):
            build.build_artifact(COMMIT, CONFIG, run=run, registry=registry)
        self.assertFalse(any('push' in call.args[0] for call in run.call_args_list))

    def test_mutable_missing_or_wrong_repository_stops_before_docker(self):
        for repository in [{}, {**IMMUTABLE, "name": REPOSITORY + "-wrong"},
                           {**IMMUTABLE, "dockerConfig": {"immutableTags": False}},
                           {**IMMUTABLE, "dockerConfig": {"immutableTags": "true"}}]:
            with self.subTest(repository=repository), self.assertRaises(build.BuildArtifactError):
                registry, run = Mock(), self.runner()
                registry.get.return_value = repository
                build.build_artifact(COMMIT, CONFIG, run=run, registry=registry)
            self.assertEqual(run.call_count, 1)

    def test_lookup_failure_never_builds_or_pushes(self):
        registry, run = Mock(), self.runner()
        registry.get.side_effect = [IMMUTABLE, build.BuildArtifactError("HTTP 403")]
        with self.assertRaises(build.BuildArtifactError):
            build.build_artifact(COMMIT, CONFIG, run=run, registry=registry)
        self.assertEqual(run.call_count, 1)

    def test_wrong_checkout_or_image_revision_cannot_be_released(self):
        registry = Mock()
        with self.assertRaises(build.BuildArtifactError):
            build.build_artifact(COMMIT, CONFIG, run=self.runner(head="c" * 40), registry=registry)
        registry.get.assert_not_called()
        registry.get.side_effect = [IMMUTABLE, TAG]
        with self.assertRaises(build.BuildArtifactError):
            build.build_artifact(COMMIT, CONFIG, run=self.runner(revision="c" * 40), registry=registry)

    def test_changed_immutable_policy_aborts_before_push(self):
        registry, run = Mock(), self.runner()
        registry.get.side_effect = [IMMUTABLE, None, {**IMMUTABLE, "dockerConfig": {}}]
        with self.assertRaises(build.BuildArtifactError):
            build.build_artifact(COMMIT, CONFIG, run=run, registry=registry)
        self.assertFalse(any("push" in call.args[0] for call in run.call_args_list))

    def test_bad_tag_resource_digest_or_missing_postpush_tag_is_rejected(self):
        for tag in [{**TAG, "name": TAG["name"] + "wrong"},
                    {**TAG, "version": TAG["version"].replace("/backend/", "/other/")},
                    {**TAG, "version": PACKAGE + "/versions/latest"}]:
            with self.subTest(tag=tag), self.assertRaises(build.BuildArtifactError):
                registry = Mock()
                registry.get.side_effect = [IMMUTABLE, tag]
                build.build_artifact(COMMIT, CONFIG, run=self.runner(), registry=registry)
        registry = Mock()
        registry.get.side_effect = [IMMUTABLE, None, IMMUTABLE, None]
        with self.assertRaises(build.BuildArtifactError):
            build.build_artifact(COMMIT, CONFIG, run=self.runner(), registry=registry)

    def test_rest_only_exact_404_is_optional_absence_and_token_stays_in_header(self):
        for status in [200, 301, 401, 403, 404, 429, 500, 503]:
            with self.subTest(status=status), patch.object(build.http.client, "HTTPSConnection") as connection:
                response = connection.return_value.getresponse.return_value
                response.status = status
                response.read.return_value = json.dumps(TAG).encode()
                registry = build.ArtifactRegistry("test-credential")
                if status in (200, 404):
                    self.assertEqual(registry.get(TAG["name"], missing_ok=True), TAG if status == 200 else None)
                else:
                    with self.assertRaises(build.BuildArtifactError):
                        registry.get(TAG["name"], missing_ok=True)
                connection.assert_called_once_with("artifactregistry.googleapis.com", timeout=30)
                request = connection.return_value.request.call_args
                self.assertEqual(request.args, ("GET", "/v1/" + TAG["name"]))
                self.assertEqual(request.kwargs["headers"]["Authorization"], "Bearer test-credential")
                connection.return_value.close.assert_called_once()
        with patch.object(build.http.client, "HTTPSConnection") as connection:
            connection.return_value.getresponse.return_value.status = 404
            with self.assertRaises(build.BuildArtifactError):
                build.ArtifactRegistry("test-credential").get(REPOSITORY)

    def test_output_file_contains_only_verified_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "github-output"
            output.write_text("previous=value\n")
            with patch.object(build, "build_artifact", return_value=IMAGE), \
                    patch.object(build.sys, "argv", ["build-artifact.py", "--commit", COMMIT, "--github-output", str(output)]), \
                    patch("builtins.print") as printed:
                self.assertEqual(build.main(), 0)
            self.assertEqual(output.read_text(), "previous=value\nref=" + IMAGE + "\n")
            printed.assert_not_called()


if __name__ == "__main__":
    unittest.main()
