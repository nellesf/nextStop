#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 RELEASE_ARCHIVE [deploy|migrate|rollback] --environment ENV --image IMAGE@sha256:DIGEST ..." >&2
  exit 64
fi
archive=$1
shift
action=deploy
if [[ ${1:-} == deploy || ${1:-} == migrate || ${1:-} == rollback || ${1:-} == verify-public ]]; then
  action=$1
  shift
fi
[[ -f /etc/nextstop/backend.env && -f /etc/nextstop/release.env ]] || {
  echo "Provision environment-specific host configuration and secrets first." >&2
  exit 78
}
umask 077
chmod 600 /etc/nextstop/backend.env
mkdir -p /opt/nextstop/releases /var/lib/nextstop/releases /var/www/letsencrypt
release_directory=$(mktemp -d /opt/nextstop/releases/release.XXXXXXXX)
# Deployment archives contain only vetted deployment tooling, never source code,
# .env files, node_modules, or build output. Reject path traversal/link members.
python3 - "$archive" "$release_directory" <<'PY'
from pathlib import Path
import sys, tarfile
archive, destination = sys.argv[1:]
with tarfile.open(archive) as bundle:
    for member in bundle.getmembers():
        parts = Path(member.name).parts
        if member.issym() or member.islnk() or member.name.startswith('/') or '..' in parts:
            raise SystemExit('Invalid release archive member.')
        if not member.isfile() and not member.isdir():
            raise SystemExit('Unsupported release archive member.')
        if not (member.name.startswith('deploy/gcp-vm/') or member.name.startswith('deploy/releases/')
                or member.name in ('deploy', 'deploy/gcp-vm', 'deploy/releases')):
            raise SystemExit('Unexpected release archive scope.')
    bundle.extractall(destination)
PY

# Include/log files contain no upstream selection and preserve the diagnostic
# redaction contract. Serving Nginx is reloaded only by the gated release runner.
if [[ -d /etc/nginx ]]; then
  install -m 644 "$release_directory/deploy/gcp-vm/nginx-request-diagnostics.conf" /etc/nginx/nextstop-request-diagnostics.conf
  install -m 644 "$release_directory/deploy/gcp-vm/nginx-diagnostics.logrotate" /etc/logrotate.d/nextstop-diagnostics
  install -d -m 750 -o www-data -g adm /var/log/nextstop
  touch /var/log/nextstop/nginx-errors.jsonl
  chown www-data:adm /var/log/nextstop/nginx-errors.jsonl
  chmod 640 /var/log/nextstop/nginx-errors.jsonl
fi
python3 "$release_directory/deploy/releases/release.py" "$action" --root "$release_directory" "$@"
if [[ $action == deploy ]]; then
  ln -sfn "$release_directory" /opt/nextstop/current
  install -m 755 "$release_directory/deploy/releases/mint-simulator-token.sh" /usr/local/sbin/nextstop-mint-simulator-token
fi
