#!/usr/bin/env python3
"""Deploy a tested immutable image to one isolated VM per environment."""
from __future__ import annotations
import argparse
from enum import Enum
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid

from release import DIGEST, DOMAINS, ReleaseError


class DeploymentPhase(str, Enum):
    ARCHIVE_UPLOAD = "archive_upload"
    INSTALLER_UPLOAD = "installer_upload"
    BACKUP_RECEIPT_UPLOAD = "backup_receipt_upload"
    REGISTRY_DIRECTORY = "registry_directory"
    REGISTRY_TOKEN = "registry_token"
    REGISTRY_LOGIN = "registry_login"
    HOST_RELEASE = "host_release"
    CLEANUP_REGISTRY = "cleanup_registry"
    CLEANUP_UPLOADS = "cleanup_uploads"


class FailureKind(str, Enum):
    EXIT = "exit"
    TIMEOUT = "timeout"
    UNAVAILABLE = "unavailable"
    INVALID_OUTPUT = "invalid_output"


SAFE_ERROR_CODES = frozenset({
    "PERMISSION_DENIED", "UNAUTHENTICATED", "IAM_PERMISSION_DENIED",
    "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
})
SAFE_PERMISSIONS = frozenset({
    "compute.projects.get", "compute.instances.get", "compute.instances.osLogin",
    "compute.instances.osAdminLogin", "iap.tunnelInstances.accessViaIAP",
    "iam.serviceAccounts.getAccessToken", "artifactregistry.repositories.downloadArtifacts",
})


def safe_error_details(stderr):
    # Inspect only known error fields; never echo excerpts, resource names,
    # principals, arbitrary permission names, or matches in free-form prose.
    text = stderr[:65536] if isinstance(stderr, str) else ""
    codes, permissions = set(), set()
    try:
        value = json.loads(text)
    except (ValueError, RecursionError):
        value = None
    if isinstance(value, dict) and isinstance(value.get("error"), dict):
        error = value["error"]
        if isinstance(error.get("status"), str) and error["status"] in SAFE_ERROR_CODES:
            codes.add(error["status"])
        for field in ("details", "errors"):
            entries = error.get(field, [])
            if not isinstance(entries, list):
                continue
            for entry in entries[:32]:
                if not isinstance(entry, dict):
                    continue
                if isinstance(entry.get("reason"), str) and entry["reason"] in SAFE_ERROR_CODES:
                    codes.add(entry["reason"])
                metadata = entry.get("metadata")
                if isinstance(metadata, dict) and isinstance(metadata.get("permission"), str):
                    if metadata["permission"] in SAFE_PERMISSIONS:
                        permissions.add(metadata["permission"])
    # gcloud's normal CLI status prefix and rendered ErrorInfo YAML fields.
    for match in re.finditer(r"(?m)^ERROR: \(gcloud\.[a-zA-Z0-9_.-]+\) ([A-Z_]+):", text):
        if match[1] in SAFE_ERROR_CODES:
            codes.add(match[1])
    for match in re.finditer(r"(?m)^\s*(?:status|reason): ['\"]?([A-Z_]+)['\"]?\s*$", text):
        if match[1] in SAFE_ERROR_CODES:
            codes.add(match[1])
    for match in re.finditer(r"(?m)^\s*permission: ['\"]?([a-zA-Z.]+)['\"]?\s*$", text):
        if match[1] in SAFE_PERMISSIONS:
            permissions.add(match[1])
    for match in re.finditer(
            r"(?m)^\s*(?:ERROR: \(gcloud\.[a-zA-Z0-9_.-]+\) )?(?:- |denied: )?"
            r"(?:Required ['\"]([a-zA-Z.]+)['\"] permission(?: for|[.\n]|$)|"
            r"Permission ['\"]([a-zA-Z.]+)['\"] denied(?: on|[.\n]|$))", text):
        permission = match[1] or match[2]
        if permission in SAFE_PERMISSIONS:
            permissions.add(permission)
    no_account = re.search(
        r"(?m)^(?:ERROR: \(gcloud\.[a-zA-Z0-9_.-]+\) )?"
        r"You do not currently have an active account selected\.$", text) is not None
    return {"errorCodes": sorted(codes), "permissions": sorted(permissions),
            "cliCategory": "no_active_account" if no_account else None}


def report_failure(phase, kind, *, exit_code=None, stderr=""):
    print(json.dumps({"event": "deployment_command_failed", "phase": phase.value,
                      "kind": kind.value, "exitCode": exit_code,
                      **safe_error_details(stderr)}, sort_keys=True), file=sys.stderr)


