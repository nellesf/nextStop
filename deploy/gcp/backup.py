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


CLIENT_METADATA = ROOT / "deploy/security/postgres-client/image.json"


def client_configuration() -> dict:
    """Only a reviewed, published client artifact may be used for a backup."""
    client = json.loads(CLIENT_METADATA.read_text())
    if (not isinstance(client, dict)
            or not re.fullmatch(r"europe-west3-docker\.pkg\.dev/nextstop-tech-staging/nextstop/postgres-client@sha256:[0-9a-f]{64}", str(client.get("image", "")))
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(client.get("configDigest", "")))
            or not re.fullmatch(r"[0-9a-f]{40}", str(client.get("sourceCommit", "")))
            or client.get("version") != "17.11" or client.get("platform") != "linux/amd64"):
        raise ValueError("A reviewed immutable PostgreSQL 17.11 client artifact is required.")
    return client


# This helper runs as root on the VM. Only archive metadata leaves the host;
# credentials enter the client through stdin, never Docker's config or logs.
REMOTE_DUMP = r'''
import json, os, pathlib, re, shutil, signal, subprocess, sys

def execute(args, *, input=None, stdin=None, stdout=subprocess.PIPE, timeout=90):
    result = subprocess.run(args, input=input, stdin=stdin, stdout=stdout,
                            stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError('Private backup operation failed.')
    return result.stdout

def database_identity(timeout=90):
    fields = '{"id":{{json .Id}},"image":{{json .Image}},"name":{{json .Name}},"started":{{json .State.StartedAt}},"running":{{json .State.Running}},"health":{{json .State.Health.Status}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}}}'
    value = json.loads(execute(['docker', 'inspect', '--format', fields, 'gcp-vm-database-1'], timeout=timeout))
    if (not re.fullmatch(r'[0-9a-f]{64}', value.get('id', ''))
            or not re.fullmatch(r'sha256:[0-9a-f]{64}', value.get('image', ''))
            or value.get('name') != '/gcp-vm-database-1' or not value.get('started')
            or value.get('running') is not True or value.get('health') != 'healthy'
            or value.get('project') != 'gcp-vm' or value.get('service') != 'database'):
        raise RuntimeError('The exact running production database is required.')
    return value

def verify_client(client):
    rows = json.loads(execute(['docker', 'image', 'inspect', client['image']]))
    if not isinstance(rows, list) or len(rows) != 1:
        raise RuntimeError('The prepared backup client is unavailable.')
    image = rows[0]
    manifest = client['image'].rsplit('@', 1)[1]
    descriptor = image.get('Descriptor')
    descriptor_ok = (isinstance(descriptor, dict) and descriptor.get('digest') == manifest
                     and descriptor.get('mediaType') in ('application/vnd.docker.distribution.manifest.v2+json', 'application/vnd.oci.image.manifest.v1+json'))
    identity_ok = ((image.get('Id') == client['configDigest'] and (descriptor is None or descriptor_ok))
                   or (image.get('Id') == manifest and descriptor_ok))
    config = image.get('Config', {})
    labels = config.get('Labels', {})
    if (not identity_ok or not isinstance(image.get('RepoDigests'), list)
            or client['image'] not in image['RepoDigests']
            or image.get('Os') != 'linux' or image.get('Architecture') != 'amd64'
            or labels.get('org.opencontainers.image.revision') != client['sourceCommit']
            or labels.get('org.opencontainers.image.version') != '17.11'
            or labels.get('org.opencontainers.image.base.digest') != 'sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4'
            or labels.get('tech.nextstop.image-purpose') != 'postgres-client'
            or config.get('User') != '65532:65532' or config.get('Entrypoint')
            or config.get('Volumes') or config.get('ExposedPorts')
            or config.get('Cmd') != ['psql', '--version'] or config.get('WorkingDir') != '/tmp'):
        raise RuntimeError('The backup client identity or isolation configuration differs.')

def password_line(path):
    status = path.stat()
    if status.st_uid != 0 or status.st_mode & 0o077:
        raise RuntimeError('The host credentials must remain root-only.')
    values = []
    for line in path.read_bytes().decode('utf-8').split('\n'):
        line = line.strip(' \t')
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key):
            raise RuntimeError('Invalid host credential file.')
        if separator and key == 'POSTGRES_PASSWORD':
            if any(c in value for c in '\x00\r\n'):
                raise RuntimeError('Invalid database-owner credential.')
            if len(value) >= 2 and value[0] == value[-1] and value[0] in '\"\'':
                value = value[1:-1]
            elif value[:1] in ('\"', "'") or value[-1:] in ('\"', "'"):
                raise RuntimeError('Invalid quoted database-owner credential.')
            values.append(value)
    if len(values) != 1 or not 1 <= len(values[0]) <= 1024 or any(c in values[0] for c in '\x00\r\n'):
        raise RuntimeError('A single valid database-owner credential is required.')
    password = values[0].replace('\\', '\\\\').replace(':', '\\:')
    return ('127.0.0.1:5432:nextstop:nextstop_app:' + password + '\n').encode()

def main(client, archive, uid, gid):
    if not re.fullmatch(r'/srv/nextstop/\.release-backup-[0-9a-f]{32}/archive\.dump', str(archive)):
        raise RuntimeError('Unexpected private archive location.')
    verify_client(client)
    database = database_identity()
    credential = password_line(pathlib.Path('/etc/nextstop/backend.env'))
    name = 'nextstop-backup-client-' + archive.parent.name.rsplit('-', 1)[1]
    base = ['docker', 'run', '--rm', '--pull=never', '--platform=linux/amd64', '--name=' + name,
            '--user=65532:65532', '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
            '--memory=512m', '--memory-swap=512m', '--cpus=1', '--pids-limit=64', '--log-driver=none', '-i']

    def client_run(tool, arguments, *, connected=False, source=None, output=subprocess.PIPE):
        if connected and database_identity() != database:
            raise RuntimeError('The production database changed before the backup operation.')
        args = base + ['--network=' + ('container:' + database['id'] if connected else 'none')]
        if connected:
            args += ['--tmpfs=/run/secrets:rw,noexec,nosuid,nodev,size=64k,mode=0700,uid=65532,gid=65532',
                     '--entrypoint=/bin/sh', client['image'], '-euc',
                     'umask 077; IFS= read -r line; printf "%s\\n" "$line" > /run/secrets/pgpass; '
                     'unset line; export PGPASSFILE=/run/secrets/pgpass PGCONNECT_TIMEOUT=10; exec "$@"',
                     '--', '/usr/local/bin/' + tool] + arguments
        else:
            args += ['--entrypoint=/usr/local/bin/' + tool, client['image']] + arguments
        try:
            return execute(args, input=credential if connected else None, stdin=source,
                           stdout=output, timeout=1500 if tool == 'pg_dump' else 90)
        finally:
            # A killed docker CLI does not reliably remove its container. Target
            # only this operation's name, including on timeout or lost SSH.
            try:
                try:
                    subprocess.run(['docker', 'rm', '--force', name], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=10, check=False)
                    # --rm may already have removed it, so a nonzero rm status
                    # is harmless only after Docker confirms exact absence.
                    if execute(['docker', 'ps', '-a', '-q', '--filter', 'name=^/' + name + '$'], timeout=10).strip():
                        raise RuntimeError('Backup client remains present.')
                except (OSError, RuntimeError, subprocess.TimeoutExpired):
                    raise RuntimeError('The private backup client could not be confirmed removed.') from None
            finally:
                if connected and database_identity(timeout=10) != database:
                    raise RuntimeError('The production database changed during the backup operation.')

    def interrupted(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        raise RuntimeError('The private backup operation was interrupted.')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    for tool in ('psql', 'pg_dump', 'pg_restore'):
        version = client_run(tool, ['--version']).decode().strip()
        if version != tool + ' (PostgreSQL) 17.11':
            raise RuntimeError('The backup tools must be PostgreSQL 17.11.')
    connection = ['--host=127.0.0.1', '--port=5432', '--no-password', '-U', 'nextstop_app', '-d', 'nextstop']
    query = "SELECT json_build_object('database',current_database(),'version',current_setting('server_version_num')::integer,'bytes',pg_database_size(current_database()))"
    info = json.loads(client_run('psql', ['-XAt'] + connection + ['-c', query], connected=True))
    if (info.get('database') != 'nextstop' or type(info.get('version')) is not int
            or not 170000 <= info['version'] < 180000 or type(info.get('bytes')) is not int or info['bytes'] <= 0):
        raise RuntimeError('The exact PostgreSQL 17 production database is required.')
    if shutil.disk_usage('/srv/nextstop').free <= info['bytes'] + 10737418240:
        raise RuntimeError('Insufficient private archive space.')
    descriptor = os.open(archive, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        client_run('pg_dump', connection + ['-Fc', '--no-owner', '--no-privileges', '--lock-wait-timeout=500ms',
                   '--exclude-table-data=nextstop.user_error_reports'], connected=True, output=output)
    with archive.open('rb') as source:
        client_run('pg_restore', ['--list'], source=source, output=subprocess.DEVNULL)
    if database_identity() != database:
        raise RuntimeError('The production database changed during archive validation.')
    os.chown(archive, uid, gid)
'''


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


