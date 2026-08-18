#!/usr/bin/env bash
set -euo pipefail

project_id=${PROJECT_ID:-nextstop-tech-staging}
region=${REGION:-europe-west3}
zone=${ZONE:-europe-west3-a}
network=nextstop-vpc
subnet=nextstop-frankfurt
instance=nextstop-backend
address=nextstop-staging-ip
data_disk=nextstop-data

gcloud config set project "$project_id"
gcloud services enable compute.googleapis.com iap.googleapis.com

active_account=$(gcloud config get-value account)
gcloud projects add-iam-policy-binding "$project_id" \
  --member="user:$active_account" --role=roles/compute.osAdminLogin \
  --condition=None >/dev/null
gcloud projects add-iam-policy-binding "$project_id" \
  --member="user:$active_account" --role=roles/iap.tunnelResourceAccessor \
  --condition=None >/dev/null

if ! gcloud compute networks describe "$network" >/dev/null 2>&1; then
  gcloud compute networks create "$network" --subnet-mode=custom
fi
if ! gcloud compute networks subnets describe "$subnet" --region="$region" >/dev/null 2>&1; then
  gcloud compute networks subnets create "$subnet" \
    --network="$network" --region="$region" --range=10.20.0.0/24
fi

if ! gcloud compute firewall-rules describe nextstop-allow-web >/dev/null 2>&1; then
  gcloud compute firewall-rules create nextstop-allow-web \
    --network="$network" --allow=tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 --target-tags=nextstop-api
fi
if ! gcloud compute firewall-rules describe nextstop-allow-iap-ssh >/dev/null 2>&1; then
  gcloud compute firewall-rules create nextstop-allow-iap-ssh \
    --network="$network" --allow=tcp:22 \
    --source-ranges=35.235.240.0/20 --target-tags=nextstop-api
fi

if ! gcloud compute addresses describe "$address" --region="$region" >/dev/null 2>&1; then
  gcloud compute addresses create "$address" --region="$region" --network-tier=PREMIUM
fi
external_ip=$(gcloud compute addresses describe "$address" \
  --region="$region" --format='value(address)')

if ! gcloud compute disks describe "$data_disk" --zone="$zone" >/dev/null 2>&1; then
  gcloud compute disks create "$data_disk" \
    --zone="$zone" --type=pd-balanced --size=150GB
fi

if ! gcloud compute instances describe "$instance" --zone="$zone" >/dev/null 2>&1; then
  gcloud compute instances create "$instance" \
    --zone="$zone" \
    --machine-type=e2-standard-2 \
    --network="$network" \
    --subnet="$subnet" \
    --address="$external_ip" \
    --network-tier=PREMIUM \
    --tags=nextstop-api \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=30GB \
    --boot-disk-type=pd-balanced \
    --disk=name="$data_disk",device-name=nextstop-data,mode=rw,boot=no,auto-delete=no \
    --metadata=enable-oslogin=TRUE \
    --metadata-from-file=startup-script=deploy/gcp-vm/bootstrap-vm.sh \
    --no-service-account \
    --no-scopes \
    --deletion-protection
fi

gcloud compute instances add-metadata "$instance" \
  --zone="$zone" \
  --metadata=enable-oslogin=TRUE \
  --metadata-from-file=startup-script=deploy/gcp-vm/bootstrap-vm.sh >/dev/null

printf '%s\n' "$external_ip"
