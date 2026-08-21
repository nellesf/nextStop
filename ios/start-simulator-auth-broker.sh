#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

broker_mode="${NEXTSTOP_SIMULATOR_AUTH_MODE:-staging}"

if [[ "$broker_mode" == "staging" ]] && ! command -v gcloud >/dev/null 2>&1; then
  printf '%s\n' \
    'Google Cloud CLI is required. Install it and run `gcloud auth login` first.' >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'Node.js is required to run the local Simulator authentication broker.' >&2
  exit 1
fi

exec node "$script_directory/SimulatorAuthBroker/server.mjs"