def dump_script(directory: str, client: dict | None = None) -> str:
    # Only the generated operation directory receives the private host archive;
    # the tool container never receives a host directory or database volume.
    client = client_configuration() if client is None else client
    script = f'''set -eu
umask 077
directory={shlex.quote(directory)}
archive="$directory/archive.dump"
sudo mkdir -m 700 -- "$directory"
trap 'sudo rm -f -- "$archive"; sudo rmdir -- "$directory"' EXIT
sudo chown "$(id -u):$(id -g)" "$directory"
sudo python3 - "$archive" "$(id -u)" "$(id -g)" <<'CLIENT'
{REMOTE_DUMP}
main({client!r}, pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))
CLIENT
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
    return "timeout --kill-after=60s 1800s bash -c " + shlex.quote(script) + " 2>/dev/null"


def create_backup(config: dict, image: str, *, run=run_json, command=run_command, now=time.time) -> dict:
    validate_image(image, config)
    if (config["name"] != "production" or config["database"]["mode"] != "local"
            or config["database"]["instance"] != config["target"]["instance"]):
        raise ValueError("The configured production VM database is required.")
    bucket = config.get("backupBucket", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]", bucket):
        raise ValueError("A private production backup bucket is required.")
    client = client_configuration()
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
        archive = run(ssh(config, dump_script(directory, client)), timeout=1920)
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


def current_production_image(config: dict, *, run=run_json) -> str:
    # Validate before printing: only these non-secret release identity fields
    # may cross the SSH boundary, including when the host state is malformed.
    program = r'''
