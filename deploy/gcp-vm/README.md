# Google Cloud single-VM staging deployment

Status: Implemented for the owner-approved private TestFlight staging environment.

This deployment intentionally mirrors the local modular monolith on one Compute
Engine VM. PostgreSQL/PostGIS, the API, authority ingestion, Swiss live ingestion,
and the single OSM worker run together. It is not the production high-availability
topology.

## Fixed resources

- Project: `nextstop-tech-staging`
- Region/zone: `europe-west3` / `europe-west3-a`
- VM: `nextstop-backend`, `e2-standard-2`, Ubuntu 24.04 LTS
- Boot disk: 30 GB balanced persistent disk
- Data disk: 150 GB balanced persistent disk, retained when the VM is deleted
- Endpoint: `https://api.nextstop.tech`
- Monthly budget: EUR 100 across the complete project, excluding credits from
  spend calculation, with alerts at 50%, 80%, 100%, and forecasted 100%

The VM has no Google Cloud service account. PostgreSQL is reachable only from the
private Docker network, the backend listens only on VM loopback, and Nginx exposes
ports 80/443. SSH is allowed only through Google IAP.

The owner explicitly declined scheduled backups for this staging deployment. A
disk failure therefore requires rebuilding public source projections. Local iOS
profiles and destination history are not stored by this backend.

The billing budget is an alert, not an automatic spending cap. Default billing
recipients receive its notifications; no automatic shutdown is configured.

## Provision and deploy

Authenticate with Google Cloud CLI, then run from the repository root:

```bash
deploy/gcp-vm/provision.sh
deploy/gcp-vm/deploy.sh
```

The provisioning command is idempotent and prints the reserved IPv4 address. Add
an IONOS `A` record for `api.nextstop.tech` pointing to that address. After DNS
resolves publicly, enable TLS on the VM:

```bash
gcloud compute ssh nextstop-backend \
  --project=nextstop-tech-staging \
  --zone=europe-west3-a \
  --tunnel-through-iap \
  --command='sudo /opt/nextstop/current/deploy/gcp-vm/enable-tls.sh CERTIFICATE_EMAIL'
```

Certbot renews the certificate automatically. The checked-in Nginx configuration
does not record route request bodies or client access logs. Backend output contains
only ingestion event names, outcomes or failure classes, and timestamps.

## Operations

```bash
gcloud compute ssh nextstop-backend \
  --project=nextstop-tech-staging \
  --zone=europe-west3-a \
  --tunnel-through-iap

cd /opt/nextstop/current
sudo docker compose --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml ps
sudo docker compose --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml logs --tail=200 backend

sudo docker compose --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T database \
  psql -U nextstop_app -d nextstop -c \
  'SELECT status, charging_point_count, park_count, published_at FROM nextstop.projection_versions ORDER BY built_at DESC LIMIT 3;'

sudo docker compose --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T database \
  psql -U nextstop_app -d nextstop -c \
  'SELECT status, poi_count, quarantine_count, published_at FROM nextstop.food_poi_projection_versions ORDER BY built_at DESC LIMIT 3;'
```

`GET /health` confirms process liveness. A food-filtered search remains retryable
until the first Germany and Switzerland OSM import has published successfully.
