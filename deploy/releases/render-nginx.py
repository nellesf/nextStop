#!/usr/bin/env python3
"""Render a checked-in Nginx template without evaluating host configuration."""
import argparse
import json
from pathlib import Path

from release import DOMAINS, ReleaseError, atomic_write, load_env, render_nginx


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["http", "https"], required=True)
    parser.add_argument("--host-config", default="/etc/nextstop/release.env")
    parser.add_argument("--state", default="/var/lib/nextstop/releases/state.json")
    parser.add_argument("--output", default="/etc/nginx/sites-available/nextstop")
    args = parser.parse_args()
    config = load_env(Path(args.host_config))
    environment = config.get("NEXTSTOP_ENVIRONMENT")
    if environment not in DOMAINS or config.get("DOMAIN", DOMAINS[environment]) != DOMAINS[environment]:
        raise ReleaseError("Invalid environment/domain configuration.")
    output = Path(args.output)
    if args.mode == "http" and output.exists() and "listen 443 ssl" in output.read_text():
        raise ReleaseError("HTTP bootstrap cannot replace a serving TLS configuration.")
    state = json.loads(Path(args.state).read_text()) if Path(args.state).exists() else {}
    slot = state.get("api", {}).get("slot", "legacy")
    template = Path(__file__).resolve().parents[1] / f"gcp-vm/nginx-{args.mode}.conf"
    content = render_nginx(template.read_text(), DOMAINS[environment], slot)
    atomic_write(output, content, 0o644)


if __name__ == "__main__":
    main()