import json, pathlib, re
state = json.loads(pathlib.Path('/var/lib/nextstop/releases/state.json').read_text())
image = state.get('image')
if (state.get('environment') != 'production'
        or not isinstance(image, str)
        or not re.fullmatch(r'europe-west3-docker\.pkg\.dev/nextstop-tech-staging/nextstop/backend@sha256:[0-9a-f]{64}', image)
        or state.get('api', {}).get('image') != image or state.get('workerImage') != image
        or any(key in state for key in ('pending', 'pendingWorkerChanged', 'pendingCandidateSlot'))):
    raise RuntimeError('A clean production release is required.')
print(json.dumps({'environment':'production', 'image':image, 'apiImage':image, 'workerImage':image, 'pending':False}))
'''
    result = run(ssh(config, shlex.join(['sudo', '/usr/bin/python3', '-c', program]) + ' 2>/dev/null'), timeout=90)
    if (not isinstance(result, dict) or set(result) != {'environment', 'image', 'apiImage', 'workerImage', 'pending'}
            or result['environment'] != 'production' or result['pending'] is not False
            or result['apiImage'] != result['image'] or result['workerImage'] != result['image']):
        raise RuntimeError('A clean production release is required.')
    validate_image(result['image'], config)
    return result['image']


def create_current_backup(config: dict, *, run=run_json, command=run_command, now=time.time) -> dict:
    if (config['name'] != 'production' or config['database']['mode'] != 'local'
            or config['database']['instance'] != config['target']['instance']):
        raise ValueError('The configured production VM database is required.')
    client_configuration()
    command(ssh(config, 'true'), timeout=90)
    image = current_production_image(config, run=run)
    receipt = create_backup(config, image, run=run, command=command, now=now)
    if current_production_image(config, run=run) != image:
        raise RuntimeError('Production changed during the backup; no receipt was issued.')
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--image")
    target.add_argument("--current-production", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    config = configuration("production")
    receipt = create_current_backup(config) if args.current_production else create_backup(config, args.image)
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
