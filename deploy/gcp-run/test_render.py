"""Release isolation and resource budgets; all inputs are synthetic."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

import render


def configuration():
    return {
        "environment": "staging", "project": render.PROJECT, "region": render.REGION,
        "backendImage": render.REGISTRY + "@sha256:" + "a" * 64, "commit": "b" * 40,
        "cloudSqlConnectionName": render.CONNECTION,
        "cacheBucket": "nextstop-tech-testing-downloads", "backupBucket": "nextstop-tech-testing-backups",
        "appAttestAppId": "ABCDEFGHIJ.example.NextStop",
        "secretVersions": {name: "2" for name in render.SECRETS}, "retainedTraffic": {},
        "acceptanceEvidence": {"object": "operations/evidence/" + "c" * 64 + ".json", "generation": "12345", "sha256": "c" * 64},
    }


def env(manifest):
    return {row["name"]: row for row in manifest["spec"]["template"]["spec"]["containers"][0]["env"]}


class RenderTests(unittest.TestCase):
    def test_separate_service_identities_and_secret_boundaries(self):
        output = render.render(configuration())
        for name in render.SERVICES:
            self.assertEqual(output[name]["spec"]["template"]["spec"]["serviceAccountName"], render.account(name))
        self.assertFalse(any("valueFrom" in row for row in env(output["gateway"]).values()))
        self.assertNotIn("run.googleapis.com/cloudsql-instances", output["gateway"]["spec"]["template"]["metadata"]["annotations"])
        self.assertNotIn("DATABASE_TRANSPORT", env(output["broker"]))
        self.assertEqual([key for key, value in env(output["broker"]).items() if "valueFrom" in value], ["SEARCH_ACCESS_TOKEN_SIGNING_KEY"])
        self.assertNotIn("AUTH_DATABASE_URL", env(output["api"]))
        self.assertEqual(env(output["api"])["DATABASE_URL"]["valueFrom"]["secretKeyRef"], {"name": "nextstop-staging-api-database-url", "key": "2"})
        self.assertEqual(env(output["api"])["ALLOW_LEGACY_STAGING_BEARER"]["value"], "false")

    def test_old_gateway_targets_remain_tagged_until_explicit_promotion(self):
        config = configuration()
        for name in render.SERVICES:
            config["retainedTraffic"][name] = [{"revisionName": "nextstop-" + name + "-old", "percent": 100, "tag": "r-111111111111"}]
        output = render.render(config)
        for name in render.SERVICES:
            self.assertEqual(output[name]["spec"]["traffic"][0], config["retainedTraffic"][name][0])
            self.assertEqual(output[name]["spec"]["traffic"][1]["percent"], 0)
        gateway_env = env(output["gateway"])
        for name in ("api", "auth"):
            self.assertEqual(gateway_env["BACKEND_" + name.upper() + "_ORIGIN"]["value"], render.origin(name, "r-" + render.release_id(config)))
            self.assertEqual(gateway_env["BACKEND_" + name.upper() + "_AUDIENCE"]["value"], render.origin(name))
        self.assertEqual(render.release_id(config), render.release_id(configuration()))

    def test_changed_secret_version_creates_new_revision(self):
        config = configuration()
        old = render.release_id(config)
        config["secretVersions"]["access-token-signing-key"] = "3"
        self.assertNotEqual(old, render.release_id(config))

    def test_refuses_mutable_image_latest_secret_and_cross_project(self):
        cases = [("backendImage", render.REGISTRY + ":latest"), ("project", "nextstop-tech-staging"),
                 ("environment", "production"), ("cloudSqlConnectionName", "other:europe-west1:db"),
                 ("cacheBucket", "production-cache"), ("commit", "abc123")]
        for key, value in cases:
            with self.subTest(key=key):
                config = configuration()
                config[key] = value
                with self.assertRaises(render.ConfigurationError):
                    render.render(config)
        config = configuration()
        config["secretVersions"]["auth-database-url"] = "latest"
        with self.assertRaises(render.ConfigurationError):
            render.render(config)
        config = configuration()
        config["backupBucket"] = config["cacheBucket"]
        with self.assertRaises(render.ConfigurationError):
            render.render(config)

    def test_retained_tags_cannot_be_repointed_or_omitted_by_latest_revision(self):
        config = configuration()
        config["retainedTraffic"]["api"] = [{"revisionName": "nextstop-api-old", "percent": 100, "tag": "r-" + render.release_id(config)}]
        with self.assertRaises(render.ConfigurationError):
            render.render(config)
        config["retainedTraffic"]["api"] = [{"latestRevision": True, "percent": 100}]
        with self.assertRaises(render.ConfigurationError):
            render.render(config)

    def test_service_limits_and_probes_never_poll_the_database(self):
        output = render.render(configuration())
        for name in render.SERVICES:
            template = output[name]["spec"]["template"]
            self.assertEqual(template["metadata"]["annotations"]["autoscaling.knative.dev/minScale"], "0")
            self.assertEqual(template["metadata"]["annotations"]["autoscaling.knative.dev/maxScale"], "1")
            self.assertEqual(output[name]["metadata"]["annotations"]["run.googleapis.com/maxScale"], "1")
            self.assertEqual(output[name]["metadata"]["annotations"]["run.googleapis.com/invoker-iam-disabled"], "false")
            container = template["spec"]["containers"][0]
            self.assertEqual(container["resources"]["limits"], {"cpu": "1", "memory": "512Mi"})
            for kind in ("startupProbe", "livenessProbe"):
                self.assertEqual(container[kind]["httpGet"]["path"], "/health")

    def test_jobs_have_finite_attempts_separate_backup_role_and_hourly_purge(self):
        output = render.render(configuration())
        for name in render.JOBS:
            job = output[name]["spec"]["template"]["spec"]
            self.assertEqual((job["parallelism"], job["taskCount"]), (1, 1))
            self.assertEqual(job["template"]["spec"]["maxRetries"], 0)
        monthly = output["monthly"]["spec"]["template"]["spec"]["template"]["spec"]
        self.assertEqual(monthly["timeoutSeconds"], "28830")
        self.assertEqual(monthly["containers"][0]["resources"]["limits"], {"cpu": "2", "memory": "8Gi"})
        backup = output["backup"]["spec"]["template"]["spec"]["template"]["spec"]
        self.assertEqual(backup["serviceAccountName"], render.account("backup"))
        self.assertEqual(backup["timeoutSeconds"], "3600")
        self.assertEqual(backup["containers"][0]["args"], ["dist/src/jobs/database-backup.js"])
        secrets = [v["valueFrom"]["secretKeyRef"]["name"] for v in backup["containers"][0]["env"] if "valueFrom" in v]
        self.assertEqual(secrets, ["nextstop-staging-backup-database-url"])
        self.assertEqual(output["scheduler-report-purge"]["schedule"], "0 * * * *")
        self.assertEqual(output["scheduler-cleanup"]["schedule"], "0 * * * *")
        self.assertEqual(set(render.SCHEDULES), {"monthly", "cleanup", "report-purge", "backup"})
        self.assertNotIn("state", output["scheduler-report-purge"])  # output-only API field
        self.assertEqual(output["scheduler-backup"]["schedule"], "0 3 * * *")

    def test_job_connector_metadata_uses_execution_template_not_task_template(self):
        # Official Cloud Run v1 Job schema: TaskTemplateSpec has no metadata.
        # Services have a different schema and retain their generation setting.
        output = render.render(configuration())
        for name in render.JOBS:
            execution = output[name]["spec"]["template"]
            self.assertEqual(execution["metadata"]["annotations"],
                             {"run.googleapis.com/cloudsql-instances": render.CONNECTION})
            self.assertEqual(set(execution["spec"]["template"]), {"spec"})
        self.assertEqual(output["api"]["spec"]["template"]["metadata"]["annotations"]
                         ["run.googleapis.com/execution-environment"], "gen2")

    @unittest.skipUnless(os.environ.get("NEXTSTOP_TEST_GCLOUD_SDK"), "Set NEXTSTOP_TEST_GCLOUD_SDK for actual offline CLI schema validation")
    def test_job_manifests_parse_with_actual_gcloud_v1_protobuf_and_reject_prior_metadata_location(self):
        sdk = Path(os.environ["NEXTSTOP_TEST_GCLOUD_SDK"]) / "lib"
        output = render.render(configuration())
        script = """
