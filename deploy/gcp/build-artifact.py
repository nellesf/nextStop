#!/usr/bin/env python3
"""Build a commit tag once, then verify and reuse its immutable image digest."""
from __future__ import annotations

import argparse
import http.client
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse

from common import COMMIT_PATTERN, ROOT, configuration, validate_image

API_HOST = "artifactregistry.googleapis.com"
MAX_RESPONSE_BYTES = 256 * 1024
DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")


class BuildArtifactError(Exception):
    pass


def run_command(arguments: list[str], timeout: int = 180) -> str:
    try:
        result = subprocess.run(arguments, cwd=ROOT, capture_output=True, text=True,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BuildArtifactError("Artifact command unavailable or timed out.") from error
    if result.returncode:
        # Docker/gcloud errors can echo credentials. Never emit their output.
        raise BuildArtifactError("Artifact command failed.")
    return result.stdout


class ArtifactRegistry:
    def __init__(self, token: str):
        if not token or len(token) > 16384 or any(character.isspace() for character in token):
            raise BuildArtifactError("Registry authentication returned an invalid credential.")
        self.token = token

    def get(self, resource: str, *, missing_ok: bool = False):
        # Fixed HTTPS host, no redirects; the credential stays in memory only.
        connection = http.client.HTTPSConnection(API_HOST, timeout=30)
        try:
            connection.request("GET", "/v1/" + resource,
                               headers={"Authorization": "Bearer " + self.token, "Accept": "application/json"})
            response = connection.getresponse()
            if response.status == 404 and missing_ok:
                return None
            if response.status != 200:
                raise BuildArtifactError(f"Artifact Registry lookup failed (HTTP {response.status}).")
            data = response.read(MAX_RESPONSE_BYTES + 1)
            if len(data) > MAX_RESPONSE_BYTES:
                raise BuildArtifactError("Artifact Registry response exceeded its size limit.")
            value = json.loads(data)
            if not isinstance(value, dict):
                raise BuildArtifactError("Artifact Registry returned an invalid response.")
            return value
        except (OSError, http.client.HTTPException, ValueError) as error:
            raise BuildArtifactError("Artifact Registry lookup failed.") from error
        finally:
            connection.close()


def registry_resources(config: dict) -> tuple[str, str, str]:
    registry = config["registry"]
    validate_image(registry + "@sha256:" + "0" * 64, config)
    host, project, repository, package = registry.split("/", 3)
    if (config["name"] != "staging" or project != config["registryProject"]
            or host != config["region"] + "-docker.pkg.dev"
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", repository)
            or any(part in ("", ".", "..") for part in package.split("/"))):
        raise BuildArtifactError("Artifact repository does not match its configured registry project.")
    resource = f"projects/{project}/locations/{config['region']}/repositories/{repository}"
    return host, resource, resource + "/packages/" + urllib.parse.quote(package, safe="")


def require_immutable_repository(registry, resource: str) -> None:
    repository = registry.get(resource)
    if (not isinstance(repository, dict) or repository.get("name") != resource
            or repository.get("format") != "DOCKER"
            or not isinstance(repository.get("dockerConfig"), dict)
            or repository["dockerConfig"].get("immutableTags") is not True):
        raise BuildArtifactError("The configured Docker repository must enforce immutable tags.")


def tagged_digest(registry, package: str, commit: str) -> str | None:
    name = package + "/tags/" + commit
    tag = registry.get(name, missing_ok=True)
    if tag is None:
        return None
    prefix = package + "/versions/"
    if (not isinstance(tag, dict) or tag.get("name") != name
            or not isinstance(tag.get("version"), str) or not tag["version"].startswith(prefix)):
        raise BuildArtifactError("Commit tag refers to an unexpected artifact resource.")
    digest = tag["version"][len(prefix):]
    if not DIGEST_PATTERN.fullmatch(digest):
        raise BuildArtifactError("Commit tag did not identify a SHA-256 image digest.")
    return digest


def verify_revision(image: str, commit: str, run) -> None:
    run(["docker", "pull", image], timeout=600)
    label = run(["docker", "image", "inspect", "--format",
                 '{{ index .Config.Labels "org.opencontainers.image.revision" }}', image]).strip()
    if label != commit:
        raise BuildArtifactError("Immutable image revision does not match the tested commit.")


def build_artifact(commit: str, config: dict, *, run=run_command, registry=None) -> str:
    if not COMMIT_PATTERN.fullmatch(commit):
        raise BuildArtifactError("A complete Git commit is required.")
    host, repository, package = registry_resources(config)
    if run(["git", "rev-parse", "HEAD"]).strip() != commit:
        raise BuildArtifactError("The checked-out source does not match the tested commit.")
    if registry is None:
        registry = ArtifactRegistry(run(["gcloud", "auth", "print-access-token", "--quiet"]).strip())
    require_immutable_repository(registry, repository)
    digest = tagged_digest(registry, package, commit)
    run(["gcloud", "auth", "configure-docker", host, "--quiet"])
    if digest is None:
        tag = config["registry"] + ":" + commit
        run(["docker", "build", "--label", "org.opencontainers.image.revision=" + commit,
             "--tag", tag, "backend"], timeout=1200)
        # Recheck before the first registry mutation, including after a long build.
        require_immutable_repository(registry, repository)
        run(["docker", "push", tag], timeout=600)
        digest = tagged_digest(registry, package, commit)
        if digest is None:
            raise BuildArtifactError("Pushed commit tag is not available for verification.")
    image = config["registry"] + "@" + digest
    validate_image(image, config)
    verify_revision(image, commit, run)
    return image


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        image = build_artifact(args.commit, configuration("staging"))
        if args.github_output:
            with args.github_output.open("a") as output:
                output.write("ref=" + image + "\n")
        else:
            print(image)
    except (BuildArtifactError, OSError, ValueError, KeyError):
        print("Artifact build or verification failed; no release image was selected.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
