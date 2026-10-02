#!/usr/bin/env python3
"""Validate a VM PostgreSQL archive and retain a private GCS release backup.

Report contents and withdrawal tombstones are excluded under the error-report
operations runbook's backup boundary. Authentication state is preserved. Archive listing validates structure;
it does not replace an isolated restore rehearsal.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from common import ROOT, configuration, run_json, validate_image


CONTAINER = "gcp-vm-database-1"


def archive_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_command(arguments: list[str], timeout: int = 180) -> None:
    # Large archives must not create temporary composite-upload components:
    # the backup identity intentionally has no object-deletion permission.
    environment = {**os.environ, "CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED": "false"}
    try:
        result = subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False, env=environment)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Backup command exceeded its time budget.") from None
    if result.returncode:
        raise RuntimeError("Backup command failed; private command output was suppressed.")


def ssh(config: dict, script: str) -> list[str]:
    return ["gcloud", "compute", "ssh", config["target"]["instance"],
            f"--project={config['project']}", f"--zone={config['target']['zone']}",
            "--tunnel-through-iap", "--quiet", "--command=" + script]


def dump_script(directory: str) -> str:
    # Paths contain only a generated hexadecimal operation ID. The shell opens
    # the file as the SSH user; sudo is used only to access the database container.
    script = f'''set -eu
umask 077
directory={shlex.quote(directory)}
archive="$directory/archive.dump"
sudo mkdir -m 700 -- "$directory"
trap 'sudo rm -f -- "$archive"; sudo rmdir -- "$directory"' EXIT
sudo chown "$(id -u):$(id -g)" "$directory"
database_bytes=$(sudo docker exec {CONTAINER} psql -XAt -U nextstop_app -d nextstop -c 'SELECT pg_database_size(current_database())')
available_bytes=$(df --output=avail -B1 /srv/nextstop | tail -1)
[ "$available_bytes" -gt "$((database_bytes + 10737418240))" ]
sudo docker exec {CONTAINER} pg_restore --version | grep -Eq 'PostgreSQL\\) 17\\.'
sudo docker exec {CONTAINER} pg_dump -U nextstop_app -d nextstop -Fc --no-owner --no-privileges --lock-wait-timeout=500ms --exclude-table-data=nextstop.user_error_reports > "$archive"
sudo docker exec -i {CONTAINER} pg_restore --list < "$archive" > /dev/null
python3 - "$archive" <<'METADATA'
import hashlib, json, os, sys
digest = hashlib.sha256()
with open(sys.argv[1], 'rb') as archive:
    for chunk in iter(lambda: archive.read(8 * 1024 * 1024), b''):
        digest.update(chunk)
print(json.dumps({{'size': os.stat(sys.argv[1]).st_size, 'sha256': digest.hexdigest()}}))
METADATA
trap - EXIT
'''
    # A remote timeout also stops the dump if the caller loses its SSH connection.
    # PostgreSQL errors can contain private values; none are returned to CI logs.
    return "timeout --kill-after=10s 1800s bash -c " + shlex.quote(script) + " 2>/dev/null"


def create_backup(config: dict, image: str, *, run=run_json, command=run_command, now=time.time) -> dict:
    validate_image(image, config)
    if (config["name"] != "production" or config["database"]["mode"] != "local"
            or config["database"]["instance"] != config["target"]["instance"]):
        raise ValueError("The configured production VM database is required.")
    bucket = config.get("backupBucket", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]", bucket):
        raise ValueError("A private production backup bucket is required.")
    project = config["project"]
    instance = config["target"]["instance"]
    bucket_metadata = run(["gcloud", "storage", "buckets", "describe", f"gs://{bucket}",
                           "--raw", f"--project={project}", "--format=json", "--quiet"])
    access = bucket_metadata.get("iamConfiguration", {}) if isinstance(bucket_metadata, dict) else {}
    if (not isinstance(bucket_metadata, dict) or bucket_metadata.get("name") != bucket
            or access.get("publicAccessPrevention") != "enforced"
            or access.get("uniformBucketLevelAccess", {}).get("enabled") is not True):
        raise RuntimeError("The release backup bucket must enforce private uniform access.")
    # A fresh gcloud SSH identity can print ssh-keygen output on stdout, even
    # with --quiet. Complete that setup with suppressed output before the dump
    # command whose stdout must remain strictly valid JSON.
    command(ssh(config, "true"), timeout=90)
    operation = uuid.uuid4().hex
    directory = f"/srv/nextstop/.release-backup-{operation}"
    started = now()
    object_name = f"production/{instance}/{int(started)}-{operation}.dump"
    destination = f"gs://{bucket}/{object_name}"
    cleanup = f"sudo rm -f -- {directory}/archive.dump && sudo rmdir -- {directory}"
    try:
        archive = run(ssh(config, dump_script(directory)), timeout=1860)
        if (not isinstance(archive, dict) or type(archive.get("size")) is not int
                or archive["size"] < 5 or not re.fullmatch(r"[0-9a-f]{64}", str(archive.get("sha256", "")))):
            raise RuntimeError("The source did not confirm a valid PostgreSQL archive.")
        # Force system temporary storage even when TMPDIR points into a checkout.
        with tempfile.TemporaryDirectory(prefix="nextstop-release-backup-", dir="/tmp") as temporary:
            local = Path(temporary) / "archive.dump"
            if Path(temporary).resolve().is_relative_to(ROOT):
                raise RuntimeError("Database archives must remain outside the checkout.")
            if shutil.disk_usage(temporary).free < archive["size"] + 512 * 1024 * 1024:
                raise RuntimeError("Insufficient local temporary space for the release backup.")
            descriptor = os.open(local, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
            command(["gcloud", "compute", "scp", f"{instance}:{directory}/archive.dump", str(local),
                     f"--project={project}", f"--zone={config['target']['zone']}",
                     "--tunnel-through-iap", "--quiet"], timeout=1800)
            os.chmod(local, 0o600)
            digest = archive_sha256(local)
            if local.stat().st_size != archive["size"] or digest != archive["sha256"]:
                raise RuntimeError("The downloaded archive does not match the validated source.")
            # gcloud verifies upload checksums. A generation precondition prevents
            # overwriting an existing object, including when retrying commands.
            command(["gcloud", "storage", "cp", str(local), destination,
                     "--if-generation-match=0", f"--project={project}", "--quiet"], timeout=1800)
            stored = run(["gcloud", "storage", "objects", "describe", destination,
                          "--raw", f"--project={project}", "--format=json", "--quiet"])
            if not isinstance(stored, dict):
                raise RuntimeError("Cloud Storage did not confirm the release backup.")
            try:
                crc = base64.b64decode(stored.get("crc32c", ""), validate=True)
                completed = datetime.datetime.fromisoformat(stored["timeCreated"].replace("Z", "+00:00")).timestamp()
                size = int(stored["size"])
            except (KeyError, ValueError, TypeError):
                raise RuntimeError("Cloud Storage backup metadata is incomplete.") from None
            generation = str(stored.get("generation", ""))
            if (stored.get("bucket") != bucket or stored.get("name") != object_name
                    or size != archive["size"] or len(crc) != 4 or not re.fullmatch(r"[1-9][0-9]*", generation)
                    or not started - 60 <= completed <= now() + 60):
                raise RuntimeError("Cloud Storage backup identity, integrity or completion time is invalid.")
        return {"environment": "production", "image": image, "project": project,
                "instance": instance, "backupId": destination + "#" + generation,
                "status": "SUCCESSFUL", "completedAt": int(completed)}
    finally:
        # Missing files after a failed dump are harmless; a failed SSH cleanup is
        # fail-closed rather than silently retaining another private archive.
        command(ssh(config, cleanup + " 2>/dev/null || test ! -e " + directory), timeout=60)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    receipt = create_backup(configuration("production"), args.image)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=args.output.parent, prefix=".backup-")
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(receipt, output)
            output.write("\n")
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps({"event": "production-backup-confirmed", "backupId": receipt["backupId"]}))


if __name__ == "__main__":
    main()
