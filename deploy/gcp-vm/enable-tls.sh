#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || -z $1 ]]; then
  echo "usage: $0 CERTIFICATE_EMAIL" >&2
  exit 64
fi
certificate_email=$1
release_directory=$(cd "$(dirname "$0")/../.." && pwd)
environment=$(sed -n 's/^NEXTSTOP_ENVIRONMENT=//p' /etc/nextstop/release.env)
case $environment in
  staging) domain=api-staging.nextstop.tech ;;
  production) domain=api.nextstop.tech ;;
  *) echo "Set NEXTSTOP_ENVIRONMENT in /etc/nextstop/release.env." >&2; exit 78 ;;
esac

install -m 644 "$release_directory/deploy/gcp-vm/nginx-request-diagnostics.conf" /etc/nginx/nextstop-request-diagnostics.conf
install -m 644 "$release_directory/deploy/gcp-vm/nginx-diagnostics.logrotate" /etc/logrotate.d/nextstop-diagnostics
install -d -m 750 -o www-data -g adm /var/log/nextstop
mkdir -p /var/www/letsencrypt
touch /var/log/nextstop/nginx-errors.jsonl
chown www-data:adm /var/log/nextstop/nginx-errors.jsonl
chmod 640 /var/log/nextstop/nginx-errors.jsonl
backup=$(mktemp)
had_site=false
if [[ -f /etc/nginx/sites-available/nextstop ]]; then
  cp /etc/nginx/sites-available/nextstop "$backup"
  had_site=true
fi
restore_config() {
  result=$?
  if [[ $result -ne 0 ]]; then
    if [[ $had_site == true ]]; then
      cp "$backup" /etc/nginx/sites-available/nextstop
    else
      rm -f /etc/nginx/sites-available/nextstop /etc/nginx/sites-enabled/nextstop
    fi
    nginx -t && systemctl reload nginx
  fi
  rm -f "$backup"
}
trap restore_config EXIT

# An existing HTTPS site already serves ACME; never downgrade it for renewal.
if [[ ! -f /etc/nginx/sites-available/nextstop ]]; then
  python3 "$release_directory/deploy/releases/render-nginx.py" --mode http
  ln -sfn /etc/nginx/sites-available/nextstop /etc/nginx/sites-enabled/nextstop
  nginx -t
  systemctl reload nginx
fi
certbot certonly --non-interactive --agree-tos --no-eff-email --email "$certificate_email" \
  --webroot --webroot-path /var/www/letsencrypt --domain "$domain"
python3 "$release_directory/deploy/releases/render-nginx.py" --mode https
ln -sfn /etc/nginx/sites-available/nextstop /etc/nginx/sites-enabled/nextstop
nginx -t
systemctl reload nginx
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
install -m 755 "$release_directory/deploy/gcp-vm/reload-nginx.sh" /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
systemctl enable --now certbot.timer
