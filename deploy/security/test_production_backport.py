import contextlib
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("backport", Path(__file__).with_name("production-backport.py"))
backport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backport)


def backup(now=None):
    return {"environment": "production", "project": backport.PROJECT, "instance": backport.INSTANCE,
            "image": backport.TARGET_IMAGE, "status": "SUCCESSFUL", "completedAt": time.time() if now is None else now,
            "backupId": "gs://nextstop-tech-staging-release-backups/production/nextstop-backend/test.dump#123"}


def staging(now=None):
    now = datetime.now(timezone.utc) if now is None else now
    tag = "sec-" + backport.TARGET_COMMIT[:12] + "-" + backport.TARGET_IMAGE.rsplit(":", 1)[1][:12]
    return [{"id": 123, "sha": backport.TARGET_COMMIT, "environment": "staging", "task": "nextstop-release",
             "payload": {"image": backport.TARGET_IMAGE, "validation": {
                 "mode": "private-candidate-validation", "phase": "private-candidates-verified", "passed": True,
                 "image": backport.TARGET_IMAGE, "commit": backport.TARGET_COMMIT, "verifiedAt": now.isoformat(),
                 "checks": {name: True for name in backport.STAGING_CHECKS},
                 "candidateRevisions": {name: f"nextstop-{name}-{tag}" for name in ("api", "auth")},
             }}}]


def remote_fixture():
    scope = {}
    exec(compile(backport.REMOTE, "<protected-host-control>", "exec"), scope)
    state = {"environment": "production", "image": backport.BASELINE_IMAGE, "workerImage": backport.BASELINE_IMAGE,
             "api": {"slot": "blue", "image": backport.BASELINE_IMAGE}}
    records = []
    data = backport.payload(False, "/tmp/test-receipt.json", "/run/test-registry")
    context = {"state": state, "receipt": backup(), "labels": backport.BASELINE_COMMIT,
               "migrations": list(backport.MIGRATIONS), "database": ["db-id", "db-image", "postgis/postgis:17-3.5", "start", True],
               "hashes": dict(backport.CONTROLLER_HASHES), "imageId": backport.TARGET_CONFIG_DIGEST,
               "protectedHash": "unchanged", "appImage": backport.BASELINE_IMAGE, "descriptor": None}

    class FakePath:
        def __init__(self, value): self.value = str(value)
        def __str__(self): return self.value
        def __truediv__(self, other): return FakePath(self.value + "/" + other)
        def resolve(self): return FakePath(backport.INSTALLED_ROOT)
        def read_text(self):
            if self.value.endswith("state.json"): return json.dumps(context["state"])
            if self.value.endswith("test-receipt.json"): return json.dumps(context["receipt"])
            raise OSError("unexpected path")

    def sha(path):
        value = str(path)
        if value.startswith(backport.INSTALLED_ROOT + "/"):
            return context["hashes"][value.removeprefix(backport.INSTALLED_ROOT + "/")]
        return context["protectedHash"]

    def execute(args, env=None, timeout=90):
        records.append((args, env))
        if args[:3] == ["docker", "image", "inspect"]:
            if "--format" in args: return context["labels"]
            return json.dumps([{"Id": context["imageId"], "RepoDigests": [backport.TARGET_IMAGE],
                                "Os": "linux", "Architecture": "amd64", "Descriptor": context["descriptor"],
                                "Config": {"Labels": {"org.opencontainers.image.revision": backport.TARGET_COMMIT}}}])
        if args[:2] == ["docker", "pull"]: return ""
        if args[0] == "/usr/bin/python3":
            context["state"] = {"environment": "production", "image": backport.TARGET_IMAGE,
                                "workerImage": backport.TARGET_IMAGE, "api": {"slot": "green", "image": backport.TARGET_IMAGE},
                                "previous": {"image": backport.BASELINE_IMAGE}}
            return ""
        raise AssertionError("Unexpected remote command")

    def inspect(name):
        if name == "gcp-vm-database-1": return list(context["database"])
        return [name, "app-config", context["appImage"], "start", True]

    scope.update(pathlib=SimpleNamespace(Path=FakePath), sha=sha, execute=execute,
                 inspect_container=inspect, migrations=lambda: context["migrations"])
    return scope, context, records, data


