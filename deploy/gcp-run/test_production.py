"""Synthetic production targeting, image, and backup integrity contract tests."""
import copy
import json
from datetime import datetime, timezone
from pathlib import Path
import unittest
from unittest.mock import patch

import deploy
import production
import production_backup as backup
import release
import render
from test_render import env


COMMIT = "a" * 40
IMAGE = render.REGISTRY + "@sha256:" + "b" * 64
EVIDENCE = {"generation": "42", "sha256": "c" * 64, "object": "operations/evidence/" + "c" * 64 + ".json"}


class ProductionTests(unittest.TestCase):
    def test_production_manifests_are_isolated_and_app_attest_rejects_development(self):
        config = production.configuration(COMMIT, IMAGE, EVIDENCE)
        items = render.render(config)
        self.assertEqual(set(items), {*render.SERVICES, *render.JOBS, "queue", "logging-exclusion",
                                      *("scheduler-" + name for name in render.SCHEDULES)})
        for name in render.SERVICES:
            service = items[name]
            self.assertEqual(service["metadata"]["namespace"], render.PRODUCTION.number)
            self.assertEqual(service["spec"]["template"]["spec"]["serviceAccountName"], render.account(name, render.PRODUCTION))
            for row in env(service).values():
                if "valueFrom" in row:
                    self.assertTrue(row["valueFrom"]["secretKeyRef"]["name"].startswith("nextstop-production-"))
        self.assertEqual(env(items["auth"])["APP_ATTEST_ALLOW_DEVELOPMENT"]["value"], "false")
        self.assertEqual(env(items["api"])["CLOUD_SQL_CONNECTION_NAME"]["value"], render.PRODUCTION.connection)
        self.assertEqual(env(items["gateway"])["BACKEND_API_AUDIENCE"]["value"], render.origin("api", target=render.PRODUCTION))
        self.assertEqual(items["logging-exclusion"]["name"], "nextstop-production-cloud-run-requests")
        self.assertEqual(production.sql_definition(config)["settings"]["dataDiskSizeGb"], "100")
        commands = release.definitions_plan(config, Path("/tmp/example"), True)["commands"] + release.promotion_plan(config)
        self.assertTrue(all("--project=" + render.PRODUCTION.project in cmd for cmd in commands))
        self.assertTrue(all("nextstop-tech-testing" not in str(item) for item in items.values()))

    def test_no_placeholder_evidence_or_cross_target_runtime_is_accepted(self):
        config = production.configuration(COMMIT, IMAGE, None, offline=True)
        deploy.acceptance_hashes(config)
        with self.assertRaises(render.ConfigurationError):
            deploy.deploy(config, target=render.PRODUCTION)
        config = production.configuration(COMMIT, IMAGE, EVIDENCE)
        with self.assertRaises(render.ConfigurationError):
            render.validate(config)  # The standalone legacy staging paths remain staging-only.
        for field, invalid in (("backupBucket", "nextstop-tech-testing-database-backups"),
                               ("cloudSqlConnectionName", render.CONNECTION), ("appAttestAppId", "ABCDEFGHIJ.another.app")):
            with self.subTest(field=field), self.assertRaises(render.ConfigurationError):
                render.render({**config, field: invalid})

    def test_all_image_severities_and_immutable_identity_required(self):
        config = production.configuration(COMMIT, IMAGE, EVIDENCE)
        counts = dict.fromkeys(["UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"], 0)
        report = {"commit": COMMIT, "image": IMAGE, "passed": True, "inventoryProfile": "backend",
                  "scanner": "trivy", "blockingFindings": [], "counts": counts}
        production.require_clean_scan(config, report)
        for invalid in ({**report, "image": IMAGE + "1"}, {**report, "counts": {**counts, "LOW": 1}},
                        {**report, "counts": {}}, {**report, "blockingFindings": ["CVE"]}):
            with self.assertRaises(release.ReleaseError):
                production.require_clean_scan(config, invalid)

    def test_backup_rejects_other_images_credentials_and_database_connections(self):
        config = production.configuration(COMMIT, IMAGE, EVIDENCE)
        template = render.job(config, "backup")["spec"]["template"]
        backup.verify_task(template["metadata"], template["spec"], IMAGE)
        for field in ("image", "command", "database", "bucket", "role"):
            invalid = copy.deepcopy(template)
            task = invalid["spec"]["template"]["spec"]
            container = task["containers"][0]
            if field == "image":
                container["image"] += "0"
            if field == "command":
                container["command"] = ["sh"]
            if field == "database":
                invalid["metadata"]["annotations"]["run.googleapis.com/cloudsql-instances"] = render.CONNECTION
            if field == "bucket":
                next(v for v in container["env"] if v["name"] == "BACKUP_BUCKET")["value"] = "other"
            if field == "role":
                task["serviceAccountName"] = render.account("api", render.PRODUCTION)
            with self.subTest(field=field), self.assertRaises(release.ReleaseError):
                backup.verify_task(invalid["metadata"], invalid["spec"], IMAGE)

    def test_backup_execution_rechecks_the_immutable_job_and_readback_evidence(self):
        config = production.configuration(COMMIT, IMAGE, EVIDENCE)
        job = render.job(config, "backup")
        job["metadata"].update(uid="test-uid", generation=7)
        template = job["spec"]["template"]
        execution = "nextstop-backup-xyz12"
        meta = {"annotations": {**template["metadata"]["annotations"], "run.googleapis.com/creator": render.PRODUCTION.deploy_account},
                "namespace": render.PRODUCTION.number, "name": execution,
                "labels": {"run.googleapis.com/job": "nextstop-backup", "run.googleapis.com/jobUid": "test-uid",
                           "run.googleapis.com/jobGeneration": "7"}}
        finished = {"metadata": meta, "spec": template["spec"],
                    "status": {"succeededCount": 1, "completionTime": "done", "conditions": [{"type": "Completed", "status": "True"}]}}
        date = datetime.now(timezone.utc).date().isoformat()
        row = {"jsonPayload": {"event": "production_backup_completed", "execution": execution, "integrityVerified": True,
               "reportsExcluded": True, "bytes": 100, "receiptGeneration": "123",
               "receiptObject": f"production/{date}/6b065e0e-538a-4205-a002-591df2fd3d04.json"}}
        def invoke():
            with patch.object(backup, "active_image", return_value=IMAGE), \
                 patch.object(release, "json_command", side_effect=[job, [row]]), \
                 patch.object(release, "run", return_value=json.dumps(finished)):
                return backup.backup()
        self.assertEqual(invoke()["receiptGeneration"], "123")
        meta["labels"]["run.googleapis.com/jobGeneration"] = "8"
        with self.assertRaises(release.ReleaseError):
            invoke()

    def test_backup_requires_this_execution_and_a_pinned_report_filtered_verified_receipt(self):
        now = datetime(2026, 10, 31, 12, tzinfo=timezone.utc)
        execution = "nextstop-backup-xyz12"
        event = {"event": "production_backup_completed", "execution": execution, "integrityVerified": True,
                 "reportsExcluded": True, "bytes": 441_013, "receiptGeneration": "123456",
                 "receiptObject": "production/2026-10-31/6b065e0e-538a-4205-a002-591df2fd3d04.json"}
        self.assertEqual(backup.completion(event, execution, now, now)["bucket"], backup.BACKUP_BUCKET)
        for key, value in (("reportsExcluded", False), ("integrityVerified", False), ("execution", "other"),
                           ("bytes", 0), ("receiptGeneration", "latest"),
                           ("receiptObject", event["receiptObject"].replace("2026-10-31", "2026-10-30"))):
            with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                backup.completion({**event, key: value}, execution, now, now)
