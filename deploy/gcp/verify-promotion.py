#!/usr/bin/env python3
"""Require the exact tested main commit, image and successful staging deployment."""
from __future__ import annotations

import argparse
import json
import subprocess

from common import COMMIT_PATTERN, ROOT, configuration, run_json, validate_image


def verify(commit: str, image: str, *, run=run_json) -> dict:
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ValueError("A complete 40-character Git commit is required.")
    config = configuration("production")
    validate_image(image, config)
    artifact = run([
        "gcloud", "artifacts", "docker", "images", "describe", config["registry"] + ":" + commit,
        "--project=nextstop-tech-staging", "--format=json", "--quiet",
    ])
    if artifact.get("image_summary", {}).get("digest") != image.split("@", 1)[1]:
        raise ValueError("The selected image is not the immutable artifact built for this commit.")
    deployments = run([
        "gh", "api", f"repos/nellesf/nextStop/deployments?sha={commit}&environment=staging&per_page=100",
    ])
    matching = [item for item in deployments if item.get("sha") == commit
                and item.get("environment") == "staging" and item.get("task") == "nextstop-release"]
    if not matching:
        raise ValueError("This commit has no staging deployment.")
    latest = max(matching, key=lambda item: item["id"])
    if latest.get("payload", {}).get("image") != image:
        raise ValueError("The staging deployment does not attest to the selected image digest.")
    statuses = run(["gh", "api", f"repos/nellesf/nextStop/deployments/{latest['id']}/statuses?per_page=1"])
    if not statuses or statuses[0].get("state") != "success":
        raise ValueError("The most recent staging deployment of this commit did not succeed.")
    return {"commit": commit, "image": image, "stagingDeploymentId": latest["id"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    if not COMMIT_PATTERN.fullmatch(args.commit):
        parser.error("A complete Git commit is required.")
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", args.commit, "origin/main"], cwd=ROOT, check=False,
    )
    if ancestor.returncode:
        parser.error("Production releases must originate from main.")
    print(json.dumps(verify(args.commit, args.image)))


if __name__ == "__main__":
    main()