class BackportTests(unittest.TestCase):
    def test_target_is_a_one_off_reviewed_artifact(self):
        backport.validate_target(backport.TARGET_COMMIT, backport.TARGET_IMAGE)
        for commit, image in (("a"*40, backport.TARGET_IMAGE), (backport.TARGET_COMMIT, backport.BASELINE_IMAGE)):
            with self.assertRaises(backport.BackportError): backport.validate_target(commit, image)

    def test_fresh_exact_backup_and_fail_closed_boundaries(self):
        now = time.time()
        backport.validate_backup(backup(now), backport.TARGET_IMAGE, now)
        changes = [{"project": "other"}, {"instance": "other"}, {"image": backport.BASELINE_IMAGE},
                   {"status": "FAILED"}, {"completedAt": now-3601}, {"completedAt": now+1},
                   {"completedAt": True}, {"backupId": "gs://wrong/test#123"}, {"backupId": "gs://nextstop-tech-staging-release-backups/production/nextstop-backend/test"}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(backport.BackportError):
                backport.validate_backup({**backup(now), **change}, backport.TARGET_IMAGE, now)

    def test_honest_private_candidate_evidence_is_required(self):
        now = datetime.now(timezone.utc)
        rows = staging(now)
        self.assertEqual(backport.validate_staging(rows, [{"state": "success"}], backport.TARGET_COMMIT, backport.TARGET_IMAGE, now), 123)
        for mode in ("absent", "stale", "future", "failed-check", "wrong-image", "wrong-mode", "revision", "failed-status"):
            rows = staging(now)
            value = rows[0]["payload"]["validation"]
            statuses = [{"state": "success"}]
            if mode == "absent": rows[0]["payload"].pop("validation")
            elif mode == "stale": value["verifiedAt"] = (now-timedelta(seconds=3601)).isoformat()
            elif mode == "future": value["verifiedAt"] = (now+timedelta(seconds=1)).isoformat()
            elif mode == "failed-check": value["checks"]["anonymousRequestsRejected"] = False
            elif mode == "wrong-image": value["image"] = backport.BASELINE_IMAGE
            elif mode == "wrong-mode": value["mode"] = "public-staging-release"
            elif mode == "revision": value["candidateRevisions"]["api"] = "wrong-revision"
            else: statuses = [{"state": "failure"}]
            with self.subTest(mode=mode), self.assertRaises(backport.BackportError):
                backport.validate_staging(rows, statuses, backport.TARGET_COMMIT, backport.TARGET_IMAGE, now)

    def test_newer_failed_staging_record_cannot_reuse_older_success(self):
        rows=staging()
        rows.append({**rows[0], "id":124, "payload":{"image":backport.TARGET_IMAGE}})
        with self.assertRaises(backport.BackportError):
            backport.validate_staging(rows, [{"state":"failure"}], backport.TARGET_COMMIT, backport.TARGET_IMAGE)

    def test_source_or_identity_rejection_precedes_host_mutations(self):
        for fail in ("identity", "source"):
            phases=[]
            def run(args, *, phase, **kwargs):
                phases.append(phase)
                if phase == "deployment-identity": return "wrong" if fail == "identity" else backport.DEPLOY_ACCOUNT
                if phase == "unchanged-application-and-schema": raise backport.BackportError("changed app source")
                return ""
            with self.subTest(fail=fail), self.assertRaises(backport.BackportError):
                backport.verify_source_and_staging(backport.TARGET_COMMIT, backport.TARGET_IMAGE, run=run)
            self.assertNotIn("staging-deployment",phases)
            self.assertFalse(any("ssh" in value for value in phases))

    def test_secret_subprocess_output_is_never_part_of_failure(self):
        with patch.object(backport.subprocess, "run", return_value=SimpleNamespace(returncode=1,stdout="PRIVATE-TOKEN",stderr="postgres://private")):
            with self.assertRaises(backport.BackportError) as error:
                backport.command(["false"], phase="fixed-phase")
        self.assertNotIn("PRIVATE",str(error.exception))
        self.assertNotIn("postgres",str(error.exception))

    def test_remote_preflight_has_no_pull_or_release(self):
        scope, context, records, data = remote_fixture()
        data["checkOnly"] = True
        with contextlib.redirect_stdout(io.StringIO()) as output: scope["main"](data)
        self.assertTrue(json.loads(output.getvalue())["passed"])
        self.assertFalse(any(args[:2]==["docker","pull"] or args[0]=="/usr/bin/python3" for args,_ in records))

    def test_remote_baseline_drift_fails_before_release(self):
        for failure in ("hash", "pending", "image", "schema", "labels", "container", "database"):
            scope, context, records, data = remote_fixture()
            if failure == "hash": context["hashes"]["deploy/releases/release.py"]="different"
            elif failure == "pending": context["state"]["pending"]={}
            elif failure == "image": context["state"]["image"]=backport.TARGET_IMAGE
            elif failure == "schema": context["migrations"].append("0016_unexpected.sql")
            elif failure == "labels": context["labels"]="wrong"
            elif failure == "container": context["appImage"]=backport.TARGET_IMAGE
            else: context["database"][-1]=False
            with self.subTest(failure=failure), contextlib.redirect_stdout(io.StringIO()) as output, self.assertRaises(SystemExit):
                scope["main"](data)
            self.assertFalse(json.loads(output.getvalue())["passed"])
            self.assertFalse(any(args[0]=="/usr/bin/python3" for args,_ in records))

    def test_remote_rechecks_backup_and_pulled_config_identity(self):
        for failure in ("backup", "image"):
            scope, context, records, data=remote_fixture()
            if failure == "backup": context["receipt"]["completedAt"]=0
            else: context["imageId"]="sha256:wrong"
            with self.subTest(failure=failure), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit): scope["main"](data)
            self.assertFalse(any(args[0]=="/usr/bin/python3" for args,_ in records))

    def test_remote_success_uses_only_pinned_installed_controller_without_migrations(self):
        scope, context, records, data=remote_fixture()
        with contextlib.redirect_stdout(io.StringIO()) as output: scope["main"](data)
        result=json.loads(output.getvalue())
        self.assertTrue(result["passed"])
        self.assertTrue(result["migrationsUnchanged"])
        releases=[args for args,_ in records if args[0]=="/usr/bin/python3"]
        self.assertEqual(len(releases),1)
        self.assertEqual(releases[0][1],backport.INSTALLED_ROOT+"/deploy/releases/release.py")
        self.assertIn("--skip-migrations",releases[0])
        self.assertIn("--backup-receipt",releases[0])

    def test_post_deploy_drift_never_reports_success(self):
        for failure in ("database", "schema", "environment", "controller", "rollback", "pending"):
            scope, context, records, data = remote_fixture()
            original = scope["execute"]
            def execute(args, env=None, timeout=90):
                result = original(args, env, timeout)
                if args[0] == "/usr/bin/python3":
                    if failure == "database": context["database"][3] = "unexpected-restart"
                    elif failure == "schema": context["migrations"].append("0016_unexpected.sql")
                    elif failure == "environment": context["protectedHash"] = "changed"
                    elif failure == "controller": context["hashes"]["deploy/releases/release.py"] = "changed"
                    elif failure == "rollback": context["state"].pop("previous")
                    else: context["state"]["pending"] = {}
                return result
            scope["execute"] = execute
            with self.subTest(failure=failure), contextlib.redirect_stdout(io.StringIO()) as output, self.assertRaises(SystemExit):
                scope["main"](data)
            self.assertFalse(json.loads(output.getvalue())["passed"])

    def test_both_docker_identity_formats_require_exact_source_and_platform(self):
        scope, context, records, data = remote_fixture()
        manifest = backport.TARGET_IMAGE.rsplit("@", 1)[1]
        descriptor = {"digest": manifest, "mediaType": "application/vnd.docker.distribution.manifest.v2+json"}
        for form in ("classic", "containerd"):
            valid = {"Id": backport.TARGET_CONFIG_DIGEST if form == "classic" else manifest,
                     "RepoDigests": [backport.TARGET_IMAGE], "Os": "linux", "Architecture": "amd64",
                     "Config": {"Labels": {"org.opencontainers.image.revision": backport.TARGET_COMMIT}}}
            if form == "containerd": valid["Descriptor"] = descriptor
            scope["verify_image"](valid, data)
            for failure in ("id", "descriptor-digest", "descriptor-type", "descriptor-shape", "architecture", "os", "repo", "repo-shape", "revision"):
                invalid = copy.deepcopy(valid)
                if failure == "id": invalid["Id"] = "sha256:" + "0" * 64
                elif failure.startswith("descriptor"):
                    invalid["Descriptor"] = dict(descriptor)
                    if failure == "descriptor-digest": invalid["Descriptor"]["digest"] = "sha256:" + "0" * 64
                    elif failure == "descriptor-type": invalid["Descriptor"]["mediaType"] = "application/vnd.oci.image.index.v1+json"
                    else: invalid["Descriptor"] = "unexpected"
                elif failure == "architecture": invalid["Architecture"] = "arm64"
                elif failure == "os": invalid["Os"] = "windows"
                elif failure == "repo": invalid["RepoDigests"] = [backport.BASELINE_IMAGE]
                elif failure == "repo-shape": invalid["RepoDigests"] = backport.TARGET_IMAGE
                else: invalid["Config"]["Labels"]["org.opencontainers.image.revision"] = backport.BASELINE_COMMIT
                with self.subTest(form=form, failure=failure), self.assertRaises(scope["GateError"]):
                    scope["verify_image"](invalid, data)
            if form == "containerd":
                invalid = copy.deepcopy(valid)
                invalid.pop("Descriptor")
                with self.assertRaises(scope["GateError"]): scope["verify_image"](invalid, data)

    def test_containerd_manifest_identity_passes_remote_gates(self):
        scope, context, records, data = remote_fixture()
        manifest = backport.TARGET_IMAGE.rsplit("@", 1)[1]
        context["imageId"] = manifest
        context["descriptor"] = {"digest": manifest, "mediaType": "application/vnd.docker.distribution.manifest.v2+json"}
        with contextlib.redirect_stdout(io.StringIO()) as output: scope["main"](data)
        self.assertTrue(json.loads(output.getvalue())["passed"])
        self.assertEqual(sum(args[0] == "/usr/bin/python3" for args, _ in records), 1)

    def test_subprocess_diagnostic_phase_is_allowlisted_without_private_output(self):
        for phase in ("host-image-identity", "PRIVATE-TOKEN"):
            stdout = json.dumps({"passed": False, "phase": phase, "error": "PRIVATE-DSN"})
            with patch.object(backport.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout=stdout, stderr="PRIVATE-STDERR")):
                with self.assertRaises(backport.BackportError) as error:
                    backport.command(["false"], phase="host-security-backport")
            self.assertEqual(error.exception.phase, phase if phase in backport.HOST_PHASES else "host-security-backport")
            self.assertNotIn("PRIVATE", str(error.exception))

    def test_cli_outputs_only_static_phase_and_error_text(self):
        for error in (backport.BackportError("PRIVATE-TOKEN", phase="registry-login"),
                      backport.BackportError("PRIVATE-DSN", phase="PRIVATE-PHASE"), ValueError("PRIVATE-VALUE")):
            argv = ["production-backport.py", "--commit", backport.TARGET_COMMIT, "--image", backport.TARGET_IMAGE]
            with patch("sys.argv", argv), patch.object(backport, "deploy", side_effect=error), contextlib.redirect_stdout(io.StringIO()) as output, self.assertRaises(SystemExit):
                backport.main()
            result = json.loads(output.getvalue())
            self.assertFalse(result["passed"])
            self.assertEqual(result["phase"], error.phase if isinstance(error, backport.BackportError) else "gate")
            self.assertNotIn("PRIVATE", output.getvalue())

    def test_registry_token_stays_on_stdin_and_cleanup_runs_on_failure(self):
        calls=[]
        def run(args, *, phase, input_text=None, **kwargs):
            calls.append((args,phase,input_text))
            if phase == "registry-credential": return "PRIVATE-TOKEN"
            if phase == "registry-login": raise backport.BackportError("login failed; suppressed")
            return ""
        with tempfile.TemporaryDirectory() as temporary:
            receipt=Path(temporary)/"backup.json"
            receipt.write_text(json.dumps(backup()))
            with patch.object(backport,"verify_source_and_staging",return_value=123), patch.object(backport,"host_check",return_value={"passed":True}), self.assertRaises(backport.BackportError):
                backport.deploy(backport.TARGET_COMMIT,backport.TARGET_IMAGE,receipt,run=run)
        self.assertFalse(any("PRIVATE-TOKEN" in str(args) for args,_,_ in calls))
        self.assertEqual([stdin for _,phase,stdin in calls if phase=="registry-login"],["PRIVATE-TOKEN\n"])
        self.assertIn("registry-cleanup",[phase for _,phase,_ in calls])
        self.assertIn("receipt-cleanup",[phase for _,phase,_ in calls])
        uploads=[args for args,_,_ in calls if args[:3]==["gcloud","compute","scp"]]
        self.assertEqual(len(uploads),1)
        self.assertIn("nextstop-security-backup-",uploads[0][4])

    def test_workflow_keeps_protected_environment_backup_and_normal_route(self):
        workflow=(Path(__file__).parents[2]/".github/workflows/backend-production.yml").read_text()
        for required in ("environment: production", "github.ref == 'refs/heads/main'", "deploy/gcp/verify-promotion.py",
                         "deploy/gcp/backup.py", "if: ${{ !inputs.security_only }}", "--check-only", "default: false"):
            self.assertIn(required,workflow)
        self.assertEqual(workflow.count("uses: actions/checkout@v7"),1)
        self.assertNotIn("ref: ${{ inputs.commit }}",workflow)


if __name__ == "__main__":
    unittest.main()
