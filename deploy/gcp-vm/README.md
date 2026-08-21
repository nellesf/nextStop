# Google Cloud single-VM staging deployment

Status: Implemented for the owner-approved private TestFlight staging environment.

This deployment intentionally keeps the modular monolith on one Compute Engine
VM. PostgreSQL/PostGIS, a read-only API process, one DML-only ingestion worker,
and a release-scoped owner/migrator run on the same VM from one artifact. It is not
the production high-availability topology.

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

On every release, the installer preserves the existing `POSTGRES_PASSWORD` and
generates missing `API_DATABASE_PASSWORD` and `WORKER_DATABASE_PASSWORD` values in
`/etc/nextstop/backend.env`, along with a missing `SEARCH_API_BEARER_TOKEN`. Only
the HTTP API receives the search token. The one-shot migrator applies pending
migrations with the legacy `nextstop_app` owner. A second one-shot service then
creates or updates the restricted roles and grants before the API and worker
start. This is an in-place privilege upgrade: it neither recreates the database
nor rebuilds the active charging or restaurant projections.

After the first authenticated-search deployment, configure the same secret for
the private iOS build without printing or committing it, then rebuild the app:

```bash
ios/configure-staging-auth.sh
```

The script retrieves the value through IAP into the ignored, mode-`0600` file
`ios/Config/Secrets.xcconfig`. Builds without a valid credential fail closed and
Release/archive builds are rejected before compilation when it is absent. Older
installed builds receive `401`. Rotating the staging token therefore requires
rebuilding and redistributing the private app. No database or projection rebuild
is involved.

## Operations

```bash
gcloud compute ssh nextstop-backend \
  --project=nextstop-tech-staging \
  --zone=europe-west3-a \
  --tunnel-through-iap

cd /opt/nextstop/current
sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml ps
sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml logs --tail=200 backend worker

sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T database \
  psql -U nextstop_app -d nextstop -c \
  'SELECT status, charging_point_count, park_count, published_at FROM nextstop.projection_versions ORDER BY built_at DESC LIMIT 3;'

sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T database \
  psql -U nextstop_app -d nextstop -c \
  'SELECT status, poi_count, quarantine_count, published_at FROM nextstop.food_poi_projection_versions ORDER BY built_at DESC LIMIT 3;'
```

`GET /health` confirms process liveness. A food-filtered search remains retryable
until the first Germany and Switzerland OSM import has published successfully.

To verify the effective database boundaries without printing credentials:

```bash
sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T backend node -e \
  "import('pg').then(async({Client})=>{const c=new Client({connectionString:process.env.DATABASE_URL});await c.connect();console.log((await c.query('select current_user')).rows,(await c.query('show statement_timeout')).rows);await c.end()})"
sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T worker node -e \
  "import('pg').then(async({Client})=>{const c=new Client({connectionString:process.env.DATABASE_URL});await c.connect();console.log((await c.query('select current_user')).rows);await c.end()})"
```
