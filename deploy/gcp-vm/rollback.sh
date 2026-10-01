#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && ( $1 == staging || $1 == production ) ]] || {
  echo "usage: $0 staging|production" >&2
  exit 64
}
exec python3 /opt/nextstop/current/deploy/releases/release.py rollback --environment "$1"
