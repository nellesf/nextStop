#!/usr/bin/env python3
"""Read Apple's available internal builds before applying any server changes."""

import json
from pathlib import Path
import re
import subprocess
import sys


def synchronize(directory: Path, run=subprocess.run) -> None:
    reader = run(
        [sys.executable, str(directory / "read-testflight-builds.py")],
        capture_output=True,
        text=True,
        timeout=150,
        check=False,
    )
    if reader.returncode != 0:
        raise RuntimeError("Apple build lookup failed; existing build permissions were preserved.")
    builds = json.loads(reader.stdout)
    if (not isinstance(builds, list) or len(builds) > 32
            or any(not isinstance(build, str)
                   or re.fullmatch(r"[A-Za-z0-9._-]{1,64}", build, re.ASCII) is None
                   for build in builds)
            or len(set(builds)) != len(builds)):
        raise RuntimeError("Apple build lookup returned an invalid build list.")
    if not builds:
        return
    applied = run(
        [sys.executable, str(directory / "allow-testflight-build.py"), "--", *builds],
        capture_output=True,
        text=True,
        timeout=330,
        check=False,
    )
    if applied.returncode != 0:
        raise RuntimeError("Build permission update failed; inspect the authentication service and retry.")
    # The updater emits only its explicit, sanitized result (never Compose output).
    if applied.stdout:
        print(applied.stdout.strip())


if __name__ == "__main__":
    try:
        synchronize(Path(__file__).resolve().parent)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        # Exceptions from the subprocess boundary can contain command/output data.
        message = str(error) if type(error) is RuntimeError else "TestFlight synchronization failed."
        print(message, file=sys.stderr)
        sys.exit(1)
