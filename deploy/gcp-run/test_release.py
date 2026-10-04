"""Mocked control-plane regression tests; no credentials or cloud requests."""
import copy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release
import render
from test_render import configuration


NOW = datetime(2026, 10, 4, 12, tzinfo=timezone.utc)


def receipt(config):
    return {"release": render.release_id(config), "image": config["backendImage"], "commit": config["commit"],
            "verifiedAt": NOW.isoformat(), "apiReady": True, "authReady": True, "syntheticSearchPassed": True,
            "clientIPIsolationPassed": True, "loggingExclusionVerified": True, "jobsBudgetVerified": True,
            "privateIAMVerified": True, "artifactVerified": True, "filteredBackupRestorePassed": True,
            "liveTaskCompatibilityPassed": True, "xffPrefixResistancePassed": True,
            "idleScaleToZeroPassed": True, "databasePerformancePassed": True}


def metadata(config, applied=False):
    manifests = render.render(config)
    traffic = {name: manifests[name]["spec"]["traffic"] for name in render.SERVICES} if applied else config["retainedTraffic"]
    return {
        "project": {"projectId": render.PROJECT, "projectNumber": render.PROJECT_NUMBER},
        "services": [{"metadata": {"name": "nextstop-" + name}, "status": {"traffic": rows}} for name, rows in traffic.items()],
        "sql": {"databaseVersion": "POSTGRES_17", "region": render.REGION,
                "settings": {"tier": "db-g1-small", "dataDiskSizeGb": "50", "dataDiskType": "PD_SSD", "availabilityType": "ZONAL", "backupConfiguration": {"enabled": False, "pointInTimeRecoveryEnabled": False},
                             "connectorEnforcement": "REQUIRED", "storageAutoResize": False,
                             "ipConfiguration": {"ipv4Enabled": True, "requireSsl": True,
                                                 "sslMode": "TRUSTED_CLIENT_CERTIFICATE_REQUIRED", "serverCaMode": "GOOGLE_MANAGED_INTERNAL_CA"},
                             "databaseFlags": [{"name": name, "value": value} for name, value in {
                                 "log_connections": "off", "log_disconnections": "off", "log_min_duration_statement": "-1",
                                 "log_min_error_statement": "panic", "log_parameter_max_length": "0",
                                 "log_parameter_max_length_on_error": "0", "log_statement": "none",
                             }.items()]}},
        "sink": {"exclusions": [copy.deepcopy(render.LOG_EXCLUSION)]},
        "queues": [{"name": "projects/p/locations/r/queues/" + render.QUEUE}] if applied else [],
        "schedules": [], "executions": [], "iam": {"bindings": []},
        "revisions": {"nextstop-" + name + "-" + render.release_id(config): {
            "metadata": manifests[name]["spec"]["template"]["metadata"],
            "spec": manifests[name]["spec"]["template"]["spec"],
            "status": {"imageDigest": config["backendImage"], "conditions": [{"type": "Ready", "status": "True"}]},
        } for name in render.SERVICES},
    }


def respond(data):
    def call(command):
        assert command[0] == "gcloud"
        assert "--project=" + render.PROJECT in command
        family = command[1:4]
        if command[1:3] == ["projects", "describe"]:
            return data["project"]
        if family == ["run", "services", "list"]:
            return data["services"]
        if family == ["run", "services", "get-iam-policy"]:
            return data["iam"]
        if family == ["run", "revisions", "describe"]:
            return data["revisions"][command[4]]
        if family == ["sql", "instances", "describe"]:
            return data["sql"]
        if family == ["logging", "sinks", "describe"]:
            return data["sink"]
        if family == ["tasks", "queues", "list"]:
            return data["queues"]
        if family == ["scheduler", "jobs", "list"]:
            return data["schedules"]
        if command[1:5] == ["run", "jobs", "executions", "list"]:
            return data["executions"]
        raise AssertionError("Unexpected command family")
    return call


