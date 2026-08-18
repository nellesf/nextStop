#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "usage: $0 CERTIFICATE_EMAIL" >&2
  exit 64
fi

certificate_email=$1
release_directory=$(readlink -f /opt/nextstop/current)

certbot certonly \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --email "$certificate_email" \
  --webroot \
  --webroot-path /var/www/letsencrypt \
  --domain api.nextstop.tech

install -m 644 "$release_directory/deploy/gcp-vm/nginx-https.conf" \
  /etc/nginx/sites-available/nextstop
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
install -m 755 "$release_directory/deploy/gcp-vm/reload-nginx.sh" \
  /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
nginx -t
systemctl reload nginx
systemctl enable --now certbot.timer
