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

umask 077
touch "$environment_file"
ensure_secret() {
  local name=$1
  if ! grep -q "^${name}=" "$environment_file"; then
    printf '%s=%s\n' "$name" "$(openssl rand -hex 32)" >> "$environment_file"
  fi
}
ensure_secret POSTGRES_PASSWORD
ensure_secret API_DATABASE_PASSWORD
ensure_secret WORKER_DATABASE_PASSWORD
ensure_secret SNAPSHOT_SIGNING_KEY
ensure_secret SEARCH_API_BEARER_TOKEN
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
compose=(
  docker compose
  --project-name gcp-vm
  --env-file "$environment_file"
  -f deploy/gcp-vm/compose.yaml
)

"${compose[@]}" build backend
"${compose[@]}" stop backend worker
"${compose[@]}" up -d --wait database
"${compose[@]}" run --rm --no-deps migrator
"${compose[@]}" run --rm --no-deps database-role-initializer
"${compose[@]}" run --rm --no-deps cache-initializer
"${compose[@]}" up -d --wait --wait-timeout 120 --no-deps --remove-orphans backend worker

find /opt/nextstop/releases -mindepth 1 -maxdepth 1 -type d \
  ! -path "$release_directory" -mtime +7 -exec rm -rf -- {} +
