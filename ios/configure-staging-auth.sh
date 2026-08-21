#!/usr/bin/env bash
set -euo pipefail

project_id=${PROJECT_ID:-nextstop-tech-staging}
zone=${ZONE:-europe-west3-a}
instance=${INSTANCE:-nextstop-backend}
repository_root=$(cd "$(dirname "$0")/.." && pwd)
configuration_file="$repository_root/ios/Config/Secrets.xcconfig"

token=$(
  gcloud compute ssh "$instance" \
    --project="$project_id" \
    --zone="$zone" \
    --tunnel-through-iap \
    --command="sudo sed -n 's/^SEARCH_API_BEARER_TOKEN=//p' /etc/nextstop/backend.env"
)

if [[ ! $token =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "The staging VM did not return one valid 64-character search token." >&2
  exit 1
fi

umask 077
printf 'NEXTSTOP_API_BEARER_TOKEN = %s\n' "$token" > "$configuration_file"
chmod 600 "$configuration_file"
echo "Configured the ignored iOS staging credential at ios/Config/Secrets.xcconfig."
