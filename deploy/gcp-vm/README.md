# Staging and production releases

The owner selected one VM per environment, each with its own local
PostgreSQL/PostGIS, API, auth process and ingestion worker. Production keeps the
existing VM, database, credentials and public origin. Staging receives a separate
VM and database for testing. This adds environment isolation and safer releases;
it does not change the existing outage or failover model.

Status on 2026-10-01: the separate staging VM and database are provisioned;
the public-data seed, database statistics and public DNS/TLS are verified.
Staging API/auth/worker startup, a controlled activation rejection and rollback
in both directions passed live checks with 146 successful synthetic search
samples. These are sampled availability checks, not a continuous-availability
guarantee; see the [verification record](../../docs/operations/staging-release-verification-2026-10-01.md)
for latency and limitations. The real production backup and isolated native
restore passed: a 2.361 GiB archive, 251 seconds of restore/checks, successful
migration/readiness/search gates and removal of private local copies. Production
PostgreSQL 17.5/PostGIS 3.5.2 was restored into native PostgreSQL 17.11/PostGIS
3.5.6, not an identical Linux environment. All 21 accompanying production search
samples returned HTTP 200 at one-minute intervals.
The first direct staging CI deployment, run `36858146070` attempt 2, failed early
at 12:00 UTC before any SSH operation was observed. Automatic releases are
**disabled again**. The stale gcloud builder-account selection was identified;
a second SDK setup and identity guard are implemented, with `actionlint` passing.
Their live CI validation remains pending. Production remains on
its legacy deployment; first adoption and protected owner review still precede
the first production release. The full iOS CI runs for `6c33d4b` and the later
`e106f2e` passed without an app change. See the exact
[activation status](../gcp/README.md) and
[ADR 0018](../../docs/adr/0018-staging-production-releases.md).

| Environment | Project | VM | Public domain |
| --- | --- | --- | --- |
| Production (existing) | `nextstop-tech-staging` | `nextstop-backend` | `api.nextstop.tech` |
| Staging (new) | `nextstop-tech-testing` | `nextstop-backend` | `api-staging.nextstop.tech` |

The legacy production project ID intentionally stays unchanged; its display name
is `NextStop Production`. Both VMs use
zone `europe-west3-a` and Compose project `gcp-vm`. PostgreSQL stays on the private
Docker network. SSH uses Google IAP; Nginx terminates HTTPS on each VM.

## Release contract

CI builds one image outside the serving VM and selects an immutable
`repository@sha256:digest`. [Environment files](../environments/) bind the target,
registry and domain. The normal deployment cannot override that mapping.
Production promotion uses the identical digest that passed staging tests.

On one host, under one release lock, the runner:

1. Pulls the pinned image. Production requires a successful recent backup receipt
   for this exact VM, project and image before migration. An existing database
   container is reused with `--no-recreate`; releases never upgrade or restart it.
2. Applies only reviewed additive migrations with `--expand-only`, serialized
   execution, a 500 ms lock timeout and finite statement budgets. Role
   initialization runs in one transaction using the existing credentials.
3. Starts candidate API and auth processes in the inactive slot. Both `/ready`
   responses must identify the expected digest. An authenticated synthetic search
   must return candidates and a snapshot token.
4. Validates and gracefully reloads Nginx, then checks both services and search
   through local HTTPS and the public domain. Existing requests have 65 seconds
   to drain; the prior API/auth remain running for rollback.
5. Stops the old worker and waits for its container to exit before starting the
   replacement. Worker replacement occurs only after serving gates pass.

The API is not stopped to build or validate a candidate. HTTP processes have a
30-second shutdown grace; Compose allows 45 seconds. The two temporary API slots
share the same VM and database and do not provide protection against a VM or
database failure.

Failure restores the prior Nginx configuration and any replaced worker. If a
failed candidate overwrote the inactive rollback slot, its previous image is
recreated and verified. The mode-0600 state/journal at
`/var/lib/nextstop/releases/state.json` is cleared only after recovery succeeds.
Application rollback never reverses DDL or restores a database over current data.

## Host configuration and first activation

Provision root-owned `/etc/nextstop/release.env` for public settings and preserve
`/etc/nextstop/backend.env` with mode 0600 for secrets. Files are parsed without
shell evaluation. The installer does not generate or rotate credentials.
Example for the existing production VM:

```text
NEXTSTOP_ENVIRONMENT=production
DOMAIN=api.nextstop.tech
PROJECT_ID=nextstop-tech-staging
DATABASE_INSTANCE=nextstop-backend
DATABASE_MODE=local
DATABASE_HOST=database
DATABASE_PORT=5432
DATABASE_OWNER=nextstop_app
COMPOSE_PROJECT_NAME=gcp-vm
```

Staging uses `NEXTSTOP_ENVIRONMENT=staging`, project `nextstop-tech-testing` and
its own domain. Keep `COMPOSE_PROJECT_NAME=gcp-vm` to preserve the existing
production database and provider-cache volumes. Legacy API/auth ports 3000/3001
stay serving while the initial slot is checked. New slots bind only loopback
3100/3101 and 3200/3201. Unknown existing proxy configurations fail closed.
`compose.yaml` remains only for explicit legacy compatibility; new releases use
`compose.release.yaml`. Never run `compose down` as a release step.

The host requires the existing owner, API, auth, support and worker passwords,
plus snapshot/search signing keys and valid App Attest configuration. Container
credentials stay scoped to their service. Each environment has independent
credentials, signing keys, auth records, support records and caches. Staging must
not copy production authentication or private report data. Signing-key/password
rotation needs a separate overlapping-version plan.

