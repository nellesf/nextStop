import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
OLD = "registry.example/nextstop@sha256:" + "a" * 64
NEW = "registry.example/nextstop@sha256:" + "b" * 64
LEGACY = "sha256:" + "c" * 64
ROOT = Path(__file__).resolve().parents[2]


class FakeRelease(release.Release):
    def __init__(self, args, fail=None):
        self.events, self.fail = [], fail
        self.failed = False
        super().__init__(args, self.fake_command, lambda delay: self.events.append(("drain", delay)))

    def fake_command(self, command, environment, timeout):
        event = ("command", tuple(command), environment.get("BACKEND_IMAGE"))
        self.events.append(event)
        if self.fail and self.fail(event) and not self.failed:
            self.failed = True
            raise release.ReleaseError("Synthetic command failure.")
        if "simulator-token-mint" in command:
            return json.dumps({"accessToken": "synthetic-token"})
        if "ps" in command:
            return "worker-container\n"
        if "inspect" in command:
            return "true 0\n" if "{{.State.Running}} {{.RestartCount}}" in command else OLD
        return ""

    def request(self, url, body=None, token=None):
        event = ("request", url, body is not None)
        self.events.append(event)
        if self.fail and self.fail(event) and not self.failed:
            self.failed = True
            raise release.ReleaseError("Synthetic gate failure.")
        if url.endswith(("/ready", "/ready/auth")):
            return {"status": "ready", "release": self.environment["RELEASE_IMAGE_DIGEST"]}
        return {"candidates": [{"id": "synthetic"}], "snapshotToken": "synthetic"}

    def ready(self, base, path="/ready"):
        # One attempt for deterministic failure-path tests; the real retry loop
        # gets its own wrong-release regression below.
        result = self.request(base + path)
        if result.get("status") != "ready" or result.get("release") != self.environment["RELEASE_IMAGE_DIGEST"]:
            raise release.ReleaseError("Synthetic readiness rejection.")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.host = self.directory / "release.env"
        self.secrets = self.directory / "backend.env"
        self.host.write_text("NEXTSTOP_ENVIRONMENT=staging\nDATABASE_MODE=local\nCOMPOSE_PROJECT_NAME=gcp-vm\n")
        self.secrets.write_text("\n".join(f"{key}={'s' * 40}" for key in [
            "POSTGRES_PASSWORD", "API_DATABASE_PASSWORD", "AUTH_DATABASE_PASSWORD",
            "SUPPORT_DATABASE_PASSWORD", "WORKER_DATABASE_PASSWORD", "SNAPSHOT_SIGNING_KEY",
            "SEARCH_ACCESS_TOKEN_SIGNING_KEY"]))
        certificate = self.directory / "certificates/api-staging.nextstop.tech/fullchain.pem"
        certificate.parent.mkdir(parents=True)
        certificate.write_text("synthetic certificate")
        self.site = self.directory / "sites-available/nextstop"
        self.site.parent.mkdir()
        self.site.write_text("known-good-old-site\n")
        self.state_directory = self.directory / "state"
        self.state_directory.mkdir()
        self.old = {"environment": "staging", "image": OLD, "api": {"slot": "blue", "image": OLD},
                    "workerImage": OLD, "nginxConfig": self.site.read_text()}
        (self.state_directory / "state.json").write_text(json.dumps(self.old))

    def make(self, extra=(), fail=None):
        args = release.parser().parse_args(["deploy", "--environment", "staging", "--image", NEW,
            "--root", str(ROOT), "--host-config", str(self.host), "--secrets", str(self.secrets),
            "--state-directory", str(self.state_directory), "--nginx-site", str(self.site),
            "--nginx-enabled-site", str(self.directory / "sites-enabled/nextstop"),
            "--certificate-root", str(self.directory / "certificates"), *extra])
        return FakeRelease(args, fail)

    def commands(self, subject):
        return [event for event in subject.events if event[0] == "command"]

    def test_success_gates_before_worker_and_retains_old_api(self):
        subject = self.make()
        subject.deploy()
        commands = self.commands(subject)
        database_start = next(event for event in commands if event[1][-1] == "database")
        self.assertIn("--no-recreate", database_start[1])
        self.assertFalse(any("build" in event[1] or "down" in event[1] for event in commands))
        self.assertFalse(any("stop" in event[1] and any("api-" in arg or "auth-" in arg for arg in event[1]) for event in commands))
        stop = next(index for index, event in enumerate(subject.events) if event[0] == "command" and "stop" in event[1])
        public_search = next(index for index, event in enumerate(subject.events) if event[:2] == ("request", "https://api-staging.nextstop.tech/v1/charging-parks/search"))
        self.assertGreater(stop, public_search)
        self.assertEqual(subject.state["api"]["slot"], "green")
        self.assertEqual(subject.state["previous"], self.old)
        self.assertIn(("drain", 65), subject.events)
        # No subprocess argument contains credentials; only its restricted env does.
        self.assertNotIn("s" * 40, repr(commands))

    def test_migration_failure_leaves_old_services_untouched(self):
        subject = self.make(fail=lambda event: event[0] == "command" and "migrator" in event[1])
        with self.assertRaises(release.ReleaseError):
            subject.deploy()
        self.assertEqual(self.site.read_text(), self.old["nginxConfig"])
        self.assertFalse(any("stop" in event[1] or "api-green" in event[1] for event in self.commands(subject)))

    def test_candidate_and_proxy_failures_restore_old_api_without_stopping_worker(self):
        for url in ["http://127.0.0.1:3200/ready", "http://127.0.0.1:3201/ready",
                    "http://127.0.0.1:3200/v1/charging-parks/search", "https://local-proxy/ready",
                    "https://local-proxy/ready/auth", "https://api-staging.nextstop.tech/ready/auth",
                    "https://api-staging.nextstop.tech/v1/charging-parks/search"]:
            with self.subTest(url=url):
                subject = self.make(["--skip-migrations"], fail=lambda event: event[:2] == ("request", url))
                with self.assertRaises(release.ReleaseError):
                    subject.deploy()
                self.assertEqual(self.site.read_text(), self.old["nginxConfig"])
                self.assertEqual(subject.state, self.old)
                self.assertFalse(any("stop" in event[1] for event in self.commands(subject)))

    def test_nginx_validation_failure_restores_exact_previous_config(self):
        subject = self.make(["--skip-migrations"], fail=lambda event: event[:2] == ("command", ("nginx", "-t")))
        with self.assertRaises(release.ReleaseError):
            subject.deploy()
        self.assertEqual(self.site.read_text(), self.old["nginxConfig"])
        self.assertFalse(any("stop" in event[1] for event in self.commands(subject)))

    def test_worker_failure_restarts_previous_digest_after_restoring_api(self):
        subject = self.make(["--skip-migrations"], fail=lambda event: event[0] == "command" and "up" in event[1] and event[1][-1] == "worker")
        with self.assertRaises(release.ReleaseError):
            subject.deploy()
        self.assertEqual(self.site.read_text(), self.old["nginxConfig"])
        restored = [event for event in self.commands(subject) if "up" in event[1] and event[1][-1] == "worker"]
        self.assertEqual([event[2] for event in restored], [NEW, OLD])
        self.assertEqual(subject.state, self.old)

    def test_failed_second_release_preserves_rollback_and_restores_overwritten_slot(self):
        subject = self.make(["--skip-migrations"])
        subject.deploy()
        previous_success = subject.state
        for fail in [
            lambda event: event[0] == "command" and "simulator-token-mint" in event[1],
            lambda event: event[0] == "command" and "up" in event[1] and "api-blue" in event[1],
            lambda event: event[:2] == ("request", "http://127.0.0.1:3100/ready"),
            lambda event: event[:2] == ("request", "https://local-proxy/ready/auth"),
        ]:
            with self.subTest(fail=fail):
                subject = self.make(["--skip-migrations"], fail)
                with self.assertRaises(release.ReleaseError):
                    subject.deploy()
                self.assertEqual(subject.state, previous_success)
                candidate_starts = [event for event in self.commands(subject) if "up" in event[1] and "api-blue" in event[1]]
                if candidate_starts:
                    self.assertEqual([event[2] for event in candidate_starts], [NEW, OLD])
                self.assertFalse(any("stop" in event[1] for event in self.commands(subject)))
        subject.rollback()
        self.assertEqual(subject.state["api"]["image"], OLD)

    def test_interrupted_candidate_restores_retained_slot_before_next_release(self):
        subject = self.make(["--skip-migrations"])
        subject.deploy()
        success = subject.state
        subject.save({**success, "pending": success, "pendingCandidateSlot": "blue"})
        subject.events.clear()
        subject.recover_pending()
        self.assertEqual(subject.state, success)
        restored = [event for event in self.commands(subject) if "up" in event[1] and "api-blue" in event[1]]
        self.assertEqual([event[2] for event in restored], [OLD])

    def test_failed_rollback_recovers_current_api_worker_and_rollback_metadata(self):
        subject = self.make(["--skip-migrations"])
        subject.deploy()
        success = subject.state
        subject.fail = lambda event: event[0] == "command" and "up" in event[1] and event[1][-1] == "worker"
        with self.assertRaises(release.ReleaseError):
            subject.rollback()
        self.assertEqual(subject.state, success)
        self.assertEqual(self.site.read_text(), success["nginxConfig"])

    def test_rollback_proxy_failure_does_not_restart_unchanged_worker(self):
        subject = self.make(["--skip-migrations"])
        subject.deploy()
        success = subject.state
        subject.events.clear()
        subject.fail = lambda event: event[:2] == ("command", ("nginx", "-t"))
        with self.assertRaises(release.ReleaseError):
            subject.rollback()
        self.assertEqual(subject.state, success)
        self.assertFalse(any("stop" in event[1] for event in self.commands(subject)))

    def test_rollback_gates_retained_slot_without_migrations(self):
        subject = self.make(["--skip-migrations"])
        subject.deploy()
        subject.events.clear()
        subject.rollback()
        self.assertEqual(subject.state["api"], self.old["api"])
        self.assertEqual(self.site.read_text(), self.old["nginxConfig"])
        self.assertFalse(any("migrator" in event[1] for event in self.commands(subject)))

    def test_mutable_image_rejected_before_any_command(self):
        for image in ["registry.example/nextstop:latest", LEGACY]:
            with self.subTest(image=image):
                subject = self.make(["--image", image])
                with self.assertRaises(release.ReleaseError):
                    subject.deploy()
                self.assertEqual(subject.events, [])

    def test_token_mint_after_first_rollback_uses_adopted_local_image(self):
        (self.state_directory / "state.json").unlink()
        self.site.write_text("proxy_pass http://127.0.0.1:3000;\nproxy_pass http://127.0.0.1:3001;\n")
        subject = self.make(["--skip-migrations"])
        original_runner = subject.runner

        def legacy_runner(command, environment, timeout):
            output = original_runner(command, environment, timeout)
            return LEGACY if "{{.Image}}" in command else output

        subject.runner = legacy_runner
        subject.deploy()
        subject.rollback()
        self.assertEqual(subject.state["api"], {"slot": "legacy", "image": None})
        self.assertEqual(subject.state["workerImage"], LEGACY)
        # A fresh broker invocation reads the persisted rollback state, even if
        # another image argument is present. It only runs the isolated mint tool.
        subject = self.make()
        self.assertEqual(json.loads(subject.mint_active_token()), {"accessToken": "synthetic-token"})
        commands = self.commands(subject)
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][2], LEGACY)
        self.assertEqual(commands[0][1][-5:], ("run", "--rm", "--no-deps", "-T", "simulator-token-mint"))
        self.assertEqual(len(subject.events), 1)

    def test_token_mint_selects_recorded_registry_digest(self):
        subject = self.make()
        subject.mint_active_token()
        self.assertEqual(self.commands(subject)[0][2], OLD)

    def test_token_mint_rejects_local_id_outside_adopted_legacy_and_invalid_refs(self):
        states = [
            {"api": {"slot": "blue", "image": LEGACY}, "workerImage": LEGACY},
            {"api": {"slot": "green", "image": None}, "workerImage": LEGACY},
            {"api": {"slot": "legacy", "image": LEGACY}, "workerImage": LEGACY},
            {"api": {"slot": "legacy", "image": None}, "image": LEGACY, "workerImage": LEGACY},
            {"workerImage": LEGACY},
        ]
        states.extend({"api": {"slot": "legacy", "image": None}, "workerImage": image}
                      for image in ["registry.example/nextstop:latest", "sha256:" + "c" * 63,
                                    "sha256:" + "G" * 64, LEGACY + "\n", "", None])
        for state in states:
            with self.subTest(state=state):
                subject = self.make()
                subject.save(state)
                with self.assertRaises(release.ReleaseError):
                    subject.mint_active_token()
                self.assertEqual(subject.events, [])

    def test_retained_image_override_sets_matching_readiness_identity(self):
        subject = self.make()
        seen = []
        subject.runner = lambda command, environment, timeout: seen.append(environment) or ""
        subject.compose("up", "-d", "api-blue", image=OLD)
        self.assertEqual(seen[0]["RELEASE_IMAGE_DIGEST"], OLD.partition("@")[2])

    def test_production_backup_must_match_database_and_image(self):
        self.host.write_text("NEXTSTOP_ENVIRONMENT=production\nDATABASE_MODE=local\nDATABASE_HOST=database\nPROJECT_ID=production-project\nDATABASE_INSTANCE=nextstop-backend\n")
        receipt = self.directory / "backup.json"
        receipt.write_text(json.dumps({"environment": "production", "image": NEW, "project": "other-project",
            "instance": "nextstop-backend", "status": "SUCCESSFUL", "completedAt": time.time(), "backupId": "gs://nextstop-backups/production/test.dump#123"}))
        subject = self.make(["--environment", "production", "--backup-receipt", str(receipt)])
        with self.assertRaises(release.ReleaseError):
            subject.migrate()
        self.assertEqual(subject.events, [])
        data = json.loads(receipt.read_text())
        data["project"] = "production-project"
        receipt.write_text(json.dumps(data))
        subject.migrate()
        self.assertTrue(any("migrator" in event[1] for event in self.commands(subject)))

    def test_wrong_release_readiness_never_passes(self):
        subject = self.make()
        subject.request = lambda url: {"status": "ready", "release": "sha256:" + "c" * 64}
        with self.assertRaises(release.ReleaseError):
            release.Release.ready(subject, "https://api-staging.nextstop.tech")

    def test_production_preserves_explicit_legacy_bearer_but_rejects_development_attest(self):
        self.host.write_text("NEXTSTOP_ENVIRONMENT=production\nDATABASE_MODE=local\n")
        certificate = self.directory / "certificates/api.nextstop.tech/fullchain.pem"
        certificate.parent.mkdir(parents=True)
        certificate.write_text("synthetic certificate")
        subject = self.make(["--environment", "production", "--skip-migrations"])
        subject.environment.update(ALLOW_LEGACY_STAGING_BEARER="true", APP_ATTEST_ALLOW_DEVELOPMENT="false")
        subject.deploy()
        self.assertEqual(subject.environment["ALLOW_LEGACY_STAGING_BEARER"], "true")
        subject = self.make(["--environment", "production", "--skip-migrations"])
        subject.environment.update(ALLOW_LEGACY_STAGING_BEARER="true", APP_ATTEST_ALLOW_DEVELOPMENT="true")
        with self.assertRaises(release.ReleaseError):
            subject.deploy()
        self.assertFalse(any("up" in event[1] for event in self.commands(subject)))
        subject.environment["APP_ATTEST_ALLOW_DEVELOPMENT"] = "false"
        subject.environment["ALLOW_LEGACY_STAGING_BEARER"] = "yes"
        with self.assertRaises(release.ReleaseError):
            subject.deploy()

    def test_release_compose_has_transactional_roles_and_no_build(self):
        compose = (ROOT / "deploy/gcp-vm/compose.release.yaml").read_text()
        self.assertNotIn("build:", compose)
        self.assertIn("--single-transaction", compose)
        self.assertIn("lock_timeout=500ms", compose)
        self.assertIn("stop_grace_period: 45s", compose)
        mint = compose.split("  simulator-token-mint:")[1].split("volumes:")[0]
        self.assertIn("network_mode: none", mint)
        self.assertIn("read_only: true", mint)
        self.assertNotIn("DATABASE_URL", mint)


if __name__ == "__main__":
    unittest.main()
