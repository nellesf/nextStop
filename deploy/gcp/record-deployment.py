#!/usr/bin/env python3
"""Record the actual release commit and digest, independently of workflow HEAD."""
from __future__ import annotations

import argparse
import json
import subprocess

from common import COMMIT_PATTERN, configuration, validate_image


def post(path: str, payload: dict) -> dict:
    result = subprocess.run(["gh", "api", "--method", "POST", path, "--input", "-"],
                            input=json.dumps(payload), text=True, capture_output=True, check=False, timeout=60)
    if result.returncode:
        raise RuntimeError("GitHub deployment recording failed.")
    return json.loads(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start")
    start.add_argument("--environment", choices=["staging", "production"], required=True)
    start.add_argument("--commit", required=True)
    start.add_argument("--image", required=True)
    status = commands.add_parser("status")
    status.add_argument("--id", type=int, required=True)
    status.add_argument("--state", choices=["success", "failure"], required=True)
    args = parser.parse_args()
    endpoint = "repos/nellesf/nextStop/deployments"
    if args.command == "start":
        config = configuration(args.environment)
        if not COMMIT_PATTERN.fullmatch(args.commit):
            parser.error("A complete Git commit is required.")
        validate_image(args.image, config)
        deployment = post(endpoint, {"ref": args.commit, "task": "nextstop-release",
            "auto_merge": False, "required_contexts": [], "environment": args.environment,
            "production_environment": args.environment == "production", "transient_environment": False,
            "payload": {"image": args.image}})
        identifier = int(deployment["id"])
        post(f"{endpoint}/{identifier}/statuses", {"state": "in_progress", "auto_inactive": False})
        print(identifier)
    else:
        if args.id < 1:
            parser.error("Invalid deployment ID.")
        post(f"{endpoint}/{args.id}/statuses", {"state": args.state, "auto_inactive": False})


if __name__ == "__main__":
    main()
