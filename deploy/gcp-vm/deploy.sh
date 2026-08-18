#!/usr/bin/env bash
set -euo pipefail

project_id=${PROJECT_ID:-nextstop-tech-staging}
zone=${ZONE:-europe-west3-a}
instance=nextstop-backend
repository_root=$(cd "$(dirname "$0")/../.." && pwd)
temporary_directory=$(mktemp -d)
archive=$temporary_directory/nextstop-release.tar.gz
trap 'rm -rf "$temporary_directory"' EXIT

tar -C "$repository_root" -czf "$archive" \
  --exclude=.git \
  --exclude='*/node_modules' \
  --exclude='*/dist' \
  --exclude='*/.env' \
  backend deploy/gcp-vm

gcloud compute scp "$archive" "$instance:/tmp/nextstop-release.tar.gz" \
  --project="$project_id" --zone="$zone" --tunnel-through-iap
gcloud compute ssh "$instance" \
  --project="$project_id" --zone="$zone" --tunnel-through-iap \
  --command='while [[ ! -f /var/lib/nextstop-bootstrap-complete ]]; do sleep 5; done; staging_directory=$(mktemp -d /tmp/nextstop-installer.XXXXXX); tar -xzf /tmp/nextstop-release.tar.gz -C "$staging_directory"; sudo "$staging_directory/deploy/gcp-vm/install-release.sh" /tmp/nextstop-release.tar.gz; rm -rf "$staging_directory" /tmp/nextstop-release.tar.gz'