The existing production legacy bearer compatibility flag stays operator-managed
under ADR 0015; separating environments does not revoke installed clients.
Production continues to reject development App Attest. New staging starts with
both compatibility flags false and never receives the production legacy key.

A fresh staging database needs a separate isolated full-schema bootstrap and
initial published charging and food imports. The rolling `--expand-only` path
deliberately refuses legacy/unclassified migrations. Search and auth readiness
must pass before exposing that instance; do not weaken the gates for an empty or
unconfigured database.

For the initial public-data seed, run `python3 deploy/gcp/seed-staging.py` from a
trusted operator machine. It accepts only the configured existing production and
new staging VMs, creates independent staging secrets, and refuses to overwrite an
existing staging schema. The source inventory must exactly match the reviewed
public/private table list; unknown tables fail closed. Auth keys, auth challenges
and support-report rows are excluded before export. SHA-256 verifies transfers;
the restore is transactional, then private-table emptiness, active public counts
and planner statistics are checked. Only PostgreSQL starts. Temporary dump copies
are removed after successful validation; failures retain them for verified
recovery. Production services remain running throughout the snapshot.

Production keeps its existing certificate and DNS. Provision staging DNS and its
matching certificate before activating its first release. Run the environment-
aware `enable-tls.sh CERTIFICATE_EMAIL` from installed deployment tooling. It uses
ACME and restores the previous proxy configuration on failure. Certificate renewal
reloads Nginx gracefully.

No serving VM service-account change is required. The deployer obtains a
short-lived registry access token and sends it only through SSH stdin to
`docker login --password-stdin`. Docker uses a mode-0700 root-owned directory
under `/run/nextstop-registry-<UUID>`, removed after success or failure. The token
never appears in command arguments or deployment logs. If host connectivity
prevents cleanup, remove that exact temporary directory through IAP before the
next release. Manual rollback uses retained local images.

## Backup, deploy and rollback

Before production migration, the backup helper creates a PostgreSQL custom-format
`pg_dump`, validates its archive structure using matching `pg_restore`, uploads it
to the designated GCS bucket and verifies the object checksum and generation.
The receipt must bind `environment`, exact `image`, `project`, VM `instance`,
`status=SUCCESSFUL`, `completedAt` within one hour and immutable
`backupId=gs://bucket/object#generation`. This is a release backup requirement;
periodic backup policy and recovery drills remain separate operational work.

The authorized production backup/restore rehearsal on 2026-10-01 passed for
artifact B (`58c7345`), including auth preservation, report-data exclusion,
function ownership, runtime grants, valid indexes, API/auth readiness and
synthetic campus/food searches. Private local archives, credentials, cluster and
test processes were removed. Only private receipt and sanitized evidence were
retained locally; no backup object identifier or private contents are recorded in
the [public verification record](../../docs/operations/staging-release-verification-2026-10-01.md).
That rehearsal does not waive the exact-image or one-hour receipt check for a
later production deployment, and it did not change the production database.

After provisioning and initial validation, protected workflows test/build/stage an
image and explicitly promote its identical digest. Manual equivalents are:

```bash
deploy/gcp-vm/deploy.sh --environment staging --image "$RELEASE_IMAGE"
python3 deploy/gcp/backup.py --image "$RELEASE_IMAGE" --output "$BACKUP_RECEIPT"
deploy/gcp-vm/deploy.sh --environment production --image "$RELEASE_IMAGE" \
  --backup-receipt "$BACKUP_RECEIPT"
```

`--skip-public-probe` is reserved for explicit initial DNS/bootstrap work. It still
requires private candidate and local HTTPS gates; verify the public endpoint
before directing users to that host. Routine releases do not use this exception.

On the host, revert explicitly to its retained prior release with:

```bash
sudo /opt/nextstop/current/deploy/gcp-vm/rollback.sh production
# Use staging on the staging VM.
```

Rollback checks retained API/auth readiness and an authenticated search before
proxy activation. A failed rollback restores the previously active state. Keep
images and `/opt/nextstop/releases` tooling referenced by active, previous or
pending state. A host/IAP failure can require operator recovery; the journal and
cached images remain available for a retry.

## Simulator broker and operations

The stable private broker command on each VM is:

```bash
sudo /usr/local/sbin/nextstop-mint-simulator-token
```

It runs a networkless, read-only, capability-free one-shot container with only the
search signing key. Short-lived token JSON is returned through private IAP and
never logged. The ingestion worker does not receive that key. The broker remains
usable during a release and resolves the active immutable image from state.
The iOS broker presets bind each endpoint to the correct environment; see
[development instructions](../../docs/development.md).

`/health` is liveness. `/ready` and `/ready/auth` verify the corresponding service
and report its release digest. Nginx records only allowlisted error metadata and
generated request IDs, with bounded rotation. Never print `docker compose config`,
container environments, tokens, credentials, precise routes or private reports
into logs. Inspect aggregate state and bounded redacted service logs instead.

Database roles remain separate: projection reads, auth DML, support-report DML,
worker DML and release-scoped owner migrations. Readiness uses a fixed migration-
presence helper, not registry-table privileges. Authentication schemas remain in
[OpenAPI](../../docs/api/openapi.yaml). Public report distribution retains the
independent [privacy and operations gates](../../docs/operations/user-error-reports.md).

## Verification

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s deploy/releases -p 'test_*.py' -v
bash -n deploy/gcp-vm/*.sh deploy/releases/*.sh
cd backend && npm run lint && npm run typecheck
```

Tests fake Docker, HTTP and gcloud. They cover candidate/migration/proxy/public/
worker failures, interrupted recovery, rollback preservation and transient
registry credential cleanup. They do not claim a real deployment has run.
Exercise a real staging release and rollback before enabling promotion.
