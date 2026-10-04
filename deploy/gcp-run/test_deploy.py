import contextlib
import copy
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import deploy
import registry
import release
import render
import verify
from test_render import configuration


def source_fixture(root):
    for pattern in deploy.COMMON_SOURCES + [pattern for patterns in deploy.OPERATOR_GATES.values() for pattern in patterns]:
        target = root / pattern.replace("*", "fixture")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("synthetic critical source\n")


def acceptance(config, root):
    return {"version": 1, "environment": "staging", "project": render.PROJECT,
            "verifiedAt": "2026-10-04T01:00:00Z",
            "checks": {key: {"passed": True, "sourceSha256": value} for key, value in deploy.acceptance_hashes(config, root).items()}}


class DeployTests(unittest.TestCase):
    def test_wif_identity_uses_fixed_self_oidc_endpoint_without_access_token_impersonation(self):
        from unittest.mock import MagicMock
        connection = MagicMock()
        connection.getresponse.return_value.status = 200
        connection.getresponse.return_value.read.return_value = b'{"token":"synthetic.header.signature"}'
        with patch.object(deploy.http.client, "HTTPSConnection", return_value=connection) as https, \
                patch.object(registry, "get_token", return_value="synthetic-access-token"), \
                patch.object(release, "run", side_effect=AssertionError("No ID-token CLI command")):
            self.assertEqual(deploy.identity_token(render.origin("gateway")), "synthetic.header.signature")
        https.assert_called_once_with("iamcredentials.googleapis.com", timeout=30)
        request = connection.request.call_args
        self.assertEqual(request.args[:2], ("POST", "/v1/projects/-/serviceAccounts/" + deploy.DEPLOY_ACCOUNT + ":generateIdToken"))
        self.assertEqual(json.loads(request.kwargs["body"]), {"audience": render.origin("gateway"), "includeEmail": True})
        connection.close.assert_called_once()
        with patch.object(deploy.http.client, "HTTPSConnection") as blocked, self.assertRaises(release.ReleaseError):
            deploy.identity_token("https://unapproved.example")
        blocked.assert_not_called()

    def test_acceptance_reuses_docs_only_build_but_rejects_critical_source_or_secret_change(self):
        config = configuration()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_fixture(root)
            record = acceptance(config, root)
            now = datetime(2026, 10, 4, 2, tzinfo=timezone.utc)
            deploy.verify_acceptance(config, record, root, now)
            (root / "README.md").write_text("docs only change")
            changed = dict(config, commit="d" * 40, backendImage=render.REGISTRY + "@sha256:" + "d" * 64)
            deploy.verify_acceptance(changed, record, root, now)
            changed = copy.deepcopy(config)
            changed["secretVersions"]["api-database-url"] = "3"
            with self.assertRaises(release.ReleaseError):
                deploy.verify_acceptance(changed, record, root, now)
            (root / "backend/src/jobs/database-backup.ts").write_text("changed dump semantics")
            with self.assertRaises(release.ReleaseError):
                deploy.verify_acceptance(config, record, root, now)

    def test_provider_changes_invalidate_budget_and_performance_evidence_only(self):
        cases = [
            ("modify", "backend/src/providers/object-download-cache.ts"),
            ("modify", "backend/src/providers/openstreetmap/geofabrik-downloader.ts"),
            ("add", "backend/src/providers/new-source/nested/normalizer.ts"),
            ("delete", "backend/src/providers/openstreetmap/geofabrik-downloader.ts"),
        ]
        affected = {"jobsBudgetVerified", "databasePerformancePassed"}
        now = datetime(2026, 10, 4, 2, tzinfo=timezone.utc)
        for operation, relative in cases:
            with self.subTest(operation=operation, path=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source_fixture(root)
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                if operation != "add":
                    path.write_text("reviewed provider behavior")
                config = configuration()
                record = acceptance(config, root)
                deploy.verify_acceptance(config, record, root, now)
                if operation == "delete":
                    path.unlink()
                else:
                    path.write_text("changed provider download or normalization behavior")
                hashes = deploy.acceptance_hashes(config, root)
                changed = {gate for gate, digest in hashes.items()
                           if digest != record["checks"][gate]["sourceSha256"]}
                self.assertEqual(changed, affected)
                with self.assertRaises(release.ReleaseError):
                    deploy.verify_acceptance(config, record, root, now)
                # Renewing only the two affected checks preserves the independent
                # IP, recovery, live-task and idle-scale acceptance records.
                renewed = copy.deepcopy(record)
                for gate in affected:
                    renewed["checks"][gate]["sourceSha256"] = hashes[gate]
                deploy.verify_acceptance(config, renewed, root, now)

    def test_evidence_hash_and_generation_cannot_be_omitted(self):
        config = configuration()
        config["acceptanceEvidence"]["generation"] = "latest"
        with self.assertRaises(render.ConfigurationError):
            render.validate(config)
        config = configuration()
        config["acceptanceEvidence"]["object"] = "private-database.dump"
        with self.assertRaises(render.ConfigurationError):
            render.validate(config)

    def test_only_originally_enabled_schedules_are_restored(self):
        original = {"nextstop-" + name: "ENABLED" for name in render.SCHEDULES}
        original["nextstop-monthly"] = "PAUSED"
        current = {name: "PAUSED" for name in original}
        with patch.object(deploy, "schedule_snapshot", return_value=current), patch.object(release, "run") as run:
            deploy.set_schedules(original, "resume")
        self.assertEqual(len(run.call_args_list), 3)
        self.assertTrue(all("nextstop-monthly" not in call.args[0] for call in run.call_args_list))

    def pipeline(self, fail_public=False, fail_candidate=False, fail_preflight=False):
        config = configuration()
        config["retainedTraffic"] = {name: [{"revisionName": "nextstop-" + name + "-old", "percent": 100, "tag": "r-111111111111"}] for name in render.SERVICES}
        commands, actions = [], []

        def run(command, **_kwargs):
            if command[0] == "git":
                return config["commit"] if "rev-parse" in command else ""
            if command[1:4] == ["config", "get-value", "account"]:
                return deploy.DEPLOY_ACCOUNT
            commands.append(command)
            return ""

        gates = {"apiReady": True, "authReady": True, "syntheticSearchPassed": True, "xffPrefixResistancePassed": True}
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(release, "run", side_effect=run))
            stack.enter_context(patch.object(deploy, "read_acceptance", return_value={}))
            stack.enter_context(patch.object(deploy, "verify_acceptance", return_value={key: True for key in deploy.OPERATOR_GATES}))
            stack.enter_context(patch.object(registry, "get_token", return_value="synthetic-iam-token"))
            stack.enter_context(patch.object(registry, "verify", return_value={"verified": True}))
            stack.enter_context(patch.object(release, "current_services", return_value=[]))
            stack.enter_context(patch.object(release, "service_snapshot", return_value=config["retainedTraffic"]))
            stack.enter_context(patch.object(deploy, "schedule_snapshot", return_value={"nextstop-" + name: "ENABLED" for name in render.SCHEDULES}))
            stack.enter_context(patch.object(deploy, "set_schedules", side_effect=lambda _snapshot, action: actions.append(action)))
            stack.enter_context(patch.object(release, "preflight", side_effect=release.ReleaseError("preflight") if fail_preflight else None))
            stack.enter_context(patch.object(verify, "verify", side_effect=release.ReleaseError("candidate") if fail_candidate else lambda *_: gates))
            stack.enter_context(patch.object(verify, "verify_public", side_effect=release.ReleaseError("public") if fail_public else None))
            stack.enter_context(patch.object(deploy.time, "sleep"))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            failed = fail_public or fail_candidate or fail_preflight
            if failed:
                with self.assertRaises(release.ReleaseError):
                    deploy.deploy(config)
            else:
                deploy.deploy(config)
        return commands, actions

    def test_real_gate_orchestration_migrates_before_definitions_and_gateway_last(self):
        commands, actions = self.pipeline()
        execute = next(i for i, command in enumerate(commands) if command[1:4] == ["run", "jobs", "execute"])
        first_service = next(i for i, command in enumerate(commands) if command[1:4] == ["run", "services", "replace"])
        self.assertLess(execute, first_service)
        traffic = [command for command in commands if "update-traffic" in command]
        self.assertEqual(traffic[-1][4], "nextstop-gateway")
        self.assertEqual(actions, ["pause", "resume"])

    def test_candidate_failure_never_promotes_and_leaves_new_jobs_paused(self):
        commands, actions = self.pipeline(fail_candidate=True)
        self.assertFalse(any("update-traffic" in command for command in commands))
        self.assertNotIn("resume", actions)

    def test_public_failure_restores_original_gateway_first_and_keeps_jobs_paused(self):
        commands, actions = self.pipeline(fail_public=True)
        rollbacks = [command for command in commands if any(arg.endswith("-old=100") for arg in command)]
        self.assertEqual(len(rollbacks), 5)
        self.assertEqual(rollbacks[0][4], "nextstop-gateway")
        self.assertNotIn("resume", actions)

    def test_preflight_failure_restores_previous_schedules_without_job_mutation(self):
        commands, actions = self.pipeline(fail_preflight=True)
        self.assertEqual(commands, [])
        self.assertEqual(actions, ["pause", "resume"])

    def test_workflow_keeps_main_trust_and_vm_default_while_selecting_cloud_run_explicitly(self):
        workflow = (deploy.ROOT / ".github/workflows/backend-staging.yml").read_text()
        self.assertIn("github.event.workflow_run.head_branch == 'main'", workflow)
        self.assertIn("github.event.workflow_run.event == 'push'", workflow)
        self.assertIn("github.event.workflow_run.head_repository.full_name == 'nellesf/nextStop'", workflow)
        self.assertIn("vars.NEXTSTOP_STAGING_HOSTING == 'cloud-run'", workflow)
        self.assertIn("vars.NEXTSTOP_STAGING_HOSTING != 'cloud-run'", workflow)
        self.assertIn("python3 deploy/gcp-run/deploy.py", workflow)
        self.assertIn("cancel-in-progress: false", workflow)


if __name__ == "__main__":
    unittest.main()
