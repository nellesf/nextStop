"""Exercise orchestration with fake gcloud; no cloud, token or Docker access."""
import contextlib
import io
import json
from pathlib import Path
import shlex
import sys
import unittest
from unittest.mock import patch

import deploy

REGISTRY = "europe-west3-docker.pkg.dev/nextstop-tech-testing/nextstop/backend"
IMAGE = REGISTRY + "@sha256:" + "a" * 64
TOKEN = "synthetic-private-registry-token"


class OrchestrationTests(unittest.TestCase):
    def invoke(self, environment="production", fail=None, skip_public=False, image=IMAGE):
        events = []

        def fake_command(arguments, *, input_text=None):
            events.append((arguments, input_text))
            if fail and fail(arguments):
                raise deploy.ReleaseError("Synthetic remote failure.")
            return TOKEN + "\n" if arguments[:3] == ["gcloud", "auth", "print-access-token"] else ""

        config = {"name": environment, "domain": deploy.DOMAINS[environment],
                  "project": "nextstop-tech-staging" if environment == "production" else "nextstop-tech-testing",
                  "registry": REGISTRY, "database": {"mode": "local"},
                  "target": {"instance": "nextstop-backend", "zone": "europe-west3-a"}}
        original_read = Path.read_text

        def fake_read(path, *args, **kwargs):
            if path.name == environment + ".json" and path.parent.name == "environments":
                return json.dumps(config)
            return original_read(path, *args, **kwargs)

        arguments = ["deploy.py", "--environment", environment, "--image", image]
        if environment == "production":
            arguments += ["--backup-receipt", "/synthetic/receipt.json"]
        if skip_public:
            arguments += ["--skip-public-probe"]
        failed = False
        with patch.object(sys, "argv", arguments), patch.object(deploy, "command", fake_command), \
                patch.object(Path, "read_text", fake_read), contextlib.redirect_stdout(io.StringIO()):
            try:
                deploy.main()
            except deploy.ReleaseError:
                failed = True
        return events, failed

    def remote(self, events):
        return [(shlex.split(next(value.removeprefix("--command=") for value in arguments if value.startswith("--command="))), text)
                for arguments, text in events if arguments[:3] == ["gcloud", "compute", "ssh"]]

    def test_one_host_deploy_performs_the_locked_migration_and_gates_with_backup(self):
        events, failed = self.invoke()
        self.assertFalse(failed)
        calls = [call for call, _ in self.remote(events) if "bash" in call]
        self.assertEqual(len(calls), 1)
        self.assertIn("deploy", calls[0])
        self.assertIn("--backup-receipt", calls[0])
        self.assertNotIn("--skip-migrations", calls[0])
        self.assertNotIn("--component", calls[0])
        for arguments, _ in events:
            if arguments[:2] == ["gcloud", "compute"]:
                self.assertIn("--project=nextstop-tech-staging", arguments)

    def test_registry_token_only_on_stdin_and_temporary_root_config_is_removed(self):
        events, failed = self.invoke()
        self.assertFalse(failed)
        self.assertNotIn(TOKEN, repr([arguments for arguments, _ in events]))
        token_calls = [(call, text) for call, text in self.remote(events) if text is not None]
        self.assertEqual(len(token_calls), 1)
        login, text = token_calls[0]
        self.assertIn("--password-stdin", login)
        self.assertEqual(text, TOKEN + "\n")
        docker_config = next(value.partition("=")[2] for value in login if value.startswith("DOCKER_CONFIG="))
        self.assertRegex(docker_config, r"^/run/nextstop-registry-[a-f0-9]{32}$")
        remote = [call for call, _ in self.remote(events)]
        self.assertIn(["sudo", "install", "-d", "-m", "700", docker_config], remote)
        self.assertIn(["sudo", "rm", "-rf", "--", docker_config], remote)

    def test_login_failure_never_deploys_and_still_cleans_temporary_credentials(self):
        events, failed = self.invoke(fail=lambda arguments: any("--password-stdin" in value for value in arguments))
        self.assertTrue(failed)
        remote = [call for call, _ in self.remote(events)]
        self.assertFalse(any("bash" in call for call in remote))
        self.assertTrue(any(call[:4] == ["sudo", "rm", "-rf", "--"] for call in remote))

    def test_failed_host_release_keeps_recovery_on_host_and_cleans_authentication(self):
        events, failed = self.invoke(fail=lambda arguments: any(" bash " in value for value in arguments))
        self.assertTrue(failed)
        remote = [call for call, _ in self.remote(events)]
        self.assertEqual(sum("bash" in call for call in remote), 1)
        self.assertTrue(any(call[:4] == ["sudo", "rm", "-rf", "--"] for call in remote))
        self.assertTrue(any(call[:3] == ["rm", "-f", "--"] for call in remote))

    def test_staging_uses_testing_project_and_no_production_backup_receipt(self):
        events, failed = self.invoke(environment="staging")
        self.assertFalse(failed)
        for arguments, _ in events:
            if arguments[:2] == ["gcloud", "compute"]:
                self.assertIn("--project=nextstop-tech-testing", arguments)
        remote = [call for call, _ in self.remote(events) if "bash" in call][0]
        self.assertNotIn("--backup-receipt", remote)

    def test_bootstrap_skip_is_forwarded_without_skipping_migrations(self):
        events, failed = self.invoke(skip_public=True)
        self.assertFalse(failed)
        remote = [call for call, _ in self.remote(events) if "bash" in call][0]
        self.assertIn("--skip-public-probe", remote)
        self.assertNotIn("--skip-migrations", remote)

    def test_unapproved_repository_rejected_before_any_remote_work(self):
        events, failed = self.invoke(image="other.example/backend@sha256:" + "a" * 64)
        self.assertTrue(failed)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
