#!/usr/bin/env python3
"""Allow distributed CFBundleVersions in the staging App Attest service."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


SETTING = "APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS"
VERSION_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,64}", re.ASCII)
ENVIRONMENT_FILE = Path("/etc/nextstop/backend.env")
COMPOSE_FILE = Path("/opt/nextstop/current/deploy/gcp-vm/compose.yaml")
RUNTIME_TIMEOUT_SECONDS = 5
COMPOSE_TIMEOUT_SECONDS = 140
LOCK_TIMEOUT_SECONDS = 5


class AllowlistError(Exception):
    """A deliberately sanitized operational failure."""


def validate_versions(value):
    versions = value.split(",")
    if (
        not 1 <= len(versions) <= 32
        or any(VERSION_PATTERN.fullmatch(version) is None for version in versions)
        or len(set(versions)) != len(versions)
    ):
        raise AllowlistError("The bundle-version allowlist is invalid.")
    return versions


def updated_environment(original, build):
    if VERSION_PATTERN.fullmatch(build) is None:
        raise AllowlistError("Supply one valid CFBundleVersion (1–64 allowed characters).")
    lines = original.splitlines(keepends=True)
    assignment = SETTING.encode("ascii") + b"="
    candidate = re.compile(rb"(?:export\s+)?" + SETTING.encode("ascii") + rb"(?:\s|=|$)")
    matches = [
        index for index, line in enumerate(lines)
        if candidate.match(line.strip()) is not None
    ]
    if len(matches) != 1:
        raise AllowlistError("The environment must contain exactly one allowlist setting.")
    index = matches[0]
    content = lines[index].rstrip(b"\r\n")
    if not content.startswith(assignment):
        raise AllowlistError("The allowlist setting must use canonical KEY=value syntax.")
    try:
        versions = validate_versions(content[len(assignment):].decode("ascii"))
    except UnicodeDecodeError:
        raise AllowlistError("The bundle-version allowlist is invalid.") from None
    if build not in versions:
        versions = validate_versions(",".join([*versions, build]))
        newline = lines[index][len(content):]
        lines[index] = assignment + ",".join(versions).encode("ascii") + newline
    return b"".join(lines), versions


def atomic_write(path, content, metadata):
    """Keep secrets and ownership intact; never create a readable temporary file."""
    descriptor, temporary = tempfile.mkstemp(prefix=".nextstop-env-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run_command(command):
    environment = os.environ.copy()
    # Shell overrides must not supersede the value just written to --env-file.
    environment.pop(SETTING, None)
    return subprocess.run(
        command, capture_output=True, text=True, check=False,
        timeout=COMPOSE_TIMEOUT_SECONDS if "up" in command else RUNTIME_TIMEOUT_SECONDS,
        env=environment,
    )


def runtime_versions(compose, runner):
    command = [
        *compose, "exec", "-T", "auth-backend", "node", "-e",
        f"process.stdout.write(JSON.stringify(process.env.{SETTING} ?? null))",
    ]
    try:
        result = runner(command)
        if result.returncode != 0:
            return None
        value = json.loads(result.stdout)
        return validate_versions(value) if isinstance(value, str) else None
    except (OSError, subprocess.SubprocessError, ValueError, AllowlistError):
        return None


def apply_compose(compose, runner):
    try:
        result = runner([
            *compose, "up", "-d", "--wait", "--wait-timeout", "120",
            "--no-deps", "auth-backend",
        ])
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return False


def acquire_lock(lock):
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise AllowlistError("Another build update is in progress; retry later.") from None
            time.sleep(0.1)


def apply_build_versions(versions, environment_file=ENVIRONMENT_FILE,
                         compose_file=COMPOSE_FILE, runner=run_command):
    """Return whether configuration/runtime changed; raise only sanitized errors."""
    environment_file = Path(environment_file)
    compose_file = Path(compose_file)
    if isinstance(versions, (str, bytes)):
        raise AllowlistError("Supply a sequence of exact CFBundleVersion values.")
    versions = list(versions)
    if any(not isinstance(value, str) or VERSION_PATTERN.fullmatch(value) is None
           for value in versions):
        raise AllowlistError("Supply valid CFBundleVersions (1–64 allowed characters each).")
    validate_versions(",".join(versions))
    lock_path = environment_file.with_name(environment_file.name + ".allow-build.lock")
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    try:
        with os.fdopen(os.open(lock_path, flags, 0o600), "r+") as lock:
            os.fchmod(lock.fileno(), 0o600)
            acquire_lock(lock)
            metadata = environment_file.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise AllowlistError("The environment path must be a regular file.")
            original = environment_file.read_bytes()
            desired = original
            for build in versions:
                desired, merged_versions = updated_environment(desired, build)
            original_versions = updated_environment(original, merged_versions[0])[1]
            compose = [
                "docker", "compose", "--project-name", "gcp-vm",
                "--env-file", str(environment_file), "-f", str(compose_file),
            ]
            if desired == original and runtime_versions(compose, runner) == merged_versions:
                return False
            if desired != original:
                atomic_write(environment_file, desired, metadata)
            if (apply_compose(compose, runner)
                    and runtime_versions(compose, runner) == merged_versions):
                return True

            # Compose may have recreated a container before failing its health
            # check. Restore the file and reapply its previous configuration.
            if environment_file.read_bytes() != desired:
                raise AllowlistError(
                    "Authentication update failed; the environment changed externally. "
                    "No rollback was attempted. Inspect the auth service before retrying."
                )
            if desired != original:
                atomic_write(environment_file, original, metadata)
            recovered = (
                apply_compose(compose, runner)
                and runtime_versions(compose, runner) == original_versions
            )
            if recovered:
                raise AllowlistError(
                    "Authentication update failed; the original configuration was restored "
                    "and reapplied. The new build is not confirmed."
                )
            raise AllowlistError(
                "Authentication update failed; the original environment file was restored, "
                "but service recovery could not be verified. Inspect auth-backend before retrying."
            )
    except OSError:
        raise AllowlistError(
            "Unable to access or update the deployment files. Check permissions and auth-backend state."
        ) from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", nargs="+", help="actual distributed CFBundleVersion values")
    args = parser.parse_args(argv)
    try:
        changed = apply_build_versions(args.build)
    except AllowlistError as error:
        print(str(error), file=sys.stderr)
        return 1
    if changed:
        print("Build allowlist applied and verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
