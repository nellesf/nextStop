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

bootstrap_required=false
if [[ ! -f /var/lib/nextstop-bootstrap-complete ]]; then
  # An incomplete bootstrap must not adopt or move an existing Docker store.
  if [[ -d /var/lib/docker ]]; then
    existing_docker_entry=$(find /var/lib/docker -mindepth 1 -maxdepth 1 -print -quit)
    if [[ -n "$existing_docker_entry" ]]; then
      echo 'Existing Docker data requires manual recovery before initial bootstrap.' >&2
      exit 1
    fi
  fi

  docker_configuration=$(printf '{"data-root":"%s/docker"}\n' "$data_mount")
  if [[ -e /etc/docker/daemon.json ]] &&
    ! cmp -s /etc/docker/daemon.json <(printf '%s\n' "$docker_configuration"); then
    echo 'Existing Docker configuration requires manual review before initial bootstrap.' >&2
    exit 1
  fi

  mkdir -p /etc/docker /opt/nextstop/releases /etc/nextstop /var/www/letsencrypt
  mkdir -p /etc/systemd/system/docker.service.d

  if [[ ! -e /etc/docker/daemon.json ]]; then
    printf '%s\n' "$docker_configuration" > /etc/docker/daemon.json
  fi
  # docker.io may start its daemon from the package installation hooks.
  # Prepare both the root and mount dependency before that first start.
  cat > /etc/systemd/system/docker.service.d/10-nextstop-data-root.conf <<EOF
[Unit]
RequiresMountsFor=$data_mount

[Service]
ExecStartPre=/usr/bin/mountpoint -q $data_mount
EOF
  systemctl daemon-reload

  apt-get update
  apt-get install -y ca-certificates certbot curl docker.io docker-compose-v2 logrotate nginx openssl python3
  apt-get clean
  bootstrap_required=true
fi

systemctl enable --now docker nginx

if [[ "$bootstrap_required" == true ]]; then
  if [[ $(docker info --format '{{.DockerRootDir}}') != "$data_mount/docker" ]]; then
    echo 'Docker is not using the mounted data disk; initial bootstrap remains incomplete.' >&2
    exit 1
  fi
  touch /var/lib/nextstop-bootstrap-complete
fi
