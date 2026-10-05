#!/usr/bin/env python3
"""Enable demand-driven ingestion only on the verified staging host; no resource changes."""
from __future__ import annotations

import argparse
from pathlib import Path
import secrets

from release import ReleaseError, atomic_write, load_env


def configure(host: Path, private: Path, *, enabled: bool) -> None:
    config = load_env(host)
    if (config.get("NEXTSTOP_ENVIRONMENT") != "staging"
            or config.get("DOMAIN") != "api-staging.nextstop.tech"):
        raise ReleaseError("Demand-ingestion activation is restricted to the staging host.")
    values = load_env(private)
    token = values.get("LIVE_REFRESH_TOKEN")
    if enabled:
        if token is None:
            # Private Docker signal only, independent of app authentication keys.
            values["LIVE_REFRESH_TOKEN"] = secrets.token_hex(32)
        elif len(token.encode()) < 32:
            raise ReleaseError("Existing private refresh credential is invalid.")
    config.update(
        INGESTION_SCHEDULE="monthly" if enabled else "daily",
        DEMAND_LIVE_AVAILABILITY_ENABLED="true" if enabled else "false",
        LIVE_REFRESH_URL="http://worker:8091/refresh" if enabled else "",
    )
    # Keys and values are parsed with the existing strict host-env grammar.
    # Write secrets first so an interrupted activation cannot enable an absent key.
    atomic_write(private, "".join(f"{key}={value}\n" for key, value in values.items()), 0o600)
    atomic_write(host, "".join(f"{key}={value}\n" for key, value in config.items()), 0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-config", type=Path, default=Path("/etc/nextstop/release.env"))
    parser.add_argument("--secrets", type=Path, default=Path("/etc/nextstop/backend.env"))
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--enable", action="store_true")
    action.add_argument("--disable", action="store_true")
    args = parser.parse_args()
    configure(args.host_config, args.secrets, enabled=args.enable)
    print("Staging ingestion configuration saved; applies with the next gated release.")


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError):
        raise SystemExit("Staging ingestion configuration was not activated.") from None