class ReleaseTests(unittest.TestCase):
    def test_sql_security_accepts_actual_connector_schema_and_empty_network_serialization(self):
        for explicit_empty in (False, True):
            with self.subTest(explicit_empty=explicit_empty):
                config = configuration()
                data = metadata(config)
                settings = data["sql"]["settings"]
                if explicit_empty:
                    settings["ipConfiguration"]["authorizedNetworks"] = []
                    # Deprecated requireSsl need not accompany authoritative sslMode.
                    del settings["ipConfiguration"]["requireSsl"]
                    settings["databaseFlags"].append({"name": "log_min_duration_sample", "value": "-1"})
                settings["databaseFlags"].append({"name": "max_connections", "value": "100"})
                with patch.object(release, "json_command", side_effect=respond(data)) as call:
                    release.preflight(config, False)
                sql_command = next(args.args[0] for args in call.call_args_list if args.args[0][1:4] == ["sql", "instances", "describe"])
                for field in ("connectorEnforcement", "ipConfiguration", "databaseFlags", "storageAutoResize"):
                    self.assertIn("settings." + field, sql_command[5])

    def test_sql_security_drift_blocks_before_following_control_plane_calls(self):
        faults = ("connector", "missing_connector", "networks", "malformed_networks", "tls", "missing_tls",
                  "storage", "missing_storage", "missing_flags", "duplicate_flags", "malformed_flags", "sampled_statements")
        for fault in faults:
            with self.subTest(fault=fault):
                config = configuration()
                data = metadata(config)
                settings = data["sql"]["settings"]
                if fault == "connector": settings["connectorEnforcement"] = "NOT_REQUIRED"
                elif fault == "missing_connector": del settings["connectorEnforcement"]
                elif fault == "networks": settings["ipConfiguration"]["authorizedNetworks"] = [{"value": "0.0.0.0/0"}]
                elif fault == "malformed_networks": settings["ipConfiguration"]["authorizedNetworks"] = None
                elif fault == "tls": settings["ipConfiguration"]["sslMode"] = "ENCRYPTED_ONLY"
                elif fault == "missing_tls": del settings["ipConfiguration"]["sslMode"]
                elif fault == "storage": settings["storageAutoResize"] = True
                elif fault == "missing_storage": del settings["storageAutoResize"]
                elif fault == "missing_flags": del settings["databaseFlags"]
                elif fault == "duplicate_flags": settings["databaseFlags"].append(copy.deepcopy(settings["databaseFlags"][0]))
                elif fault == "malformed_flags": settings["databaseFlags"][0]["value"] = False
                else: settings["databaseFlags"].append({"name": "log_min_duration_sample", "value": "100"})
                with patch.object(release, "json_command", side_effect=respond(data)) as call, self.assertRaises(release.ReleaseError):
                    release.preflight(config, False)
                self.assertEqual(call.call_args.args[0][1:4], ["sql", "instances", "describe"])

    def test_each_missing_or_changed_redaction_flag_blocks_release(self):
        for name in release.SQL_LOG_FLAGS:
            for missing in (False, True):
                with self.subTest(name=name, missing=missing):
                    settings = metadata(configuration())["sql"]["settings"]
                    row = next(row for row in settings["databaseFlags"] if row["name"] == name)
                    if missing: settings["databaseFlags"].remove(row)
                    else: row["value"] = "unsafe-value"
                    with self.assertRaisesRegex(release.ReleaseError, "logging redaction"):
                        release.verify_sql_security(settings)

    def test_plan_has_no_iam_dns_migration_execution_or_schedule_mutations(self):
        config = configuration()
        with patch.object(release.subprocess, "run", side_effect=AssertionError("No calls permitted")):
            plan = release.definitions_plan(config, Path("/tmp/rendered"), False)
        self.assertEqual(len(plan["commands"]), 11)
        for cmd in plan["commands"]:
            self.assertIn("--project=" + render.PROJECT, cmd)
            self.assertNotIn("execute", cmd)
            self.assertNotIn("scheduler", cmd)
            self.assertNotIn("iam", cmd)
        changed = copy.deepcopy(config)
        changed["secretVersions"]["auth-database-url"] = "3"
        self.assertNotEqual(plan["planSha256"], release.definitions_plan(changed, Path("/tmp/rendered"), False)["planSha256"])

    def test_promotion_after_initial_apply_accepts_new_queue_and_tags(self):
        config = configuration()
        data = metadata(config, applied=True)
        with patch.object(release, "json_command", side_effect=respond(data)):
            release.preflight(config, queue_exists=False, candidates_applied=True)
        data["services"][0]["status"]["traffic"][0]["tag"] = "r-000000000000"
        with patch.object(release, "json_command", side_effect=respond(data)), self.assertRaisesRegex(release.ReleaseError, "traffic changed"):
            release.preflight(config, False, candidates_applied=True)

    def test_lost_retained_tag_and_concurrent_traffic_change_block_apply(self):
        config = configuration()
        config["retainedTraffic"]["api"] = [
            {"revisionName": "nextstop-api-old", "percent": 100, "tag": "r-111111111111"},
            {"revisionName": "nextstop-api-older", "percent": 0, "tag": "r-222222222222"},
        ]
        data = metadata(config)
        # The nonserving tag is needed by a retained gateway for rollback.
        data["services"][0]["status"]["traffic"] = data["services"][0]["status"]["traffic"][:1]
        with patch.object(release, "json_command", side_effect=respond(data)), self.assertRaisesRegex(release.ReleaseError, "traffic changed"):
            release.preflight(config, False)

    def test_preflight_requires_log_exclusion_paused_schedules_and_no_active_jobs(self):
        for fault in ("logging", "schedule", "execution", "sql", "backups"):
            with self.subTest(fault=fault):
                config = configuration()
                data = metadata(config)
                if fault == "logging":
                    data["sink"]["exclusions"][0]["disabled"] = True
                elif fault == "schedule":
                    data["schedules"] = [{"name": "projects/p/locations/r/jobs/nextstop-backup", "state": "ENABLED"}]
                elif fault == "execution":
                    data["executions"] = [{"metadata": {"labels": {"run.googleapis.com/job": "nextstop-migrate"}}, "status": {}}]
                elif fault == "sql":
                    data["sql"]["settings"]["dataDiskType"] = "PD_HDD"
                else:
                    data["sql"]["settings"]["backupConfiguration"]["enabled"] = True
                with patch.object(release, "json_command", side_effect=respond(data)), self.assertRaises(release.ReleaseError):
                    release.preflight(config, False)

    def test_public_private_service_and_changed_candidate_secret_block_promotion(self):
        for fault in ("iam", "iam-bypass", "secret", "image", "identity", "mount", "resources", "ready"):
            with self.subTest(fault=fault):
                config = configuration()
                data = metadata(config, applied=True)
                revision = data["revisions"]["nextstop-api-" + render.release_id(config)]
                if fault == "iam":
                    data["iam"] = {"bindings": [{"role": "roles/run.invoker", "members": ["allUsers"]}]}
                elif fault == "iam-bypass":
                    data["services"][1]["metadata"]["annotations"] = {"run.googleapis.com/invoker-iam-disabled": "true"}
                elif fault == "secret":
                    item = next(v for v in revision["spec"]["containers"][0]["env"] if v["name"] == "DATABASE_URL")
                    item["valueFrom"]["secretKeyRef"]["key"] = "latest"
                elif fault == "image":
                    revision["status"]["imageDigest"] = render.REGISTRY + "@sha256:" + "c" * 64
                elif fault == "identity":
                    revision["spec"]["serviceAccountName"] = render.account("auth")
                elif fault == "mount":
                    revision["metadata"]["annotations"]["run.googleapis.com/cloudsql-instances"] = "other:r:db"
                elif fault == "resources":
                    revision["spec"]["containers"][0]["resources"]["limits"]["cpu"] = "2"
                else:
                    revision["status"]["conditions"][0]["status"] = "False"
                with patch.object(release, "json_command", side_effect=respond(data)), self.assertRaises(release.ReleaseError):
                    release.preflight(config, False, candidates_applied=True)

    def test_receipt_requires_recent_exact_release_and_all_real_gates(self):
        config = configuration()
        release.verify_receipt(config, receipt(config), now=NOW)
        for fault in ("old", "future", "image", "gate", "missing"):
            with self.subTest(fault=fault):
                value = receipt(config)
                if fault == "old":
                    value["verifiedAt"] = (NOW - timedelta(seconds=3601)).isoformat()
                elif fault == "future":
                    value["verifiedAt"] = (NOW + timedelta(seconds=1)).isoformat()
                elif fault == "image":
                    value["image"] = render.REGISTRY + "@sha256:" + "c" * 64
                elif fault == "gate":
                    value["filteredBackupRestorePassed"] = False
                else:
                    del value["privateIAMVerified"]
                with self.assertRaises(release.ReleaseError):
                    release.verify_receipt(config, value, now=NOW)

    def test_gateway_is_last_promotion_and_no_tag_replacement_flag(self):
        commands = release.promotion_plan(configuration())
        self.assertEqual(commands[-1][4], "nextstop-gateway")
        for command in commands:
            self.assertFalse(any(arg.startswith(("--set-tags", "--remove-tags", "--clear-tags")) for arg in command))

    def test_cloud_failure_details_are_not_reflected(self):
        result = subprocess.CompletedProcess(["gcloud"], 1, "sensitive stdout", "sensitive stderr")
        with patch.object(release.subprocess, "run", return_value=result), self.assertRaises(release.ReleaseError) as caught:
            release.run(["gcloud"])
        self.assertNotIn("sensitive", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