def command(arguments, *, phase, input_text=None):
    if not isinstance(phase, DeploymentPhase):
        raise ReleaseError("Deployment command requires a known phase.")
    try:
        result = subprocess.run(arguments, input=input_text, capture_output=True,
                                text=True, check=False, timeout=1800)
    except subprocess.TimeoutExpired:
        report_failure(phase, FailureKind.TIMEOUT)
        raise ReleaseError("Deployment command timed out.") from None
    except OSError:
        report_failure(phase, FailureKind.UNAVAILABLE)
        raise ReleaseError("Deployment command unavailable.") from None
    if result.returncode:
        # Remote command output can contain credentials. Never relay it to CI logs.
        report_failure(phase, FailureKind.EXIT, exit_code=result.returncode, stderr=result.stderr)
        raise ReleaseError("Deployment command failed.")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True, choices=["staging", "production"])
    parser.add_argument("--image", required=True)
    parser.add_argument("--backup-receipt")
    parser.add_argument("--skip-public-probe", action="store_true", help="Initial DNS bootstrap only.")
    args = parser.parse_args()
    if not DIGEST.fullmatch(args.image):
        raise ReleaseError("Image must use an immutable registry digest.")
    root = Path(__file__).resolve().parents[2]
    config = json.loads((root / f"deploy/environments/{args.environment}.json").read_text())
    if config["name"] != args.environment or config["domain"] != DOMAINS[args.environment]:
        raise ReleaseError("Environment configuration mismatch.")
    if args.image.partition("@")[0] != config["registry"]:
        raise ReleaseError("Image is outside the environment's approved registry repository.")
    if config["database"]["mode"] != "local":
        raise ReleaseError("This deployment requires one VM with a local database.")
    project, target = config["project"], config["target"]
    if (not re.fullmatch(r"[a-z][a-z0-9-]+", project)
            or not re.fullmatch(r"[a-z][a-z0-9-]+", target["instance"])
            or not re.fullmatch(r"[a-z0-9-]+", target["zone"])):
        raise ReleaseError("Invalid configured deployment target.")
    if args.environment == "production" and not args.backup_receipt:
        raise ReleaseError("Production requires a verified database backup receipt.")

    def gcloud(operation, *arguments, phase, input_text=None):
        return command(["gcloud", "compute", operation, *arguments,
                        f"--project={project}", f"--zone={target['zone']}",
                        "--tunnel-through-iap", "--quiet"], phase=phase, input_text=input_text)

    def ssh(arguments, *, phase, input_text=None):
        return gcloud("ssh", target["instance"], "--command=" + shlex.join(arguments), phase=phase, input_text=input_text)

    def upload(local, remote, phase):
        gcloud("scp", str(local), f"{target['instance']}:{remote}", phase=phase)

    with tempfile.TemporaryDirectory(prefix="nextstop-deploy-") as temporary:
        archive = Path(temporary) / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for subtree in [root / "deploy/gcp-vm", root / "deploy/releases"]:
                for file in sorted(subtree.rglob("*")):
                    if file.is_file() and ".env" not in file.name and "__pycache__" not in file.parts and not file.name.endswith(".pyc"):
                        bundle.add(file, arcname=str(file.relative_to(root)), recursive=False)
        operation = uuid.uuid4().hex
        remote_archive = f"/tmp/nextstop-release-{operation}.tar.gz"
        remote_installer = f"/tmp/nextstop-install-{operation}.sh"
        receipt_remote = f"/tmp/nextstop-backup-{operation}.json"
        docker_config = f"/run/nextstop-registry-{operation}"
        primary_error = None
        try:
            upload(archive, remote_archive, DeploymentPhase.ARCHIVE_UPLOAD)
            upload(root / "deploy/gcp-vm/install-release.sh", remote_installer, DeploymentPhase.INSTALLER_UPLOAD)
            options = ["deploy", "--environment", args.environment, "--image", args.image]
            if args.backup_receipt:
                upload(args.backup_receipt, receipt_remote, DeploymentPhase.BACKUP_RECEIPT_UPLOAD)
                options += ["--backup-receipt", receipt_remote]
            if args.skip_public_probe:
                options += ["--skip-public-probe"]
            # Existing serving VMs need no new service account or VM restart.
            # The short-lived credential exists only in memory, SSH stdin and a
            # root-only temporary Docker config; it is never a command argument.
            ssh(["sudo", "install", "-d", "-m", "700", docker_config], phase=DeploymentPhase.REGISTRY_DIRECTORY)
            token = command(["gcloud", "auth", "print-access-token"], phase=DeploymentPhase.REGISTRY_TOKEN).strip()
            if not token or "\n" in token:
                report_failure(DeploymentPhase.REGISTRY_TOKEN, FailureKind.INVALID_OUTPUT, exit_code=0)
                raise ReleaseError("Registry authentication token is unavailable.")
            ssh(["sudo", "env", f"DOCKER_CONFIG={docker_config}", "docker", "login",
                 "--username", "oauth2accesstoken", "--password-stdin", config["registry"].split("/")[0]],
                phase=DeploymentPhase.REGISTRY_LOGIN, input_text=token + "\n")
            del token
            # The host runner takes one lock, performs one migration/role
            # transaction sequence, gates the candidate, then replaces the worker.
            ssh(["sudo", "env", f"DOCKER_CONFIG={docker_config}", "bash", remote_installer,
                 remote_archive, *options], phase=DeploymentPhase.HOST_RELEASE)
        except BaseException as error:
            primary_error = error
            raise
        finally:
            cleanup_error = None
            for phase, arguments in [
                (DeploymentPhase.CLEANUP_REGISTRY, ["sudo", "rm", "-rf", "--", docker_config]),
                (DeploymentPhase.CLEANUP_UPLOADS, ["rm", "-f", "--", remote_archive, remote_installer, receipt_remote]),
            ]:
                try:
                    ssh(arguments, phase=phase)
                except ReleaseError as error:
                    if cleanup_error is None:
                        cleanup_error = error
            # Each command already emitted its own safe diagnostic. Cleanup
            # must not mask the original failure or prevent the other cleanup.
            if primary_error is None and cleanup_error is not None:
                raise cleanup_error
        print(json.dumps({"event": "environment-release-completed", "environment": args.environment, "image": args.image}))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError):
        print("Environment release failed; retained slots remain available for rollback.", file=sys.stderr)
        raise SystemExit(1)
