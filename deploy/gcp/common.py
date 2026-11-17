"""Shared, non-secret environment configuration and bounded CLI calls."""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IMAGE_PATTERN = re.compile(r"^[a-z0-9.-]+/[a-z0-9_./-]+@sha256:[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def configuration(environment: str) -> dict:
    if environment not in {"staging", "production"}:
        raise ValueError("Choose staging or production explicitly.")
    result = json.loads((ROOT / "deploy" / "environments" / f"{environment}.json").read_text())
    if result["name"] != environment:
        raise ValueError("Environment configuration identity mismatch.")
    expected_domain = "api.nextstop.tech" if environment == "production" else "api-staging.nextstop.tech"
    if result["domain"] != expected_domain:
        raise ValueError("Unexpected API origin in environment configuration.")
    return result


def run_json(arguments: list[str], timeout: int = 180) -> object:
    result = subprocess.run(arguments, text=True, capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        # CLI errors can include credentials or rendered configuration. Report the
        # command family only, never the subprocess output or complete arguments.
        raise RuntimeError(f"{arguments[0]} {' '.join(arguments[1:3])} failed (exit {result.returncode}).")
    return json.loads(result.stdout or "null")


def validate_image(image: str, config: dict) -> None:
    if not IMAGE_PATTERN.fullmatch(image) or image.split("@", 1)[0] != config["registry"]:
        raise ValueError("Release image must use the configured repository and an immutable SHA-256 digest.")


def verified_platform_image(commit: str, image: str, config: dict, *, run=run_json) -> str:
    """Select the proven linux/amd64 manifest, retaining direct manifest identity."""
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ValueError("A complete Git commit is required.")
    validate_image(image, config)
    digest = image.split("@", 1)[1]
    proof = run([sys.executable, str(ROOT / "deploy/gcp-run/registry.py"),
                 "--commit", commit, "--digest", digest])
    if (not isinstance(proof, dict) or proof.get("verified") is not True
            or proof.get("manifestAndConfigHashesVerified") is not True
            or proof.get("commit") != commit or proof.get("digest") != digest
            or proof.get("platform") != "linux/amd64"
            or not isinstance(proof.get("platformDigest"), str)):
        raise ValueError("Registry metadata did not prove the release platform manifest.")
    canonical = config["registry"] + "@" + proof["platformDigest"]
    validate_image(canonical, config)
    return canonical
