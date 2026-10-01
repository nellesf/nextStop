#!/usr/bin/env bash
set -euo pipefail
# Production already exists. This command provisions only the isolated staging VM.
[[ ${1:-} == --environment && ${2:-} == staging && $# == 2 ]] || {
  echo "usage: $0 --environment staging" >&2
  exit 64
}
root=$(cd "$(dirname "$0")/../.." && pwd)
project_id=nextstop-tech-testing
region=europe-west3
zone=europe-west3-a
network=nextstop-vpc
subnet=nextstop-frankfurt
instance=nextstop-backend
address=nextstop-staging-ip
data_disk=nextstop-data
cloud() { gcloud "$@" --project="$project_id" --quiet; }

cloud services enable compute.googleapis.com iap.googleapis.com oslogin.googleapis.com
active_account=$(gcloud config get-value account)
cloud projects add-iam-policy-binding "$project_id" --member="user:$active_account" --role=roles/compute.osAdminLogin --condition=None >/dev/null
cloud projects add-iam-policy-binding "$project_id" --member="user:$active_account" --role=roles/iap.tunnelResourceAccessor --condition=None >/dev/null

if ! cloud compute networks describe "$network" >/dev/null 2>&1; then
  cloud compute networks create "$network" --subnet-mode=custom
fi
if ! cloud compute networks subnets describe "$subnet" --region="$region" >/dev/null 2>&1; then
  cloud compute networks subnets create "$subnet" --network="$network" --region="$region" --range=10.30.0.0/24
fi
if ! cloud compute firewall-rules describe nextstop-allow-web >/dev/null 2>&1; then
  cloud compute firewall-rules create nextstop-allow-web --network="$network" --allow=tcp:80,tcp:443 --source-ranges=0.0.0.0/0 --target-tags=nextstop-api
fi
if ! cloud compute firewall-rules describe nextstop-allow-iap-ssh >/dev/null 2>&1; then
  cloud compute firewall-rules create nextstop-allow-iap-ssh --network="$network" --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=nextstop-api
fi
if ! cloud compute addresses describe "$address" --region="$region" >/dev/null 2>&1; then
  cloud compute addresses create "$address" --region="$region" --network-tier=PREMIUM
fi
external_ip=$(cloud compute addresses describe "$address" --region="$region" --format='value(address)')
if ! cloud compute disks describe "$data_disk" --zone="$zone" >/dev/null 2>&1; then
  cloud compute disks create "$data_disk" --zone="$zone" --type=pd-balanced --size=150GB
fi
if ! cloud compute instances describe "$instance" --zone="$zone" >/dev/null 2>&1; then
  cloud compute instances create "$instance" --zone="$zone" --machine-type=e2-standard-2 \
    --network="$network" --subnet="$subnet" --address="$external_ip" --network-tier=PREMIUM \
    --tags=nextstop-api --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
    --boot-disk-size=30GB --boot-disk-type=pd-balanced \
    --disk=name="$data_disk",device-name=nextstop-data,mode=rw,boot=no,auto-delete=no \
    --metadata=enable-oslogin=TRUE --metadata-from-file=startup-script="$root/deploy/gcp-vm/bootstrap-vm.sh" \
    --no-service-account --no-scopes --deletion-protection \
    --labels=application=nextstop,environment=staging
fi
printf '%s\n' "$external_ip"
