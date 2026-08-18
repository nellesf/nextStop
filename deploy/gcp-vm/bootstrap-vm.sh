#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

data_device=/dev/disk/by-id/google-nextstop-data
data_mount=/srv/nextstop

while [[ ! -e "$data_device" ]]; do
  sleep 2
done

if ! blkid "$data_device" >/dev/null 2>&1; then
  mkfs.ext4 -F "$data_device"
fi

mkdir -p "$data_mount"
data_uuid=$(blkid -s UUID -o value "$data_device")
if ! grep -q "UUID=$data_uuid" /etc/fstab; then
  printf 'UUID=%s %s ext4 defaults,nofail,discard 0 2\n' "$data_uuid" "$data_mount" >> /etc/fstab
fi
if ! mountpoint -q "$data_mount"; then
  mount "$data_mount"
fi

if [[ ! -f /var/lib/nextstop-bootstrap-complete ]]; then
  apt-get update
  apt-get install -y ca-certificates certbot curl docker.io docker-compose-v2 nginx openssl
  apt-get clean

  mkdir -p /etc/docker /opt/nextstop/releases /etc/nextstop /var/www/letsencrypt

  if [[ ! -f /etc/docker/daemon.json ]]; then
    printf '{"data-root":"%s/docker"}\n' "$data_mount" > /etc/docker/daemon.json
  fi

  touch /var/lib/nextstop-bootstrap-complete
fi

systemctl enable --now docker nginx
