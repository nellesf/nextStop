"""Run the currently serving production image's filtered backup and attest its completion.

Only the restricted backup job reads GCS backup data. CI sees its immutable
execution metadata and sanitized completion reference, never an archive or DSN.
"""
from datetime import datetime, timezone
import json
import re
import time

import release
import render

TARGET = render.PRODUCTION
BACKUP_BUCKET = TARGET.project + "-database-backups"
EXECUTION = re.compile(r"nextstop-backup-[a-z0-9]{5,20}\Z")
RECEIPT = re.compile(r"production/(\d{4}-\d{2}-\d{2})/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.json\Z")
IMAGE = re.compile(re.escape(render.REGISTRY) + r"@sha256:[0-9a-f]{64}\Z")


def gcloud(*args):
    return release.gcloud(*args, target=TARGET)


def active_image():
    rows = release.service_snapshot(release.current_services(TARGET))
    if set(rows) != set(render.SERVICES):
        raise release.ReleaseError("Production Cloud Run must be commissioned before backup.")
    images = set()
    for name in render.SERVICES:
        serving = {row["revisionName"] for row in rows[name] if row["percent"] > 0}
        if len(serving) != 1 or sum(row["percent"] for row in rows[name]) != 100:
            raise release.ReleaseError("Production backup requires one stable serving release.")
        revision = serving.pop()
        if not re.fullmatch("nextstop-" + name + r"-[a-z0-9-]{1,40}", revision):
            raise release.ReleaseError("Unexpected serving revision.")
        value = release.json_command(gcloud("run", "revisions", "describe", revision,
                                     "--region=" + render.REGION, "--format=json(status.imageDigest)"))
        images.add(value["status"]["imageDigest"])
    if len(images) != 1 or not IMAGE.fullmatch(next(iter(images))):
        raise release.ReleaseError("Production does not serve one immutable backend image.")
    return images.pop()


def verify_task(meta, spec, image):
    if (meta.get("annotations", {}).get("run.googleapis.com/cloudsql-instances") != TARGET.connection
            or spec.get("taskCount") != 1 or spec.get("parallelism", 1) != 1):
        raise release.ReleaseError("Backup requires one task and the exact production database.")
    task = spec["template"]["spec"]
    containers = task["containers"]
    if (task.get("serviceAccountName") != render.account("backup", TARGET) or len(containers) != 1
            or task.get("maxRetries", 0) != 0 or task.get("volumes")):
        raise release.ReleaseError("Backup task identity or isolation differs from the approved job.")
    container = containers[0]
    env = {row["name"]: row for row in container["env"]}
    pin = env.get("BACKUP_DATABASE_URL", {}).get("valueFrom", {}).get("secretKeyRef", {})
    expected = render.runtime_environment({"environment": "production", "backendImage": image,
                    "cloudSqlConnectionName": TARGET.connection}) + render.environment({"BACKUP_BUCKET": BACKUP_BUCKET})
    if (container.get("image") != image or container.get("command") != ["node"]
            or container.get("args") != ["dist/src/jobs/database-backup.js"] or container.get("volumeMounts")
            or len(env) != len(container["env"]) or len(env) != len(expected) + 1
            or any(env.get(row["name"]) != row for row in expected)
            or pin.get("name") != "nextstop-production-backup-database-url"
            or not re.fullmatch(r"[1-9]\d{0,8}", str(pin.get("key", "")))):
        raise release.ReleaseError("Backup image, command or role secret differs from the verified production target.")


def completion(event, execution, started, finished):
    obj = event.get("receiptObject")
    match = RECEIPT.fullmatch(obj) if isinstance(obj, str) else None
    if (not match or not started.date().isoformat() <= match[1] <= finished.date().isoformat()
            or event.get("event") != "production_backup_completed" or event.get("execution") != execution
            or event.get("reportsExcluded") is not True or event.get("integrityVerified") is not True
            or type(event.get("bytes")) is not int or not 5 <= event["bytes"] <= 50 * 1024**3
            or not isinstance(event.get("receiptGeneration"), str)
            or not re.fullmatch(r"[1-9]\d{0,24}", event["receiptGeneration"])):
        raise release.ReleaseError("Backup completion is missing an immutable, integrity-verified receipt.")
    return {"execution": execution, "bucket": BACKUP_BUCKET, "receiptObject": obj,
            "receiptGeneration": event["receiptGeneration"], "bytes": event["bytes"]}


def backup():
    image = active_image()
    job = release.json_command(gcloud("run", "jobs", "describe", "nextstop-backup", "--region=" + render.REGION,
                               "--format=json(metadata,spec)"))
    if job["metadata"].get("namespace") != TARGET.number or not job["metadata"].get("uid"):
        raise release.ReleaseError("Unexpected production backup job.")
    template = job["spec"]["template"]
    verify_task(template["metadata"], template["spec"], image)
    started = datetime.now(timezone.utc)
    result = json.loads(release.run(gcloud("run", "jobs", "execute", "nextstop-backup", "--region=" + render.REGION,
                             "--wait", "--format=json(metadata,spec,status)"), timeout=3800))
    finished = datetime.now(timezone.utc)
    meta, status = result["metadata"], result["status"]
    labels = meta.get("labels", {})
    execution = meta["name"]
    if (not EXECUTION.fullmatch(execution) or meta.get("namespace") != TARGET.number
            or labels.get("run.googleapis.com/job") != "nextstop-backup"
            or labels.get("run.googleapis.com/jobUid") != job["metadata"]["uid"]
            or str(labels.get("run.googleapis.com/jobGeneration")) != str(job["metadata"]["generation"])
            or meta.get("annotations", {}).get("run.googleapis.com/creator") != TARGET.deploy_account
            or status.get("succeededCount") != 1 or not status.get("completionTime")
            or not any(c.get("type") == "Completed" and c.get("status") == "True" for c in status.get("conditions", []))):
        raise release.ReleaseError("Backup execution did not complete on the expected production job generation.")
    verify_task(meta, result["spec"], image)
    query = (f'resource.type="cloud_run_job" AND resource.labels.job_name="nextstop-backup" AND '
             f'resource.labels.location="{render.REGION}" AND labels."run.googleapis.com/execution_name"="{execution}" AND '
             f'logName="projects/{TARGET.project}/logs/run.googleapis.com%2Fstdout" AND '
             'jsonPayload.event="production_backup_completed"')
    for attempt in range(7):
        rows = release.json_command(gcloud("logging", "read", query, "--limit=2", "--freshness=2h", "--format=json(jsonPayload)"))
        if len(rows) == 1:
            return completion(rows[0]["jsonPayload"], execution, started, finished)
        if len(rows) > 1 or attempt == 6:
            break
        time.sleep(5)
    raise release.ReleaseError("Expected one completion event from this production backup execution.")