import json,sys
from googlecloudsdk.api_lib.util.messages import DictToMessageWithErrorCheck, DecodeError
from googlecloudsdk.generated_clients.apis.run.v1.run_v1_messages import Job
values=json.load(sys.stdin)
for manifest in values:
    DictToMessageWithErrorCheck(manifest,Job)
old=values[0]
old['spec']['template']['spec']['template']['metadata']=old['spec']['template'].pop('metadata')
try:
    DictToMessageWithErrorCheck(old,Job)
except DecodeError:
    pass
else:
    raise AssertionError('Prior invalid TaskTemplateSpec metadata was not rejected')
"""
        environment = {**os.environ, "PYTHONPATH": str(sdk) + os.pathsep + str(sdk / "third_party")}
        result = subprocess.run([sys.executable, "-c", script],
                                input=json.dumps([output[name] for name in render.JOBS]), env=environment,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_queue_does_not_retry_inside_ten_minute_lease(self):
        queue = render.render(configuration())["queue"]
        self.assertEqual(queue["rateLimits"]["maxConcurrentDispatches"], 1)
        self.assertEqual(queue["retryConfig"]["maxAttempts"], 3)
        self.assertEqual(queue["retryConfig"]["minBackoff"], "660s")
        self.assertEqual(queue["retryConfig"]["maxRetryDuration"], "0s")
        self.assertEqual(queue["stackdriverLoggingConfig"]["samplingRatio"], 0)


if __name__ == "__main__":
    unittest.main()
