#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 RELEASE_ARCHIVE" >&2
  exit 64
fi

archive=$1
release_id=$(date -u +%Y%m%dT%H%M%SZ)
release_directory=/opt/nextstop/releases/$release_id
environment_file=/etc/nextstop/backend.env

mkdir -p "$release_directory" /etc/nextstop /var/www/letsencrypt
tar -xzf "$archive" -C "$release_directory"

if [[ ! -f "$environment_file" ]]; then
  umask 077
  postgres_password=$(openssl rand -hex 32)
  snapshot_signing_key=$(openssl rand -hex 32)
  printf 'POSTGRES_PASSWORD=%s\nSNAPSHOT_SIGNING_KEY=%s\n' \
    "$postgres_password" "$snapshot_signing_key" > "$environment_file"
fi
chmod 600 "$environment_file"

ln -sfn "$release_directory" /opt/nextstop/current

if [[ -f /etc/letsencrypt/live/api.nextstop.tech/fullchain.pem ]]; then
  install -m 644 "$release_directory/deploy/gcp-vm/nginx-https.conf" \
    /etc/nginx/sites-available/nextstop
else
  install -m 644 "$release_directory/deploy/gcp-vm/nginx-http.conf" \
    /etc/nginx/sites-available/nextstop
fi
ln -sfn /etc/nginx/sites-available/nextstop /etc/nginx/sites-enabled/nextstop
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

cd "$release_directory"
docker compose --env-file "$environment_file" \
  -f deploy/gcp-vm/compose.yaml up -d --build --remove-orphans

find /opt/nextstop/releases -mindepth 1 -maxdepth 1 -type d \
  ! -path "$release_directory" -mtime +7 -exec rm -rf -- {} +
