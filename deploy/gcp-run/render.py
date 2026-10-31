#!/usr/bin/env python3
"""Render an isolated nextStop Cloud Run release; no cloud calls or secret values."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from typing import NamedTuple

REGION = "europe-west1"


class Target(NamedTuple):
    environment: str
    project: str
    number: str
    domain: str

    @property
    def connection(self):
        return f"{self.project}:{REGION}:nextstop-{self.environment}"

    @property
    def deploy_account(self):
        return f"nextstop-{self.environment}-deploy@{self.project}.iam.gserviceaccount.com"


STAGING = Target("staging", "nextstop-tech-testing", "353471052580", "api-staging.nextstop.tech")
PRODUCTION = Target("production", "nextstop-tech-staging", "1022346259037", "api.nextstop.tech")
TARGETS = {target.environment: target for target in (STAGING, PRODUCTION)}
PROJECT, PROJECT_NUMBER, CONNECTION = STAGING.project, STAGING.number, STAGING.connection
REGISTRY = "europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend"
SERVICES = ("gateway", "api", "auth", "live", "broker")
SECRETS = (
    "api-database-url", "auth-database-url", "support-database-url",
    "worker-database-url", "migrator-database-url", "snapshot-signing-key",
    "access-token-signing-key", "backup-database-url",
)
QUEUE = "nextstop-live"
LOG_EXCLUSION = {
    "name": "nextstop-staging-cloud-run-requests",
    "description": "Do not retain raw request URLs or client IPs; application diagnostics are sanitized.",
    "filter": 'resource.type="cloud_run_revision" AND log_id("run.googleapis.com/requests") '
              'AND resource.labels.service_name=~"^nextstop-(gateway|api|auth|live|broker)$"',
    "disabled": False,
}
JOB_MODES = {"monthly": "monthly-import", "cleanup": "cleanup", "report-purge": "report-purge"}
JOBS = (*JOB_MODES, "backup", "migrate")
JOB_SECONDS = {"monthly": 28_800, "cleanup": 300, "report-purge": 120, "backup": 3600, "migrate": 900}
SCHEDULES = {"monthly": "0 2 * * *", "cleanup": "0 * * * *", "report-purge": "0 * * * *", "backup": "0 3 * * *"}


class ConfigurationError(ValueError):
    pass


def account(role, target=STAGING):
    return f"nextstop-run-{role}@{target.project}.iam.gserviceaccount.com"


def origin(service, tag=None, target=STAGING):
    prefix = "" if tag is None else tag + "---"
    return f"https://{prefix}nextstop-{service}-{target.number}.{REGION}.run.app"


def log_exclusion(target):
    return {**LOG_EXCLUSION, "name": f"nextstop-{target.environment}-cloud-run-requests"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def validate(config, expected_environment="staging", *, offline=False):
    required = {"environment", "project", "region", "backendImage", "commit", "cloudSqlConnectionName",
                "cacheBucket", "backupBucket", "appAttestAppId", "secretVersions", "retainedTraffic", "acceptanceEvidence"}
    if isinstance(config, dict) and config.get("environment") == "production":
        required.add("cloudSqlDiskGb")
    if not isinstance(config, dict) or set(config) != required:
        raise ConfigurationError("Configuration keys do not match the Cloud Run schema.")
    target = TARGETS.get(config["environment"]) if isinstance(config["environment"], str) else None
    if target is None or target.environment != expected_environment or (config["project"], config["region"], config["cloudSqlConnectionName"]) != (
        target.project, REGION, target.connection,
    ):
        raise ConfigurationError("Cloud Run environment, project, region and database must match the approved target.")
    if not isinstance(config["backendImage"], str) or not re.fullmatch(re.escape(REGISTRY) + r"@sha256:[0-9a-f]{64}", config["backendImage"]):
        raise ConfigurationError("A backend digest from the existing approved registry is required.")
    if not isinstance(config["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", config["commit"]):
        raise ConfigurationError("A complete source commit is required; verify its OCI revision before applying.")
    for bucket in ("cacheBucket", "backupBucket"):
        if not isinstance(config[bucket], str) or not re.fullmatch(re.escape(target.project) + r"-[a-z0-9][a-z0-9-]{1,38}", config[bucket]):
            raise ConfigurationError("Storage buckets must belong to the selected environment.")
    if target == PRODUCTION and (type(config["cloudSqlDiskGb"]) is not int or not 60 <= config["cloudSqlDiskGb"] <= 1024):
        raise ConfigurationError("Production requires a reviewed disk size covering the measured source.")
    if target == PRODUCTION and (config["cacheBucket"], config["backupBucket"], config["appAttestAppId"]) != (
        target.project + "-download-cache", target.project + "-database-backups", "MR3P73S995.de.nextstop.app",
    ):
        raise ConfigurationError("Production requires its dedicated buckets and signed application identifier.")
    if config["cacheBucket"] == config["backupBucket"]:
        raise ConfigurationError("Public download cache and private filtered backups require separate buckets.")
    evidence = config["acceptanceEvidence"]
    if not (offline and target == PRODUCTION and evidence is None) and (not isinstance(evidence, dict) or set(evidence) != {"object", "generation", "sha256"}
            or not isinstance(evidence["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", evidence["sha256"])
            or evidence["object"] != "operations/evidence/" + evidence["sha256"] + ".json"
            or not isinstance(evidence["generation"], str) or not re.fullmatch(r"[1-9][0-9]{0,24}", evidence["generation"])):
        raise ConfigurationError("Private acceptance evidence must be pinned by generation and SHA-256.")
    if not isinstance(config["appAttestAppId"], str) or not re.fullmatch(r"[A-Z0-9]{10}\.[A-Za-z0-9.-]{3,200}", config["appAttestAppId"]):
        raise ConfigurationError("The exact App Attest application identifier is required.")
    if not isinstance(config["secretVersions"], dict) or set(config["secretVersions"]) != set(SECRETS):
        raise ConfigurationError("Every expected staging secret must have a pinned version.")
    if any(not isinstance(v, str) or not re.fullmatch(r"[1-9][0-9]{0,8}", v)
           for v in config["secretVersions"].values()):
        raise ConfigurationError("Secret versions must be numeric, never latest or secret values.")
    retained = config["retainedTraffic"]
    if not isinstance(retained, dict) or any(name not in SERVICES for name in retained):
        raise ConfigurationError("Only this release's service traffic can be retained.")
    for service, traffic in retained.items():
        if not isinstance(traffic, list) or not traffic or len(traffic) > 12:
            raise ConfigurationError("Retained traffic must be a bounded nonempty snapshot.")
        tags = set()
        for entry in traffic:
            if not isinstance(entry, dict) or not {"revisionName", "percent"} <= set(entry) or set(entry) - {"revisionName", "percent", "tag"}:
                raise ConfigurationError("Retained traffic must pin explicit revisions, never latestRevision.")
            if not isinstance(entry["revisionName"], str) or not re.fullmatch(r"nextstop-" + re.escape(service) + r"-[a-z0-9-]{1,40}", entry["revisionName"]):
                raise ConfigurationError("Retained revision belongs to a different service.")
            if type(entry["percent"]) is not int or not 0 <= entry["percent"] <= 100:
                raise ConfigurationError("Invalid traffic allocation.")
            tag = entry.get("tag")
            if tag is not None:
                # The security-backport drill keeps private zero-traffic API/Auth
                # tags bound to an immutable revision under its exact own name.
                security_tag = (config["environment"] == "staging" and service in {"api", "auth"}
                                and entry["percent"] == 0 and isinstance(tag, str)
                                and re.fullmatch(r"sec-[0-9a-f]{12}-[0-9a-f]{12}", tag)
                                and entry["revisionName"] == "nextstop-" + service + "-" + tag)
                if not isinstance(tag, str) or tag in tags or not (security_tag or re.fullmatch(r"r-[0-9a-f]{12}", tag)):
                    raise ConfigurationError("Only unique immutable release tags may be retained.")
                tags.add(tag)
        if sum(row["percent"] for row in traffic) != 100:
            raise ConfigurationError("Retained traffic must total 100 percent.")
    return config


def release_id(config):
    # Routing history changes neither images, secret versions nor immutable URLs.
    return hashlib.sha256(canonical({k: v for k, v in config.items() if k not in {"retainedTraffic", "acceptanceEvidence"}}).encode()).hexdigest()[:12]


def secret(config, variable, name):
    return {"name": variable, "valueFrom": {"secretKeyRef": {
        "name": "nextstop-" + config["environment"] + "-" + name, "key": config["secretVersions"][name],
    }}}


def environment(values):
    return [{"name": key, "value": str(value)} for key, value in values.items()]


def runtime_environment(config, database=True):
    values = {"NEXTSTOP_RUNTIME": "cloud-run", "NEXTSTOP_ENVIRONMENT": config["environment"],
              "RELEASE_IMAGE_DIGEST": config["backendImage"].split("@", 1)[1]}
    if database:
        values.update(DATABASE_TRANSPORT="cloud-sql-socket", CLOUD_SQL_CONNECTION_NAME=config["cloudSqlConnectionName"])
    return environment(values)


def live_environment(target):
    return environment({
        "LIVE_REFRESH_TRANSPORT": "cloud-tasks",
        "LIVE_REFRESH_TASK_QUEUE": f"projects/{target.project}/locations/{REGION}/queues/{QUEUE}",
        "LIVE_REFRESH_TASK_TARGET": origin("live", target=target) + "/refresh",
        "LIVE_REFRESH_TASK_SERVICE_ACCOUNT": account("tasks", target),
    })


def service(config, name, extra_env, command, role=None):
    target = TARGETS[config["environment"]]
    tag = "r-" + release_id(config)
    revision = "nextstop-" + name + "-" + release_id(config)
    database = name not in {"gateway", "broker"}
    annotations = {"run.googleapis.com/execution-environment": "gen2",
                   "autoscaling.knative.dev/minScale": "0", "autoscaling.knative.dev/maxScale": "1",
                   "run.googleapis.com/cpu-throttling": "true", "run.googleapis.com/startup-cpu-boost": "false"}
    if database:
        # v1 Cloud Run mounts this connection at /cloudsql/<connection name>.
        annotations["run.googleapis.com/cloudsql-instances"] = target.connection
    traffic = [dict(row) for row in config["retainedTraffic"].get(name, [])]
    existing = next((row for row in traffic if row.get("tag") == tag), None)
    if existing is not None and existing["revisionName"] != revision:
        raise ConfigurationError("A release tag cannot be repointed to another revision.")
    if existing is None:
        traffic.append({"revisionName": revision, "tag": tag, "percent": 0 if traffic else 100})
    return {
        "apiVersion": "serving.knative.dev/v1", "kind": "Service",
        "metadata": {"name": "nextstop-" + name, "namespace": target.number,
                     "labels": {"nextstop-environment": target.environment, "nextstop-release": release_id(config)},
                     "annotations": {"run.googleapis.com/ingress": "all", "run.googleapis.com/minScale": "0",
                                     "run.googleapis.com/maxScale": "1",
                                     "run.googleapis.com/invoker-iam-disabled": "false"}},
        "spec": {"template": {
            "metadata": {"name": revision, "annotations": annotations},
            "spec": {"serviceAccountName": account(role or name, target),
                     "containerConcurrency": 1 if name == "live" else 8,
                     "timeoutSeconds": 300 if name == "live" else 60 if name == "gateway" else 30,
                     "containers": [{"name": name, "image": config["backendImage"],
                                     "command": ["node"], "args": [f"dist/src/{command}.js"],
                                     "ports": [{"name": "http1", "containerPort": 8080}],
                                     "env": runtime_environment(config, database) + environment({"HOST": "0.0.0.0"}) + extra_env,
                                     "resources": {"limits": {"cpu": "1", "memory": "512Mi"}},
                                     "startupProbe": {"httpGet": {"path": "/health", "port": 8080},
                                                      "periodSeconds": 2, "timeoutSeconds": 1, "failureThreshold": 30},
                                     "livenessProbe": {"httpGet": {"path": "/health", "port": 8080},
                                                       "periodSeconds": 30, "timeoutSeconds": 1, "failureThreshold": 3}}]}},
                 "traffic": traffic},
    }


def job(config, name):
    target = TARGETS[config["environment"]]
    env = runtime_environment(config)
    if name == "backup":
        role = "backup"
        env.append(secret(config, "BACKUP_DATABASE_URL", "backup-database-url"))
        env += environment({"BACKUP_BUCKET": config["backupBucket"]})
    elif name == "report-purge":
        role = "support"
        env.append(secret(config, "SUPPORT_DATABASE_URL", "support-database-url"))
    else:
        role = "migrator" if name == "migrate" else "worker"
        env.append(secret(config, "DATABASE_URL", "migrator-database-url" if name == "migrate" else "worker-database-url"))
    if name == "monthly":
        env += environment({"DOWNLOAD_CACHE_BACKEND": "gcs", "DOWNLOAD_CACHE_BUCKET": config["cacheBucket"],
                            "INGESTION_SCHEDULE": "monthly", "OSM_INGESTION_ENABLED": "true",
                            "DEMAND_LIVE_AVAILABILITY_ENABLED": "true", "NODE_OPTIONS": "--max-old-space-size=4608",
                            "OSM_GEOFABRIK_PBF_URLS": "https://download.geofabrik.de/europe/germany-latest.osm.pbf,https://download.geofabrik.de/europe/switzerland-latest.osm.pbf"})
    if name == "backup":
        args = ["dist/src/jobs/database-backup.js"]
    elif name == "migrate":
        args = ["dist/src/jobs/cloud-migrate.js"]
    else:
        args = ["dist/src/jobs/maintenance-job.js"]
        env += environment({"MAINTENANCE_JOB_MODE": JOB_MODES[name], "MAINTENANCE_JOB_MAX_SECONDS": JOB_SECONDS[name]})
    return {"apiVersion": "run.googleapis.com/v1", "kind": "Job",
            "metadata": {"name": "nextstop-" + name, "namespace": target.number,
                         "labels": {"nextstop-environment": target.environment, "nextstop-release": release_id(config)}},
            # Cloud Run v1 ExecutionTemplateSpec accepts metadata; its nested
            # TaskTemplateSpec accepts only spec. Jobs always use generation2.
            "spec": {"template": {
                "metadata": {"annotations": {"run.googleapis.com/cloudsql-instances": target.connection}},
                "spec": {"taskCount": 1, "parallelism": 1, "template": {
                "spec": {"serviceAccountName": account(role, target), "maxRetries": 0,
                         "timeoutSeconds": str(JOB_SECONDS[name] + (30 if name in JOB_MODES else 0)),
                         "containers": [{"image": config["backendImage"], "command": ["node"], "args": args,
                                         "env": env, "resources": {"limits": {
                                             "cpu": "2" if name == "monthly" else "1",
                                             "memory": "8Gi" if name == "monthly" else "512Mi"}}}]}}}}}}


def scheduler(name, target=STAGING):
    return {"name": f"projects/{target.project}/locations/{REGION}/jobs/nextstop-{name}",
            "schedule": SCHEDULES[name], "timeZone": "Etc/UTC",
            "attemptDeadline": "180s", "retryConfig": {"retryCount": 0, "maxRetryDuration": "0s"},
            "httpTarget": {"uri": f"https://run.googleapis.com/v2/projects/{target.project}/locations/{REGION}/jobs/nextstop-{name}:run",
                           "httpMethod": "POST", "headers": {"Content-Type": "application/json"}, "body": "e30=",
                           "oauthToken": {"serviceAccountEmail": account("scheduler", target),
                                          "scope": "https://www.googleapis.com/auth/cloud-platform"}}}


def render(config):
    validate(config, config.get("environment"), offline=True)
    target = TARGETS[config["environment"]]
    tag = "r-" + release_id(config)
    result = {
        "gateway": service(config, "gateway", environment({"BACKEND_API_ORIGIN": origin("api", tag, target),
                                                           "BACKEND_AUTH_ORIGIN": origin("auth", tag, target),
                                                           "BACKEND_API_AUDIENCE": origin("api", target=target),
                                                           "BACKEND_AUTH_AUDIENCE": origin("auth", target=target)}), "gateway-server"),
        "api": service(config, "api", [secret(config, "DATABASE_URL", "api-database-url"),
                                       secret(config, "SUPPORT_DATABASE_URL", "support-database-url"),
                                       secret(config, "SNAPSHOT_SIGNING_KEY", "snapshot-signing-key"),
                                       secret(config, "SEARCH_ACCESS_TOKEN_SIGNING_KEY", "access-token-signing-key")]
                       + environment({"ALLOW_LEGACY_STAGING_BEARER": "false", "DEMAND_LIVE_AVAILABILITY_ENABLED": "true"})
                       + live_environment(target), "server"),
        "auth": service(config, "auth", [secret(config, "AUTH_DATABASE_URL", "auth-database-url"),
                                         secret(config, "SEARCH_ACCESS_TOKEN_SIGNING_KEY", "access-token-signing-key")]
                        + environment({"APP_ATTEST_APP_ID": config["appAttestAppId"], "APP_ATTEST_ALLOW_DEVELOPMENT": "true" if target == STAGING else "false"}), "auth-server"),
        "live": service(config, "live", [secret(config, "DATABASE_URL", "worker-database-url")] + live_environment(target), "live-refresh-server"),
        "broker": service(config, "broker", [secret(config, "SEARCH_ACCESS_TOKEN_SIGNING_KEY", "access-token-signing-key")], "simulator-token-server"),
    }
    result.update({name: job(config, name) for name in JOBS})
    result["queue"] = {"name": f"projects/{target.project}/locations/{REGION}/queues/{QUEUE}",
                       "rateLimits": {"maxDispatchesPerSecond": 0.1, "maxConcurrentDispatches": 1},
                       "retryConfig": {"maxAttempts": 3, "maxRetryDuration": "0s", "minBackoff": "660s",
                                       "maxBackoff": "660s", "maxDoublings": 0},
                       "stackdriverLoggingConfig": {"samplingRatio": 0}}
    # Scheduler state is output-only. These request bodies are NOT automatically
    # submitted: creating a scheduler immediately enables it, so activation is a
    # separate operator step after all release/backup/budget gates pass.
    result.update({"scheduler-" + name: scheduler(name, target) for name in SCHEDULES})
    result["logging-exclusion"] = log_exclusion(target)
    return result


def write_rendered(config, directory):
    directory.mkdir(parents=True, exist_ok=True)
    manifests = render(config)
    for name, manifest in manifests.items():
        path = directory / (name + ".json")
        if path.is_symlink():
            raise ConfigurationError("Refusing to overwrite a manifest symlink.")
        path.write_text(json.dumps(manifest, indent=2) + "\n")
    return manifests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        manifests = write_rendered(config, args.output)
        print(json.dumps({"project": config["project"], "release": release_id(config), "manifestCount": len(manifests)}))
    except (ConfigurationError, ValueError, OSError, TypeError, KeyError):
        raise SystemExit("Invalid staging release configuration or output path; no cloud changes made.") from None


if __name__ == "__main__":
    main()
