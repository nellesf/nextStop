"""Exercise orchestration with fake gcloud; no cloud, token or Docker access."""
import contextlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import deploy

REGISTRY = "europe-west3-docker.pkg.dev/nextstop-tech-testing/nextstop/backend"
IMAGE = REGISTRY + "@sha256:" + "a" * 64
TOKEN = "synthetic-private-registry-token"


class OrchestrationTests(unittest.TestCase):
    def invoke(self, environment="production", fail=None, skip_public=False, image=IMAGE,
               runner=None, errors=None):
        events = []

        def fake_command(arguments, *, phase, input_text=None):
            self.assertIsInstance(phase, deploy.DeploymentPhase)
            events.append((arguments, input_text))
            if runner is not None:
                return runner(arguments, phase=phase, input_text=input_text)
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
            except deploy.ReleaseError as error:
                failed = True
                if errors is not None:
                    errors.append(error)
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

    def test_primary_failure_survives_both_cleanup_failures_with_distinct_diagnostics(self):
        real_command = deploy.command
        raised, caught = [], []

        def remembered_command(arguments, **kwargs):
            try:
                return real_command(arguments, **kwargs)
            except deploy.ReleaseError as error:
                raised.append(error)
                raise

        diagnostic = io.StringIO()
        denied = SimpleNamespace(returncode=1, stdout=TOKEN,
                                 stderr="ERROR: (gcloud.compute.scp) PERMISSION_DENIED: " + TOKEN)
        with patch.object(deploy.subprocess, "run", return_value=denied), contextlib.redirect_stderr(diagnostic):
            events, failed = self.invoke(runner=remembered_command, errors=caught)
        self.assertTrue(failed)
        self.assertIs(caught[0], raised[0])
        self.assertEqual(len(events), 3)
        rows = [json.loads(line) for line in diagnostic.getvalue().splitlines()]
        self.assertEqual([row["phase"] for row in rows], ["archive_upload", "cleanup_registry", "cleanup_uploads"])
        self.assertTrue(all(row["exitCode"] == 1 for row in rows))
        self.assertNotIn(TOKEN, diagnostic.getvalue())
        self.assertFalse(any("bash" in call for call, _ in self.remote(events)))

    def test_cleanup_only_failure_is_reported_and_other_cleanup_still_runs(self):
        real_command = deploy.command
        caught = []

        def process(arguments, **kwargs):
            cleanup = any("sudo rm -rf" in value for value in arguments)
            stdout = TOKEN + "\n" if arguments[:3] == ["gcloud", "auth", "print-access-token"] else ""
            return SimpleNamespace(returncode=1 if cleanup else 0, stdout=stdout, stderr=TOKEN)

        diagnostic = io.StringIO()
        with patch.object(deploy.subprocess, "run", side_effect=process), contextlib.redirect_stderr(diagnostic):
            events, failed = self.invoke(runner=real_command, errors=caught)
        self.assertTrue(failed)
        self.assertEqual(len(caught), 1)
        self.assertEqual(json.loads(diagnostic.getvalue())["phase"], "cleanup_registry")
        self.assertTrue(any(call[:3] == ["rm", "-f", "--"] for call, _ in self.remote(events)))


