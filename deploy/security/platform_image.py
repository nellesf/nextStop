#!/usr/bin/env python3
"""Resolve a backend commit tag to its verified linux/amd64 manifest."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gcp"))
from common import COMMIT_PATTERN, run_json, verified_platform_image

REGISTRY = "europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend"


def select_image(commit: str, *, run=run_json) -> dict:
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ValueError("A complete Git commit is required.")
    tagged = run(["gcloud", "artifacts", "docker", "images", "describe", REGISTRY + ":" + commit,
                  "--project=nextstop-tech-staging", "--format=json", "--quiet", "--verbosity=error"])
    summary = tagged.get("image_summary") if isinstance(tagged, dict) else None
    digest = summary.get("digest") if isinstance(summary, dict) else None
    if not isinstance(digest, str):
        raise ValueError("Registry commit tag did not return an immutable digest.")
    tagged_image = REGISTRY + "@" + digest
    image = verified_platform_image(commit, tagged_image, {"registry": REGISTRY}, run=run)
    return {"commit": commit, "tagImage": tagged_image, "image": image,
            "platform": "linux/amd64", "manifestAndConfigHashesVerified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--output-ref", required=True, type=Path)
    parser.add_argument("--output-proof", required=True, type=Path)
    args = parser.parse_args()
    try:
        # A failed rerun cannot leave a usable reference from an earlier attempt.
        args.output_ref.unlink(missing_ok=True)
        args.output_proof.unlink(missing_ok=True)
        if args.registry != REGISTRY:
            raise ValueError("Unexpected backend registry.")
        proof = select_image(args.commit)
        args.output_proof.write_text(json.dumps(proof, indent=2) + "\n")
        args.output_ref.write_text(proof["image"] + "\n")
        print(json.dumps(proof, separators=(",", ":")))
        return 0
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired):
        print("Platform image verification failed; private command output suppressed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
