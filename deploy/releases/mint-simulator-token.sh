#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 0 ]] || exit 64
# Parse only the nonsecret enum; never source the host configuration as shell code.
environment=$(sed -n 's/^NEXTSTOP_ENVIRONMENT=//p' /etc/nextstop/release.env)
[[ $environment == staging || $environment == production ]] || exit 78
exec python3 /opt/nextstop/current/deploy/releases/release.py mint-token --environment "$environment"
