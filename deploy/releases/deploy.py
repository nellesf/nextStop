#!/usr/bin/env python3
"""Deploy a tested immutable image to one isolated VM per environment."""
from __future__ import annotations
import argparse
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


def command(arguments, *, input_text=None):
    try:
        result = subprocess.run(arguments, input=input_text, capture_output=True,
                                text=True, check=False, timeout=1800)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseError("Deployment command unavailable or timed out.") from error
    if result.returncode:
        # Remote command output can contain credentials. Never relay it to CI logs.
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

    def gcloud(operation, *arguments, input_text=None):
        return command(["gcloud", "compute", operation, *arguments,
                        f"--project={project}", f"--zone={target['zone']}",
                        "--tunnel-through-iap", "--quiet"], input_text=input_text)

    def ssh(arguments, input_text=None):
        return gcloud("ssh", target["instance"], "--command=" + shlex.join(arguments), input_text=input_text)

    def upload(local, remote):
        gcloud("scp", str(local), f"{target['instance']}:{remote}")

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
        try:
            upload(archive, remote_archive)
            upload(root / "deploy/gcp-vm/install-release.sh", remote_installer)
            options = ["deploy", "--environment", args.environment, "--image", args.image]
            if args.backup_receipt:
                upload(args.backup_receipt, receipt_remote)
                options += ["--backup-receipt", receipt_remote]
            if args.skip_public_probe:
                options += ["--skip-public-probe"]
            # Existing serving VMs need no new service account or VM restart.
            # The short-lived credential exists only in memory, SSH stdin and a
            # root-only temporary Docker config; it is never a command argument.
            ssh(["sudo", "install", "-d", "-m", "700", docker_config])
            token = command(["gcloud", "auth", "print-access-token"]).strip()
            if not token or "\n" in token:
                raise ReleaseError("Registry authentication token is unavailable.")
            ssh(["sudo", "env", f"DOCKER_CONFIG={docker_config}", "docker", "login",
                 "--username", "oauth2accesstoken", "--password-stdin", config["registry"].split("/")[0]], token + "\n")
            del token
            # The host runner takes one lock, performs one migration/role
            # transaction sequence, gates the candidate, then replaces the worker.
            ssh(["sudo", "env", f"DOCKER_CONFIG={docker_config}", "bash", remote_installer,
                 remote_archive, *options])
            print(json.dumps({"event": "environment-release-completed", "environment": args.environment, "image": args.image}))
        finally:
            try:
                ssh(["sudo", "rm", "-rf", "--", docker_config])
            finally:
                try:
                    ssh(["rm", "-f", "--", remote_archive, remote_installer, receipt_remote])
                except ReleaseError:
                    pass


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError):
        print("Environment release failed; retained slots remain available for rollback.", file=sys.stderr)
        raise SystemExit(1)
