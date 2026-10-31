"""Exercise fail-closed promotion and exact-database backup verification."""
import importlib.util
import contextlib
import hashlib
import io
import json
import re
import shlex
import subprocess
import sys
from types import SimpleNamespace
import unittest
from pathlib import Path
from unittest.mock import patch

from common import configuration, validate_image


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


backup = module("backup", "backup.py")
promotion = module("promotion", "verify-promotion.py")
record = module("record", "record-deployment.py")
CONFIG = configuration("production")
IMAGE = CONFIG["registry"] + "@sha256:" + "a" * 64
COMMIT = "b" * 40


class ReleaseControlTests(unittest.TestCase):
    def setUp(self):
        client = {"image": "europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/postgres-client@sha256:" + "1" * 64,
                  "configDigest": "sha256:" + "2" * 64, "sourceCommit": "3" * 40,
                  "version": "17.11", "platform": "linux/amd64"}
        mocked_client = patch.object(backup, "client_configuration", return_value=client)
        mocked_client.start()
        self.addCleanup(mocked_client.stop)

    def test_mutable_or_cross_repository_image_rejected(self):
        for image in [CONFIG["registry"] + ":latest", IMAGE.replace("/nextstop/", "/other/")]:
            with self.assertRaises(ValueError):
                validate_image(image, CONFIG)

    def backup_runner(self, changes=None, failure=None, corrupt_download=False, private_bucket=True):
        payload = b"PGDMP synthetic fixture with no production content"
        events, local_paths = [], []
        destination = None

        def run(arguments, **kwargs):
            self.assertIn("--project=nextstop-tech-staging", arguments)
            if arguments[1:4] == ["storage", "buckets", "describe"]:
                events.append("bucket")
                return {"name": CONFIG["backupBucket"], "iamConfiguration": {
                    "publicAccessPrevention": "enforced" if private_bucket else "inherited",
                    "uniformBucketLevelAccess": {"enabled": True}}}
            if arguments[1:3] == ["compute", "ssh"]:
                events.append("dump")
                self.assertEqual(arguments[3], "nextstop-backend")
                self.assertIn("--tunnel-through-iap", arguments)
                script = arguments[-1]
                self.assertIn("client_run", script)
                self.assertNotIn("docker exec", script)
                self.assertIn("--exclude-table-data=nextstop.user_error_reports", script)
                self.assertIn("pg_restore", script)
                self.assertIn("--list", script)
                self.assertIn("1800s", script)
                self.assertIn("2>/dev/null", script)
                if failure == "dump":
                    raise RuntimeError("remote dump rejected")
                return {"size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
            self.assertEqual(arguments[1:4], ["storage", "objects", "describe"])
            events.append("describe")
            self.assertEqual(arguments[4], destination)
            bucket, name = destination.removeprefix("gs://").split("/", 1)
            return {"bucket": bucket, "name": name, "size": str(len(payload)),
                    "crc32c": "AAAAAA==", "generation": "42", "timeCreated": "2026-10-01T00:00:00Z",
                    **(changes or {})}

        def command(arguments, **kwargs):
            nonlocal destination
            if arguments[1:3] == ["compute", "ssh"] and arguments[-1] == "--command=true":
                events.append("prepare")
                self.assertEqual(arguments[3], "nextstop-backend")
                self.assertIn("--project=nextstop-tech-staging", arguments)
                self.assertIn("--tunnel-through-iap", arguments)
                self.assertEqual(kwargs["timeout"], 90)
                if failure == "prepare":
                    raise RuntimeError("SSH preparation failed")
            elif arguments[1:3] == ["compute", "scp"]:
                events.append("download")
                self.assertTrue(arguments[3].startswith("nextstop-backend:/srv/nextstop/.release-backup-"))
                local = Path(arguments[4])
                local_paths.append(local)
                self.assertEqual(local.stat().st_mode & 0o777, 0o600)
                self.assertEqual(local.parent.stat().st_mode & 0o777, 0o700)
                self.assertFalse(local.resolve().is_relative_to(backup.ROOT))
                local.write_bytes(payload if not corrupt_download else b"PGDMP damaged")
                if failure == "download":
                    raise RuntimeError("download failed")
            elif arguments[1:3] == ["storage", "cp"]:
                events.append("upload")
                self.assertIn("--if-generation-match=0", arguments)
                destination = arguments[4]
                self.assertTrue(destination.startswith("gs://nextstop-tech-staging-release-backups/production/nextstop-backend/"))
                if failure == "upload":
                    raise RuntimeError("upload checksum failed")
            else:
                events.append("cleanup")
                self.assertEqual(arguments[1:3], ["compute", "ssh"])
                self.assertIn("sudo rm -f -- /srv/nextstop/.release-backup-", arguments[-1])
                if failure == "cleanup":
                    raise RuntimeError("cleanup failed")
        return run, command, events, local_paths

    def test_successful_backup_is_bound_to_database_image_generation_and_attempt(self):
        run, command, events, paths = self.backup_runner()
        receipt = backup.create_backup(CONFIG, IMAGE, run=run, command=command, now=lambda: 1790812800)
        self.assertEqual({key: receipt[key] for key in receipt if key != "backupId"}, {
            "environment": "production", "image": IMAGE, "project": "nextstop-tech-staging",
            "instance": "nextstop-backend", "status": "SUCCESSFUL", "completedAt": 1790812800})
        self.assertRegex(receipt["backupId"], r"^gs://nextstop-tech-staging-release-backups/production/nextstop-backend/1790812800-[0-9a-f]{32}\.dump#42$")
        self.assertEqual(events, ["bucket", "prepare", "dump", "download", "upload", "describe", "cleanup"])
        self.assertTrue(all(not path.parent.exists() for path in paths))

    def test_ssh_preparation_failure_prevents_dump_and_temporary_state(self):
        run, command, events, paths = self.backup_runner(failure="prepare")
        with patch.object(backup.uuid, "uuid4") as operation, \
             patch.object(backup.tempfile, "TemporaryDirectory") as temporary:
            with self.assertRaisesRegex(RuntimeError, "SSH preparation failed"):
                backup.create_backup(CONFIG, IMAGE, run=run, command=command)
        self.assertEqual(events, ["bucket", "prepare"])
        self.assertEqual(paths, [])
        operation.assert_not_called()
        temporary.assert_not_called()

    def test_first_ssh_banner_is_suppressed_before_strict_dump_metadata_parsing(self):
        run, command, events, _ = self.backup_runner()
        real_subprocess = subprocess.run
        banner = "Generating public/private rsa key pair.\nSynthetic private setup output\n+--[RSA 3072]--+\n|   .o+       |\n+----[SHA256]--+"
        payload = b"PGDMP synthetic fixture with no production content"
        metadata = {"size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
        calls = []

        def local_cli(arguments, **kwargs):
            self.assertEqual(arguments[1:3], ["compute", "ssh"])
            preparing = arguments[-1] == "--command=true"
            calls.append("prepare" if preparing else "dump")
            if preparing:
                self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
                self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
                program = "import sys; print(" + repr(banner) + "); print('synthetic setup stderr', file=sys.stderr)"
            else:
                self.assertEqual(calls, ["prepare", "dump"])
                self.assertTrue(kwargs["capture_output"])
                program = "print(" + repr(json.dumps(metadata)) + ")"
            return real_subprocess([sys.executable, "-c", program], **kwargs)

        def prepared_command(arguments, **kwargs):
            command(arguments, **kwargs)
            if arguments[-1] == "--command=true":
                backup.run_command(arguments, **kwargs)

        def strict_run(arguments, **kwargs):
            expected = run(arguments, **kwargs)
            if arguments[1:3] == ["compute", "ssh"]:
                return backup.run_json(arguments, **kwargs)
            return expected

        with patch.object(backup.subprocess, "run", side_effect=local_cli):
            receipt = backup.create_backup(CONFIG, IMAGE, run=strict_run, command=prepared_command,
                                           now=lambda: 1790812800)
        self.assertEqual(receipt["status"], "SUCCESSFUL")
        self.assertEqual(calls, ["prepare", "dump"])
        self.assertEqual(events[:3], ["bucket", "prepare", "dump"])

    def test_json_metadata_remains_strict_if_unexpected_output_follows_preparation(self):
        with patch.object(backup.subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout='unexpected banner\n{"size": 5, "sha256": "synthetic"}')):
            with self.assertRaises(json.JSONDecodeError):
                backup.run_json(["gcloud", "compute", "ssh"])

    def test_wrong_object_incomplete_checksum_stale_and_future_backups_rejected(self):
        for changes in [{"bucket": "staging"}, {"name": "wrong.dump"}, {"size": "1"},
                        {"generation": ""}, {"crc32c": ""}, {"crc32c": "not_base64"},
                        {"timeCreated": "2026-09-30T00:00:00Z"}, {"timeCreated": "2026-10-02T00:00:00Z"}]:
            with self.subTest(changes=changes):
                run, command, events, paths = self.backup_runner(changes)
                with self.assertRaises(RuntimeError):
                    backup.create_backup(CONFIG, IMAGE, run=run, command=command, now=lambda: 1790812800)
                self.assertEqual(events[-1], "cleanup")
                self.assertTrue(all(not path.parent.exists() for path in paths))

    def test_dump_download_upload_and_cleanup_failures_cannot_issue_receipt(self):
        for failure in ["dump", "download", "upload", "cleanup"]:
            with self.subTest(failure=failure):
                run, command, events, paths = self.backup_runner(failure=failure)
                with self.assertRaises(RuntimeError):
                    backup.create_backup(CONFIG, IMAGE, run=run, command=command, now=lambda: 1790812800)
                self.assertEqual(events[-1], "cleanup")
                self.assertTrue(all(not path.parent.exists() for path in paths))
                if failure in {"dump", "download", "upload"}:
                    self.assertNotIn("describe", events)

    def test_download_corruption_is_rejected_before_upload(self):
        run, command, events, paths = self.backup_runner(corrupt_download=True)
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            backup.create_backup(CONFIG, IMAGE, run=run, command=command, now=lambda: 1790812800)
        self.assertNotIn("upload", events)
        self.assertEqual(events[-1], "cleanup")
        self.assertTrue(all(not path.parent.exists() for path in paths))

    def test_insufficient_local_space_rejects_before_download(self):
        run, command, events, _ = self.backup_runner()
        with patch.object(backup.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(RuntimeError, "Insufficient"):
                backup.create_backup(CONFIG, IMAGE, run=run, command=command)
        self.assertEqual(events, ["bucket", "prepare", "dump", "cleanup"])

    def test_bucket_privacy_must_be_confirmed_before_creating_dump(self):
        run, command, events, _ = self.backup_runner(private_bucket=False)
        with self.assertRaisesRegex(RuntimeError, "private uniform access"):
            backup.create_backup(CONFIG, IMAGE, run=run, command=command)
        self.assertEqual(events, ["bucket"])

    def test_nonlocal_or_wrong_environment_rejected_before_commands(self):
        for config in [{**CONFIG, "name": "staging"}, {**CONFIG, "database": {"mode": "external"}},
                       {**CONFIG, "database": {"mode": "local", "instance": "other"}}]:
            with self.assertRaises(ValueError):
                backup.create_backup(config, IMAGE, run=lambda *_: self.fail("must not execute"))

    def test_command_errors_and_timeouts_do_not_expose_private_output(self):
        with patch.object(backup.subprocess, "run") as command:
            command.return_value = SimpleNamespace(returncode=1)
            with self.assertRaisesRegex(RuntimeError, "private command output was suppressed"):
                backup.run_command(["gcloud", "storage", "cp"])
            self.assertEqual(command.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertEqual(command.call_args.kwargs["stderr"], subprocess.DEVNULL)
            command.side_effect = subprocess.TimeoutExpired(["private-value"], 1, output=b"private-content")
            with self.assertRaises(RuntimeError) as error:
                backup.run_command(["gcloud"])
            self.assertNotIn("private", str(error.exception))

    def test_backup_commands_disable_composite_uploads_without_changing_parent_environment(self):
        property_name = "CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED"
        for inherited_value in [None, "true", "false"]:
            with self.subTest(inherited_value=inherited_value):
                inherited = {
                    "PATH": "/synthetic/tools",
                    "CLOUDSDK_CONFIG": "/synthetic/gcloud",
                    "GOOGLE_APPLICATION_CREDENTIALS": "/synthetic/credentials.json",
                }
                if inherited_value is not None:
                    inherited[property_name] = inherited_value
                arguments = ["gcloud", "storage", "cp", "/synthetic/archive.dump", "gs://synthetic/archive.dump"]
                with patch.dict(backup.os.environ, inherited, clear=True), \
                     patch.object(backup.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as command:
                    backup.run_command(arguments, timeout=1800)
                    self.assertEqual(command.call_args.args, (arguments,))
                    self.assertEqual(command.call_args.kwargs["env"], {**inherited, property_name: "false"})
                    self.assertEqual(command.call_args.kwargs["timeout"], 1800)
                    self.assertEqual(dict(backup.os.environ), inherited)

    def test_remote_dump_script_is_valid_bash_without_executing_it(self):
        arguments = shlex.split(backup.dump_script("/srv/nextstop/.release-backup-" + "a" * 32))
        self.assertEqual(arguments[:5], ["timeout", "--kill-after=60s", "1800s", "bash", "-c"])
        result = subprocess.run(["bash", "-n"], input=arguments[5], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_current_production_read_exports_only_validated_release_identity(self):
        state = {"environment": "production", "image": IMAGE, "workerImage": IMAGE,
                 "api": {"image": IMAGE, "privateExtra": "PRIVATE"}, "privateExtra": "PRIVATE"}
        seen = []
        def run(arguments, **kwargs):
            script = shlex.split(arguments[-1].removeprefix('--command='))
            self.assertEqual(script[:3], ['sudo', '/usr/bin/python3', '-c'])
            source = SimpleNamespace(read_text=lambda: json.dumps(state))
            with patch('pathlib.Path', return_value=source), contextlib.redirect_stdout(io.StringIO()) as output:
                exec(script[3], {})
            seen.append(output.getvalue())
            return json.loads(output.getvalue())
        self.assertEqual(backup.current_production_image(CONFIG, run=run), IMAGE)
        self.assertNotIn('PRIVATE', seen[0])
        self.assertEqual(set(json.loads(seen[0])), {'environment', 'image', 'apiImage', 'workerImage', 'pending'})
        for changes in ({"environment": "staging"}, {"workerImage": IMAGE + "wrong"},
                        {"api": {"image": IMAGE + "wrong"}}, {"pending": {}},
                        {"pendingWorkerChanged": False}, {"pendingCandidateSlot": None},
                        {"image": "PRIVATE"}):
            invalid = {**state, **changes}
            with self.subTest(changes=changes):
                original = state
                state = invalid
                with self.assertRaises(RuntimeError):
                    backup.current_production_image(CONFIG, run=run)
                state = original
        self.assertEqual(len(seen), 1)

    def test_current_production_backup_rechecks_image_and_pending_state(self):
        receipt = {"image": IMAGE, "status": "SUCCESSFUL"}
        for final in (IMAGE, IMAGE[:-1] + 'c', RuntimeError('pending production state')):
            command = unittest.mock.Mock()
            with self.subTest(final=final), patch.object(backup, 'current_production_image', side_effect=[IMAGE, final]) as read, \
                 patch.object(backup, 'create_backup', return_value=receipt) as create:
                if final == IMAGE:
                    self.assertEqual(backup.create_current_backup(CONFIG, command=command), receipt)
                else:
                    with self.assertRaises(RuntimeError):
                        backup.create_current_backup(CONFIG, command=command)
                self.assertEqual(read.call_count, 2)
                self.assertEqual(create.call_args.args, (CONFIG, IMAGE))
                self.assertEqual(command.call_args.args[0][-1], '--command=true')

    def test_backup_cli_requires_exactly_one_image_source(self):
        for targets in ([], ['--image', IMAGE, '--current-production']):
            with self.subTest(targets=targets), patch.object(sys, 'argv', ['backup.py', *targets, '--output', '/tmp/unused.json']), \
                 patch.object(backup, 'create_backup') as create, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    backup.main()
                self.assertEqual(error.exception.code, 2)
                create.assert_not_called()

    def test_backup_only_workflow_never_records_or_promotes_even_with_security_only(self):
        root = Path(__file__).parents[2]
        workflow = (root / '.github/workflows/backend-production.yml').read_text()
        self.assertFalse((root / '.github/workflows/backend-production-backup.yml').exists())
        for guard in ("if: vars.NEXTSTOP_RELEASES_ENABLED == 'true' && github.ref == 'refs/heads/main'",
                      'environment: production', 'group: nextstop-production-release',
                      'cancel-in-progress: false', 'id-token: write',
                      'workload_identity_provider: ${{ vars.NEXTSTOP_WORKLOAD_IDENTITY_PROVIDER }}',
                      'service_account: ${{ vars.NEXTSTOP_DEPLOY_SERVICE_ACCOUNT }}'):
            self.assertIn(guard, workflow)
        self.assertRegex(workflow, r'backup_only:\n\s+description: [^\n]+\n\s+type: boolean\n\s+default: false')
        for required in ('commit', 'image'):
            self.assertRegex(workflow, required + r':\n\s+description: [^\n]+\n\s+type: string\n\s+required: true')
        self.assertNotRegex(workflow, r'(?m)^\s+(schedule|pull_request|push):')
        sections = workflow.split('      - name: ')[1:]
        self.assertEqual(len(sections), 12)
        for backup_only in (False, True):
            for security_only in (False, True):
                selected = []
                for section in sections:
                    name = section.splitlines()[0]
                    match = re.search(r'^        if: (.+)$', section, re.M)
                    condition = match.group(1) if match else 'True'
                    condition = condition.removeprefix('${{').removesuffix('}}').strip()
                    for source, value in (('inputs.backup_only', backup_only), ('inputs.security_only', security_only),
                                          ("vars.NEXTSTOP_PRODUCTION_HOSTING != 'cloud-run'", True),
                                          ("vars.NEXTSTOP_PRODUCTION_HOSTING == 'cloud-run'", False),
                                          ('always()', True), ("steps.deployment.outputs.id != ''", not backup_only)):
                        condition = condition.replace(source, str(value))
                    condition = condition.replace('&&', ' and ').replace('!', 'not ')
                    # Accept only this workflow's boolean grammar; new syntax
                    # must receive an explicit routing-test update.
                    self.assertTrue(set(condition.split()) <= {'True', 'False', 'and', 'not'})
                    if eval(condition, {'__builtins__': {}}, {}):
                        selected.append(name)
                if backup_only:
                    self.assertEqual(selected, ['Select the commissioned production target', 'Prepare the reviewed PostgreSQL backup clients',
                                                'Back up the unchanged current production release'])
                else:
                    self.assertIn('Require successful staging of this exact image', selected)
                    self.assertIn('Record the selected release', selected)
                    self.assertIn('Record outcome', selected)
                    self.assertIn('Back up the exact production database', selected)
                    self.assertNotIn('Back up the unchanged current production release', selected)
                    promotions = [name for name in selected if name.startswith('Promote and verify')]
                    self.assertEqual(promotions, ['Promote and verify the security-only production backport'
                                                  if security_only else 'Promote and verify production'])
                    self.assertEqual('Verify security-only baseline and private candidate evidence' in selected, security_only)
                    self.assertLess(selected.index('Prepare the reviewed PostgreSQL backup clients'),
                                    selected.index('Back up the exact production database'))

    def promotion_runner(self, *, image=IMAGE, state="success", older_success=False, task="nextstop-release"):
        deployment = {"sha": COMMIT, "environment": "staging", "id": 42,
                      "task": task, "payload": {"image": image}}

        def run(arguments, **kwargs):
            if arguments[0] == "gcloud":
                return {"image_summary": {"digest": IMAGE.split("@")[1]}}
            if "/statuses?" in arguments[-1]:
                self.assertIn("/42/", arguments[-1])
                return [{"state": state}]
            return [deployment, {**deployment, "id": 41}] if older_success else [deployment]
        return run

    def test_exact_successful_staged_artifact_can_be_promoted(self):
        self.assertEqual(promotion.verify(COMMIT, IMAGE, run=self.promotion_runner()),
                         {"commit": COMMIT, "image": IMAGE, "stagingDeploymentId": 42})

    def test_cloud_run_requires_exact_full_staging_and_successful_main_test_runs(self):
        runner = self.promotion_runner()
        with self.assertRaises(ValueError):
            promotion.verify(COMMIT, IMAGE, run=runner, require_cloud_run=True)

        def cloud_run(arguments, conclusion="success"):
            if "/actions/workflows/" in arguments[-1]:
                return {"workflow_runs": [{"head_sha": COMMIT, "status": "completed", "conclusion": conclusion}]}
            rows = runner(arguments)
            if isinstance(rows, list) and rows and "payload" in rows[0]:
                rows[0]["payload"]["hosting"] = "cloud-run"
            return rows

        self.assertEqual(promotion.verify(COMMIT, IMAGE, run=cloud_run, require_cloud_run=True)["stagingDeploymentId"], 42)
        with self.assertRaises(ValueError):
            promotion.verify(COMMIT, IMAGE, run=lambda args: cloud_run(args, "failure"), require_cloud_run=True)

    def test_later_failed_staging_attempt_blocks_older_success(self):
        with self.assertRaises(ValueError):
            promotion.verify(COMMIT, IMAGE, run=self.promotion_runner(state="failure", older_success=True))

    def test_unbound_auto_deployment_and_wrong_digest_cannot_authorize_promotion(self):
        for runner in [self.promotion_runner(task="deploy"), self.promotion_runner(image=IMAGE[:-1] + "b")]:
            with self.assertRaises(ValueError):
                promotion.verify(COMMIT, IMAGE, run=runner)

    def test_registry_digest_mismatch_rejected_before_deployment_lookup(self):
        with self.assertRaises(ValueError):
            promotion.verify(COMMIT, IMAGE, run=lambda *_: {"image_summary": {"digest": "sha256:" + "b" * 64}})

    def test_untrusted_commit_rejected_before_any_command(self):
        with self.assertRaises(ValueError):
            promotion.verify("main; touch nope", IMAGE, run=lambda *_: self.fail("must not execute"))

    def test_record_payload_is_passed_as_stdin_not_shell_arguments(self):
        with patch.object(record.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = '{"id":42}'
            self.assertEqual(record.post("repos/nellesf/nextStop/deployments", {"ref": COMMIT}), {"id": 42})
            self.assertNotIn(COMMIT, run.call_args.args[0])
            self.assertIn(COMMIT, run.call_args.kwargs["input"])


if __name__ == "__main__":
    unittest.main()
