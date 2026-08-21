# Google Cloud single-VM staging deployment

Status: Implemented for the owner-approved private TestFlight staging environment.

This deployment intentionally keeps the modular monolith on one Compute Engine
VM. PostgreSQL/PostGIS, a read-only search API process, an isolated App Attest
authentication process, one DML-only ingestion worker, and a release-scoped
owner/migrator run on the same VM from one artifact. It is not the production
high-availability topology.

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
generates missing `API_DATABASE_PASSWORD`, `AUTH_DATABASE_PASSWORD`, and
`WORKER_DATABASE_PASSWORD` values in `/etc/nextstop/backend.env`. It also generates
the independent `SNAPSHOT_SIGNING_KEY`, `SEARCH_ACCESS_TOKEN_SIGNING_KEY`, and
transitional `SEARCH_API_BEARER_TOKEN` when absent. The one-shot migrator applies
pending migrations with the legacy `nextstop_app` owner. A second one-shot service
then creates or updates the restricted roles and grants before the search API,
authentication service, and worker start.

`nextstop_api` remains read-only and cannot access authentication tables.
`nextstop_auth` uses a separate four-connection pool and can select, insert,
update, and delete only `nextstop.app_attest_keys` and
`nextstop.app_attest_challenges`; it cannot read search projections or create
schema objects. `nextstop_worker` cannot access the App Attest tables. The
migrator remains the only schema owner.

The `backend` container listens on VM loopback port `3000` and holds only the
read-only projection connection. The separate `auth-backend` container listens on
VM loopback port `3001` and holds only the `nextstop_auth` connection. Nginx sends
exactly `/v1/auth/app-attest/*` to `3001`, sends health and candidate search to
`3000`, and exposes neither container port directly to the internet.

The App Attest migration and role initialization are in-place. They do not
recreate the database, select a new active version, invalidate either active
projection, or require a charging/restaurant projection rebuild. The worker's
normal refresh schedule continues independently after restart.

## App Attest activation and staged rollout

The public authentication contract is:

- `POST /v1/auth/app-attest/challenge`: bind 32 random client-data bytes to one
  key and `attestation` or `assertion` purpose; consume within three minutes;
- `POST /v1/auth/app-attest/attest`: register a verified physical-device key and
  return a 15-minute search bearer;
- `POST /v1/auth/app-attest/assert`: advance the registered key's assertion
  counter and return another 15-minute search bearer;
- `POST /v1/charging-parks/search`: accept that short-lived bearer in
  `Authorization`; and
- `GET /health`: remain public.

The exact JSON schemas, size limits, and error responses are in
[`docs/api/openapi.yaml`](../../docs/api/openapi.yaml).

The public gateway shares a `12 requests/minute/client IP` limit with burst four
across all three App Attest paths. Independently, the isolated auth process caps
challenge creation at 120/minute globally, proof exchanges at 60/minute globally,
and cryptographic proof work at two concurrent operations. Rate and capacity
rejections return `429` with `Retry-After: 60`.

Authentication activation is currently blocked on an external Apple Developer
value. Enable App Attest for `de.nextstop.app`, refresh the provisioning profiles,
and obtain the exact App ID prefix. Do not assume it equals the Team ID. Then edit
the mode-`0600` environment file through IAP:

```bash
sudoedit /etc/nextstop/backend.env
```

Set these values without committing or printing their secrets:

```text
APP_ATTEST_APP_ID=<exact App ID prefix>.de.nextstop.app
APP_ATTEST_ALLOW_DEVELOPMENT=true
APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS=1
ALLOW_LEGACY_STAGING_BEARER=true
```

`APP_ATTEST_ALLOW_DEVELOPMENT=true` is only for the bounded
development-provisioned physical-device test. It permits Apple's current sandbox
AAGUID as well as the legacy development AAGUID used by supported older iOS
versions. TestFlight/App Store uses production attestations. Once the App Attest
TestFlight build has passed, set `APP_ATTEST_ALLOW_DEVELOPMENT=false` and
`ALLOW_LEGACY_STAGING_BEARER=false`, then redeploy. The legacy flag is the only
switch that permits the old `SEARCH_API_BEARER_TOKEN`; it exists solely so already
installed private staging builds survive this transition. New builds contain no
shared bearer, and rotating either server signing key never requires an app
rebuild. Disabling the development environment rejects both new development
attestations and assertions from development keys that were registered earlier;
production keys remain valid.

`APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS` is a comma-separated allowlist without
whitespace (at most 32 unique values, each 1–64 characters from
`A-Z`, `a-z`, `0-9`, `.`, `_`, or `-`). The installer initializes it to the
current `CFBundleVersion` `1`; add a new build number before distributing that
build and retain supported older values during rollout. For iOS 27 proofs, Apple
validation category and bundle version must occur as a pair. Development keys
accept category `3`, while production keys accept category `2` (TestFlight) or
`4` (App Store); the bundle version must also be allowlisted. The auth service
checks both values on every proof but does not require equality with the initial
attestation, so legitimate allowlisted updates can retain their key. Missing
extensions are accepted only as the legacy pre-iOS-27 proof shape; partial or
unknown extensions fail closed.

Until `APP_ATTEST_APP_ID` is configured, the three App Attest endpoints return
`503` and signed-token search remains available only to the Debug Simulator broker
described below. The explicitly enabled legacy bearer may continue serving old
private builds during that interval.

## Debug Simulator broker

Apple App Attest is unavailable in the iOS Simulator. On the developer Mac,
authenticate `gcloud` with an identity authorized for IAP/SSH and keep this helper
running:

```bash
gcloud auth login
ios/start-simulator-auth-broker.sh
```

The helper binds only to `127.0.0.1:9482`, reaches `nextstop-backend` through
`gcloud compute ssh --tunnel-through-iap`, and invokes the dedicated one-shot
`simulator-token-mint` service inside the existing deployment. That service receives
only `SEARCH_ACCESS_TOKEN_SIGNING_KEY`, has no container network, uses a read-only
filesystem, drops Linux capabilities, and disables persistent container logging. It
serves the resulting 15-minute credential only to the Debug Simulator's guarded
`POST /token` request, caches it in memory, and refreshes one minute before expiry.
No static token, signing key, or manual secret is placed in Xcode or the iOS process.
Release builds do not compile this fallback. Local broker mode is documented in
[`docs/development.md`](../../docs/development.md).

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
  -f deploy/gcp-vm/compose.yaml logs --tail=200 backend auth-backend worker

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
  -f deploy/gcp-vm/compose.yaml exec -T auth-backend node -e \
  "import('pg').then(async({Client})=>{const c=new Client({connectionString:process.env.AUTH_DATABASE_URL});await c.connect();console.log((await c.query('select current_user')).rows,(await c.query('show statement_timeout')).rows);await c.end()})"
sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
  -f deploy/gcp-vm/compose.yaml exec -T worker node -e \
  "import('pg').then(async({Client})=>{const c=new Client({connectionString:process.env.DATABASE_URL});await c.connect();console.log((await c.query('select current_user')).rows);await c.end()})"
```
