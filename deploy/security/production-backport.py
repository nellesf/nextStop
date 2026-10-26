#!/usr/bin/env python3
"""Protected, opt-in deployment of the reviewed production security backport.

Control is loaded from protected main by backend-production.yml. The pinned
installed VM controller performs its usual readiness/search/TLS/rollback gates
with --skip-migrations. No deployment source, SQL or environment file is uploaded.
Only a fresh backup receipt and transient root-only registry credentials travel
to the host. This one-off path deliberately refuses other baselines/artifacts.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shlex
import subprocess
import time
import uuid

PROJECT = "nextstop-tech-staging"
INSTANCE = "nextstop-backend"
ZONE = "europe-west3-a"
DEPLOY_ACCOUNT = f"nextstop-production-deploy@{PROJECT}.iam.gserviceaccount.com"
REGISTRY = f"europe-west3-docker.pkg.dev/{PROJECT}/nextstop/backend"
BASELINE_COMMIT = "fbd248999625a6171e12986bba477b4e4c4a6ec4"
BASELINE_IMAGE = REGISTRY + "@sha256:e93e7f3a622169b74507a3c3fe5712d6641ef600b6c99ae30ef5b22b285890f7"
TARGET_COMMIT = "e32bb59f69ee11f7bb0979a0a4cbefaf4b7ab4f0"
TARGET_IMAGE = REGISTRY + "@sha256:95753a1b0dee6a50c87daf821f681937d5c823bf20a5a80a24c1e5c9726e845e"
TARGET_CONFIG_DIGEST = "sha256:6daed4bbde5dcfb052cccdb0b1cda2d9e9981ce516775c6901d59d9fecbf762e"
INSTALLED_ROOT = "/opt/nextstop/releases/release.2F48B1TC"
CONTROLLER_HASHES = {
    "deploy/releases/release.py": "0e0f34fffa43ec937ec1a85877cc14e590ae9d69dc4cb29f2dbc142ae0c80495",
    "deploy/gcp-vm/compose.release.yaml": "7d76ae6f08f35c7a10efb43baea3bbc61163dd793485e9829ff4ffb82274bf5c",
    "deploy/gcp-vm/nginx-https.conf": "3869a5d03db540cbd3cac3bf74b08286f9ef8248e135965c1f634ffe61a5333a",
}
MIGRATIONS = [
    "0001_initial_postgis_projection.sql", "0002_live_availability_snapshots.sql",
    "0003_operator_charging_point_counts.sql", "0004_osm_food_poi_projection.sql",
    "0005_power_search_projection.sql", "0006_power_projection_work_memory.sql",
    "0007_power_projection_spatial_lookup.sql", "0008_conditional_charging_campus.sql",
    "0009_app_attest_authentication.sql", "0010_audit_only_projection_conflicts.sql",
    "0011_user_error_reports.sql", "0012_projection_build_statistics.sql",
    "0013_search_projection_retention.sql", "0014_static_projection_input_checks.sql",
    "0015_runtime_readiness.sql",
]
STAGING_CHECKS = {"apiReady", "authReady", "syntheticSearchPassed", "anonymousRequestsRejected",
                  "existingTrafficPreserved", "privateIAMPreserved", "gatewayAndBrokerUnchanged"}


class BackportError(RuntimeError):
    pass


def command(args, *, phase, input_text=None, timeout=120):
    try:
        result = subprocess.run(args, input=input_text, capture_output=True, text=True,
                                check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise BackportError(phase + ": command unavailable or timed out; output suppressed.") from None
    if result.returncode:
        raise BackportError(phase + ": command failed; output suppressed.")
    return result.stdout


def read_json(args, *, phase, run=command):
    try:
        return json.loads(run(args, phase=phase))
    except (ValueError, TypeError):
        raise BackportError(phase + ": invalid structured response; output suppressed.") from None


def validate_target(commit, image):
    if commit != TARGET_COMMIT or image != TARGET_IMAGE:
        raise BackportError("This reviewed maintenance path accepts only the pinned security backport.")


def validate_backup(receipt, image, now=None):
    now = time.time() if now is None else now
    if (not isinstance(receipt, dict) or receipt.get("environment") != "production"
            or receipt.get("project") != PROJECT or receipt.get("instance") != INSTANCE
            or receipt.get("image") != image or receipt.get("status") != "SUCCESSFUL"
            or type(receipt.get("completedAt")) not in (int, float)
            or not 0 <= now - receipt["completedAt"] <= 3600
            or not re.fullmatch(r"gs://nextstop-tech-staging-release-backups/production/nextstop-backend/[^#\s]+#[1-9][0-9]*", receipt.get("backupId", ""))):
        raise BackportError("A fresh, generation-bound backup of this production database/image is required.")


def validate_staging(deployments, statuses, commit, image, now=None):
    now = datetime.now(timezone.utc) if now is None else now
    matching = [row for row in deployments if row.get("sha") == commit
                and row.get("environment") == "staging" and row.get("task") == "nextstop-release"]
    if not matching:
        raise BackportError("No exact-image private staging validation is recorded.")
    latest = max(matching, key=lambda row: row["id"])
    payload = latest.get("payload", {})
    value = payload.get("validation", {})
    tag = "sec-" + commit[:12] + "-" + image.rsplit(":", 1)[1][:12]
    try:
        stamp = datetime.fromisoformat(value.get("verifiedAt", "").replace("Z", "+00:00"))
        fresh = stamp.tzinfo is not None and 0 <= (now - stamp).total_seconds() <= 3600
    except (ValueError, TypeError):
        fresh = False
    if (payload.get("image") != image or value.get("image") != image or value.get("commit") != commit
            or value.get("mode") != "private-candidate-validation" or value.get("passed") is not True
            or value.get("phase") != "private-candidates-verified" or not fresh
            or not all(value.get("checks", {}).get(key) is True for key in STAGING_CHECKS)
            or value.get("candidateRevisions") != {name: f"nextstop-{name}-{tag}" for name in ("api", "auth")}
            or not statuses or statuses[0].get("state") != "success"):
        raise BackportError("Private staging evidence is missing, stale, mismatched or unsuccessful.")
    return latest["id"]


def verify_source_and_staging(commit, image, *, run=command):
    validate_target(commit, image)
    account = run(["gcloud", "config", "get-value", "account"], phase="deployment-identity").strip()
    if account != DEPLOY_ACCOUNT:
        raise BackportError("The protected production deployment identity is required.")
    run(["git", "merge-base", "--is-ancestor", commit, "origin/main"], phase="trusted-main-ancestry")
    run(["git", "diff", "--exit-code", BASELINE_COMMIT, commit, "--", "backend/src", "backend/migrations", "ios"],
        phase="unchanged-application-and-schema")
    rows = read_json(["gh", "api", f"repos/nellesf/nextStop/deployments?sha={commit}&environment=staging&per_page=100"],
                     phase="staging-deployment", run=run)
    matching = [row for row in rows if row.get("sha") == commit and row.get("environment") == "staging"
                and row.get("task") == "nextstop-release"]
    if not matching:
        raise BackportError("No exact staging validation is recorded.")
    identifier = max(row["id"] for row in matching)
    statuses = read_json(["gh", "api", f"repos/nellesf/nextStop/deployments/{identifier}/statuses?per_page=1"],
                         phase="staging-status", run=run)
    return validate_staging(rows, statuses, commit, image)


# Executed from SSH stdin, never installed on the serving VM. Only fixed metadata
# is printed. Docker/release output, database values and environment files remain
# inside the process and cannot enter GitHub logs.
REMOTE = r'''
import hashlib, json, os, pathlib, re, subprocess, time

class GateError(Exception): pass

def execute(args, env=None, timeout=90):
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired):
        raise GateError('Host operation unavailable or timed out.') from None
    if result.returncode:
        raise GateError('Host operation failed; private output suppressed.')
    return result.stdout.strip()

def sha(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def inspect_container(name):
    fields = '{{json .Id}}|{{json .Image}}|{{json .Config.Image}}|{{json .State.StartedAt}}|{{json .State.Running}}'
    return [json.loads(item) for item in execute(['docker', 'inspect', '--format', fields, name]).split('|')]

def migrations():
    return execute(['docker', 'exec', 'gcp-vm-database-1', 'psql', '-XAt', '-U', 'nextstop_app', '-d', 'nextstop',
                    '-c', 'SELECT name FROM nextstop.schema_migrations ORDER BY name']).splitlines()

def receipt(path, data):
    value = json.loads(pathlib.Path(path).read_text())
    if (value.get('environment') != 'production' or value.get('project') != data['project']
            or value.get('instance') != data['instance'] or value.get('image') != data['image']
            or value.get('status') != 'SUCCESSFUL' or type(value.get('completedAt')) not in (int, float)
            or not 0 <= time.time() - value['completedAt'] <= 3600
            or not re.fullmatch(r'gs://nextstop-tech-staging-release-backups/production/nextstop-backend/[^#\s]+#[1-9][0-9]*', value.get('backupId',''))):
        raise GateError('Fresh exact-image production backup receipt required.')

def baseline(data):
    root = pathlib.Path('/opt/nextstop/current').resolve()
    if str(root) != data['installedRoot']:
        raise GateError('Installed release root differs from reviewed baseline.')
    for name, expected in data['controllerHashes'].items():
        if sha(root / name) != expected:
            raise GateError('Installed controller, Compose or Nginx template differs from reviewed baseline.')
    state = json.loads(pathlib.Path('/var/lib/nextstop/releases/state.json').read_text())
    if (state.get('environment') != 'production' or state.get('image') != data['baselineImage']
            or state.get('workerImage') != data['baselineImage'] or state.get('api', {}).get('image') != data['baselineImage']
            or state.get('api', {}).get('slot') not in ('blue','green')
            or any(key in state for key in ('pending','pendingWorkerChanged','pendingCandidateSlot'))):
        raise GateError('Production is not the clean reviewed baseline release.')
    source = execute(['docker','image','inspect','--format','{{index .Config.Labels "org.opencontainers.image.revision"}}', data['baselineImage']])
    if source != data['baselineCommit']:
        raise GateError('Production image source does not match the reviewed baseline.')
    names = ['gcp-vm-api-' + state['api']['slot'] + '-1', 'gcp-vm-auth-' + state['api']['slot'] + '-1', 'gcp-vm-worker-1']
    for name in names:
        value = inspect_container(name)
        if value[2] != data['baselineImage'] or value[4] is not True:
            raise GateError('Active production container differs from baseline.')
    if migrations() != data['migrations']:
        raise GateError('Production must retain exactly the original fifteen migrations.')
    database = inspect_container('gcp-vm-database-1')
    if database[4] is not True:
        raise GateError('Production database is not running.')
    protected = {name: sha(name) for name in ('/etc/nextstop/backend.env','/etc/nextstop/release.env')}
    return root, database, protected

def main(data):
    try:
        root, database, protected = baseline(data)
        if data['checkOnly']:
            print(json.dumps({'passed':True, 'mode':'security-only-preflight', 'baselineVerified':True}))
            return
        receipt(data['backupReceipt'], data)
        env = {'PATH':'/usr/sbin:/usr/bin:/sbin:/bin', 'LANG':'C.UTF-8', 'DOCKER_CONFIG':data['dockerConfig']}
        execute(['docker','pull',data['image']],env,timeout=600)
        image = json.loads(execute(['docker','image','inspect',data['image']],env))[0]
        if (image.get('Id') != data['configDigest'] or data['image'] not in image.get('RepoDigests',[])
                or image.get('Config',{}).get('Labels',{}).get('org.opencontainers.image.revision') != data['commit']):
            raise GateError('Pulled image does not match verified digest/config/source.')
        baseline(data)
        receipt(data['backupReceipt'], data)
        execute(['/usr/bin/python3', str(root/'deploy/releases/release.py'), 'deploy', '--environment','production',
                 '--image',data['image'],'--root',str(root),'--skip-migrations','--backup-receipt',data['backupReceipt']],env,timeout=1800)
        state=json.loads(pathlib.Path('/var/lib/nextstop/releases/state.json').read_text())
        if (state.get('image') != data['image'] or state.get('workerImage') != data['image']
                or state.get('api',{}).get('image') != data['image']
                or state.get('previous',{}).get('image') != data['baselineImage']
                or any(key in state for key in ('pending','pendingWorkerChanged','pendingCandidateSlot'))):
            raise GateError('Post-deploy release state or retained rollback image is invalid.')
        if inspect_container('gcp-vm-database-1') != database or migrations() != data['migrations']:
            raise GateError('Database identity, uptime or migration history changed unexpectedly.')
        if any(sha(name) != expected for name,expected in protected.items()):
            raise GateError('Production environment files changed unexpectedly.')
        if any(sha(root/name) != expected for name,expected in data['controllerHashes'].items()):
            raise GateError('Installed release tooling changed unexpectedly.')
        print(json.dumps({'passed':True,'mode':'security-only-production','image':data['image'],'commit':data['commit'],
                          'databaseUnchanged':True,'migrationsUnchanged':True,'environmentUnchanged':True,'retainedRollbackVerified':True}))
    except (GateError, OSError, ValueError, KeyError, TypeError) as error:
        reason=str(error) if isinstance(error,GateError) else 'Invalid host state; private details suppressed.'
        print(json.dumps({'passed':False,'error':reason}))
        raise SystemExit(1)
'''


def ssh(script):
    return ["gcloud", "compute", "ssh", INSTANCE, f"--project={PROJECT}", f"--zone={ZONE}",
            "--tunnel-through-iap", "--quiet", "--command=" + script]


def remote_program(data):
    return REMOTE + "\nmain(json.loads(" + repr(json.dumps(data)) + "))\n"


def payload(check_only, receipt=None, docker_config=None):
    return {"project": PROJECT, "instance": INSTANCE, "baselineCommit": BASELINE_COMMIT, "baselineImage": BASELINE_IMAGE,
            "commit": TARGET_COMMIT, "image": TARGET_IMAGE, "configDigest": TARGET_CONFIG_DIGEST,
            "installedRoot": INSTALLED_ROOT, "controllerHashes": CONTROLLER_HASHES, "migrations": MIGRATIONS,
            "checkOnly": check_only, "backupReceipt": receipt, "dockerConfig": docker_config}


def host_check(data, *, run=command):
    raw = run(ssh("sudo /usr/bin/python3 -"), phase="host-security-backport", input_text=remote_program(data), timeout=2100)
    try:
        value = json.loads(raw)
    except ValueError:
        raise BackportError("Host returned invalid structured result; private output suppressed.") from None
    if not isinstance(value, dict) or value.get("passed") is not True:
        raise BackportError("Host security backport did not report success.")
    return value


def deploy(commit, image, backup_path=None, *, check_only=False, run=command):
    staging = verify_source_and_staging(commit, image, run=run)
    # A new CI SSH identity can emit a key-generation banner before remote JSON.
    run(ssh("true"), phase="ssh-initialize")
    preflight = host_check(payload(True), run=run)
    if check_only:
        return {**preflight, "stagingDeploymentId": staging}
    if backup_path is None:
        raise BackportError("Security-only deployment requires a fresh backup receipt.")
    try:
        backup = json.loads(Path(backup_path).read_text())
    except (OSError, ValueError):
        raise BackportError("Backup receipt is unavailable or invalid.") from None
    validate_backup(backup, image)
    operation = uuid.uuid4().hex
    receipt = "/tmp/nextstop-security-backup-" + operation + ".json"
    credentials = "/run/nextstop-security-registry-" + operation
    primary_error = None
    try:
        run(["gcloud", "compute", "scp", str(backup_path), INSTANCE + ":" + receipt, f"--project={PROJECT}",
             f"--zone={ZONE}", "--tunnel-through-iap", "--quiet"], phase="backup-receipt-upload")
        run(ssh(shlex.join(["sudo", "chmod", "600", receipt])), phase="backup-receipt-permissions")
        run(ssh(shlex.join(["sudo", "install", "-d", "-m", "700", credentials])), phase="registry-directory")
        token = run(["gcloud", "auth", "print-access-token", "--quiet"], phase="registry-credential").strip()
        if not token or len(token) > 16384 or any(char.isspace() for char in token):
            raise BackportError("Registry credential unavailable; value suppressed.")
        run(ssh(shlex.join(["sudo", "env", "DOCKER_CONFIG=" + credentials, "docker", "login",
                           "--username", "oauth2accesstoken", "--password-stdin", REGISTRY.split("/")[0]])),
            phase="registry-login", input_text=token + "\n")
        del token
        result = host_check(payload(False, receipt, credentials), run=run)
        return {**result, "stagingDeploymentId": staging}
    except BaseException as error:
        primary_error = error
        raise
    finally:
        failure = None
        for phase, args in (
            ("registry-cleanup", ["sudo", "rm", "-rf", "--", credentials]),
            ("receipt-cleanup", ["sudo", "rm", "-f", "--", receipt]),
        ):
            try:
                run(ssh(shlex.join(args)), phase=phase)
            except BackportError as error:
                failure = failure or error
        if primary_error is None and failure is not None:
            raise failure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--backup-receipt", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    try:
        result = deploy(args.commit, args.image, args.backup_receipt, check_only=args.check_only)
        print(json.dumps(result, sort_keys=True))
    except (BackportError, OSError, ValueError, TypeError, KeyError):
        print(json.dumps({"passed": False, "mode": "security-only-production", "error": "Security-only production gate failed; private output suppressed."}))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