class CommandDiagnosticsTests(unittest.TestCase):
    def failure(self, stderr, *, stdout=TOKEN, code=1):
        diagnostic, standard = io.StringIO(), io.StringIO()
        result = SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)
        with patch.object(deploy.subprocess, "run", return_value=result), \
                contextlib.redirect_stderr(diagnostic), contextlib.redirect_stdout(standard):
            with self.assertRaises(deploy.ReleaseError):
                deploy.command(["gcloud", TOKEN], phase=deploy.DeploymentPhase.ARCHIVE_UPLOAD, input_text=TOKEN)
        self.assertEqual(standard.getvalue(), "")
        self.assertNotIn(TOKEN, diagnostic.getvalue())
        return json.loads(diagnostic.getvalue()), diagnostic.getvalue()

    def test_cli_error_emits_only_allowlisted_fields_not_secrets_or_resource_names(self):
        stderr = ("ERROR: (gcloud.compute.scp) PERMISSION_DENIED: private-account@example.invalid\n"
                  " - Required 'compute.instances.get' permission for 'private-project/private-vm'\n"
                  "postgresql://private-user:private-password@private-host/database\n"
                  "-----BEGIN PRIVATE KEY-----\n" + TOKEN)
        row, output = self.failure(stderr, code=255)
        self.assertEqual(row, {"event": "deployment_command_failed", "phase": "archive_upload",
                              "kind": "exit", "exitCode": 255, "errorCodes": ["PERMISSION_DENIED"],
                              "permissions": ["compute.instances.get"], "cliCategory": None})
        for forbidden in ["private-account", "private-project", "private-vm", "postgresql", "private-password", "PRIVATE KEY"]:
            self.assertNotIn(forbidden, output)

    def test_structured_and_yaml_error_fields_are_filtered(self):
        structured = {"error": {"status": "PERMISSION_DENIED", "message": TOKEN, "details": [
            {"reason": "IAM_PERMISSION_DENIED", "metadata": {
                "permission": "iam.serviceAccounts.getAccessToken", "principal": TOKEN}},
            {"reason": TOKEN, "metadata": {"permission": "unknown.secret.permission"}},
        ]}}
        row, output = self.failure(json.dumps(structured))
        self.assertEqual(row["errorCodes"], ["IAM_PERMISSION_DENIED", "PERMISSION_DENIED"])
        self.assertEqual(row["permissions"], ["iam.serviceAccounts.getAccessToken"])
        self.assertNotIn("unknown.secret.permission", output)
        yaml = "reason: ACCESS_TOKEN_SCOPE_INSUFFICIENT\nmetadata:\n  permission: iap.tunnelInstances.accessViaIAP\n  resource: " + TOKEN
        row, _ = self.failure(yaml)
        self.assertEqual(row["errorCodes"], ["ACCESS_TOKEN_SCOPE_INSUFFICIENT"])
        self.assertEqual(row["permissions"], ["iap.tunnelInstances.accessViaIAP"])

    def test_known_words_in_prose_and_invalid_field_types_are_not_diagnostics(self):
        for stderr in [
            "An example mentions PERMISSION_DENIED and compute.instances.get. " + TOKEN,
            "Prefix You do not currently have an active account selected. " + TOKEN,
            json.dumps({"error": {"status": [TOKEN], "details": [
                {"reason": {"private": TOKEN}, "metadata": {"permission": [TOKEN]}}]}}),
            json.dumps({"error": {"status": {"private": TOKEN}}}),
            '{"error":' + '[' * 1200 + '"' + TOKEN + '"' + ']' * 1200 + '}',
        ]:
            with self.subTest(stderr_kind="unrecognized"):
                row, _ = self.failure(stderr)
                self.assertEqual(row["errorCodes"], [])
                self.assertEqual(row["permissions"], [])
                self.assertIsNone(row["cliCategory"])

    def test_exact_no_active_account_error_has_fixed_category(self):
        row, output = self.failure("ERROR: (gcloud.compute.scp) You do not currently have an active account selected.\n"
                                   "Please run a command with " + TOKEN)
        self.assertEqual(row["cliCategory"], "no_active_account")
        self.assertNotIn("Please run", output)

    def test_timeouts_and_os_errors_never_serialize_exception_or_partial_output(self):
        for error, kind in [
            (subprocess.TimeoutExpired([TOKEN], 1800, output=TOKEN, stderr=TOKEN), "timeout"),
            (OSError(TOKEN), "unavailable"),
        ]:
            with self.subTest(kind=kind):
                diagnostic = io.StringIO()
                with patch.object(deploy.subprocess, "run", side_effect=error), contextlib.redirect_stderr(diagnostic):
                    with self.assertRaises(deploy.ReleaseError) as caught:
                        deploy.command([TOKEN], phase=deploy.DeploymentPhase.REGISTRY_LOGIN, input_text=TOKEN)
                row = json.loads(diagnostic.getvalue())
                self.assertEqual(row["kind"], kind)
                self.assertIsNone(row["exitCode"])
                self.assertNotIn(TOKEN, diagnostic.getvalue() + str(caught.exception))

    def test_successful_token_stays_in_memory_and_stdin_without_diagnostic(self):
        diagnostic, standard = io.StringIO(), io.StringIO()
        with patch.object(deploy.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=TOKEN, stderr=TOKEN)) as run, \
                contextlib.redirect_stderr(diagnostic), contextlib.redirect_stdout(standard):
            returned = deploy.command(["gcloud", "auth", "print-access-token"], phase=deploy.DeploymentPhase.REGISTRY_TOKEN)
            deploy.command(["gcloud", "compute", "ssh"], phase=deploy.DeploymentPhase.REGISTRY_LOGIN, input_text=returned)
        self.assertEqual(returned, TOKEN)
        self.assertEqual(run.call_args.kwargs["input"], TOKEN)
        self.assertNotIn(TOKEN, repr(run.call_args.args))
        self.assertEqual(diagnostic.getvalue() + standard.getvalue(), "")

    def test_arbitrary_phase_is_rejected_before_running_or_logging(self):
        diagnostic = io.StringIO()
        with patch.object(deploy.subprocess, "run") as run, contextlib.redirect_stderr(diagnostic):
            with self.assertRaises(deploy.ReleaseError):
                deploy.command(["gcloud"], phase=TOKEN)
        run.assert_not_called()
        self.assertEqual(diagnostic.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
