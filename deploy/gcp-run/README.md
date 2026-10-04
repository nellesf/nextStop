# Isolated staging on Cloud Run and Cloud SQL

The owner selected Cloud SQL for the staging migration on 2026-10-04. This folder
contains local render/release controls, database transfer helpers and a reviewable
cost model. It is not evidence that a cloud deployment or migration has completed.
Production continues to use the existing VM, database and protected release path.
No production role, image, domain or workflow is changed by these helpers.

The fixed target is project `nextstop-tech-testing` (`353471052580`), region
`europe-west1`, PostgreSQL17 Enterprise `db-g1-small`, zonal, 50GiB SSD, instance
`nextstop-staging`. The Cloud SQL connection name is
`nextstop-tech-testing:europe-west1:nextstop-staging`. The database stays running;
the application services scale to zero between requests. G1-small capacity and a
full shadow import must be measured before accepting the migration.

## Runtime and identity boundaries

| Service | Entry point | Identity | Secrets / database access |
| --- | --- | --- | --- |
| `nextstop-gateway` | `dist/src/gateway-server.js` | `nextstop-run-gateway` | None; invokes only API and auth |
| `nextstop-api` | `dist/src/server.js` | `nextstop-run-api` | Read-only search DSN, restricted support DSN, snapshot and access-token keys |
| `nextstop-auth` | `dist/src/auth-server.js` | `nextstop-run-auth` | Auth DSN and access-token key |
| `nextstop-live` | `dist/src/live-refresh-server.js` | `nextstop-run-live` | Worker DSN; one task at a time |
| `nextstop-broker` | `dist/src/simulator-token-server.js` | `nextstop-run-broker` | Access-token key only; no database |

All identities are service accounts in the isolated staging project. Each service
uses one 1vCPU/512MiB container, port8080, request-based CPU, minimum0 and maximum1
instance. The maximum is a concurrency control, not a complete spend cap.
Readiness is tested explicitly; platform probes use `/health` and do not poll the
database. Cloud Run supplies `PORT`; the image binds `0.0.0.0`.

Only the gateway becomes public. API, auth, live and broker retain Cloud Run IAM
authentication even though ingress allows Google service-to-service requests.
Gateway credentials have `run.invoker` on API/auth and no Secret Manager or SQL
access. The trusted broker caller can invoke only the private broker. The task
identity `nextstop-run-tasks` can invoke only the live service; the API can enqueue
on the one staging queue and act as that task identity. Apply IAM narrowly per
resource; do not grant a runtime identity project-wide secret access.

The gateway exposes a fixed path set, never `/token`, and forwards an IAM token in
`X-Serverless-Authorization` while retaining the app's own authorization header.
Its client-IP limiter accepts the Cloud Run ingress peer information only. The
live ingress spoof/isolation test is a release gate; a unit test alone does not
establish the platform's forwarding behavior. No raw request URLs, client IPs,
tokens or payloads belong in application diagnostics.

Before granting public invocation or sending any test request, install the exact
`logging-exclusion.json` filter on the `_Default` log sink. It excludes the raw
Cloud Run request log for all five services. The release preflight checks that the
exclusion is enabled. Queue request logging also remains disabled. Do not use
temporary public access to debug a private service.

The staging custom domain can map to the gateway in Belgium without a load
balancer or retained VM proxy. Cloud Run's regional domain mapping is a preview
feature with its documented limitations; this is a staging choice, not a change
to the production availability design. A first cutover requires separately
verified DNS/TLS and authenticated search before the old staging VM is retired.

## Maintenance and backup jobs

| Job | Identity | Schedule (UTC) | Limits |
| --- | --- | --- | --- |
| `nextstop-monthly` | `nextstop-run-worker` | Daily02:00 due check | 2vCPU/8GiB; 8h work plus30s shutdown; no platform retries |
| `nextstop-cleanup` | `nextstop-run-worker` | Daily23:00 | 1vCPU/512MiB; 300s work plus30s shutdown; no retries |
| `nextstop-report-purge` | `nextstop-run-support` | Hourly | 1vCPU/512MiB; 120s work plus30s shutdown; no retries |
| `nextstop-backup` | `nextstop-run-backup` | Daily03:00 | 1vCPU/512MiB; 3600s total; no retries |
| `nextstop-migrate` | `nextstop-run-migrator` | Explicit release step only | 1vCPU/512MiB; 900s; no retries; expand-only migrations then verified object grants |

Monthly scheduling is persisted in the database. A daily invocation performs
heavy work only when due and outside the24h failure cooldown. The shared monthly
budget allows at most three whole heavy attempts for charging and food together,
each at most8h. Charging precedes food; the job does not perform periodic Swiss
live refreshes. One DB session lock serializes monthly work. GCS cache files are
public provider downloads, with generation-pinned reads and bounded object
validation. Use a dedicated cache bucket with uniform access, public access
prevention, no versioning/soft delete, and a finite lifecycle such as90days. This
can cause an occasional safe redownload for objects unchanged beyond90days.

The private live queue permits one concurrent dispatch,0.1 dispatches/second and
three attempts. Retries wait660seconds, beyond the10-minute database lease; a
request does not wait for provider refresh. Availability stays informational and
unknown on a provider/queue failure. Idle searches do not start periodic imports.

The backup job uses a separate read-only role, Cloud SQL socket and its own bucket.
It streams a PG17 custom archive directly to GCS. The report table is excluded from
the data archive; separately captured catalog-only report DDL permits recreation
without granting the backup role access to report values. Auth records remain
private recovery data. Receipt/checksums bind both objects to exact generations.
Restore rehearsals must use a private isolated recovery database, never ordinary
staging seeded with production private data. Backup access/retention and a real
restore rehearsal are activation gates. Managed full backups and PITR remain off
because they would retain report data contrary to the existing policy.

The maintenance program is `node dist/src/jobs/maintenance-job.js` with
`MAINTENANCE_JOB_MODE=monthly-import|cleanup|report-purge`; backup uses
`node dist/src/jobs/database-backup.js`. Scheduler invokes the Jobs API using
OAuth as `nextstop-run-scheduler` with scoped `run.jobs.run` permissions. It cannot
override job secrets or arguments. Definitions have one task and parallelism1;
this does not by itself prevent two manual executions, so do not overlap manual
backup/recovery runs. Release preflight refuses an unfinished job execution.

Scheduler JSON files are request templates, not applied by the release helper.
Cloud Scheduler `state` is output-only and a newly created schedule is enabled.
Create schedules only after all gates pass, or immediately pause them during an
explicit operator setup. Never assume a `state: PAUSED` field in create JSON keeps
a new schedule dormant. Existing schedules must be paused before job definitions
are replaced, then explicitly resumed after the verified release.

For initial commissioning, run `python3 deploy/gcp-run/commission_schedulers.py
--config /private/tmp/staging-config.json --expected-release REVIEWED_RELEASE_ID`
to inspect the local plan; it makes no cloud calls. Add `--apply` only during UTC
minutes10–49, away from the four minute-zero schedules. The helper creates only
missing definitions, immediately pauses each new job, and verifies all four end
in `PAUSED` with the exact schedule, invocation identity, body and retry policy.
Existing jobs must already match and be paused; differences stop commissioning.
Creation briefly enables a job because Scheduler has no atomic paused-create
operation. SIGINT/SIGTERM finish the current bounded pause verification before
aborting. If pause confirmation fails, stop and inspect the four jobs before
retrying. This helper never resumes or executes a job; activation remains a
separate operator action after the release gates pass.

## Local configuration and reviewed release

Use the same immutable backend image for every service and job. Only the existing
registry `europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend` is
accepted. Verify the registry manifest/config hashes, `linux/amd64` platform and
OCI source revision against the complete source commit before applying. A receipt
is a record of performed checks, not an image-verification mechanism by itself.

The config schema is exact:

```json
{
  "environment": "staging",
  "project": "nextstop-tech-testing",
  "region": "europe-west1",
  "backendImage": "europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend@sha256:REPLACE_WITH_VERIFIED_DIGEST",
  "commit": "REPLACE_WITH_COMPLETE_VERIFIED_COMMIT",
  "cloudSqlConnectionName": "nextstop-tech-testing:europe-west1:nextstop-staging",
  "cacheBucket": "nextstop-tech-testing-downloads",
  "backupBucket": "nextstop-tech-testing-backups",
  "appAttestAppId": "REPLACE_WITH_EXACT_TEAM_AND_BUNDLE_ID",
  "secretVersions": {
    "api-database-url": "1",
    "auth-database-url": "1",
    "support-database-url": "1",
    "worker-database-url": "1",
    "migrator-database-url": "1",
    "backup-database-url": "1",
    "snapshot-signing-key": "1",
    "access-token-signing-key": "1"
  },
  "retainedTraffic": {},
  "acceptanceEvidence": {
    "object": "operations/evidence/REPLACE_WITH_SHA256.json",
    "generation": "REPLACE_WITH_NUMERIC_GENERATION",
    "sha256": "REPLACE_WITH_SHA256"
  }
}
```

Bucket names in the example must match the actual isolated resources. Secret
references become `nextstop-staging-<name>` at the numeric version; `latest` and
secret values are rejected. DSNs use the role's password and
`postgresql://ROLE:PASSWORD@localhost/nextstop`, without query, fragment or port.
`DATABASE_TRANSPORT=cloud-sql-socket` replaces localhost with the fixed
`/cloudsql/<connection>` path. See the database bootstrap/roles/transfer files for
restricted ownership, required PostGIS/btree_gist extensions and restore order.

The following commands run from the repository root. Use a private local config
file and output directory. `plan` and `render.py` perform no cloud calls;
`snapshot` is read-only:

```bash
python3 deploy/gcp-run/release.py snapshot --project nextstop-tech-testing
python3 deploy/gcp-run/release.py plan --project nextstop-tech-testing \
  --config /private/tmp/staging-config.json --output /private/tmp/staging-release
```

Copy the fresh resolved `retainedTraffic` snapshot into the config. On an existing
queue add `--queue-exists` consistently when generating/applying that plan. Inspect
the plan, rendered IAM/secret references and image proof. The rendered release ID
binds image, commit, configuration and secret versions; traffic history does not
change that ID. Existing tagged revisions are preserved, with the candidate tag
receiving0% while the old revision keeps its allocation. First-created services
have100% of their own traffic but remain private until the separate IAM step.

After prerequisite resources/roles, filtered public seed, compatible migration,
log exclusion and private IAM have been verified, apply the reviewed hash:

```bash
python3 deploy/gcp-run/release.py apply-definitions --project nextstop-tech-testing \
  --config /private/tmp/staging-config.json --output /private/tmp/staging-release \
  --expected-plan-sha256 REVIEWED_PLAN_HASH
```

This creates/updates only the queue and service/job definitions. It performs no
IAM, secret, bucket, database, DNS, scheduler activation, job execution or existing
gateway traffic switch. It checks project number, exact SQL sizing/backup policy,
fresh retained traffic, private-service IAM and logging before mutations.

Test the tagged candidate path while preserving the current gateway's API/auth
targets. The gateway uses the candidate's immutable API/auth tag URLs and the
untagged service URLs as IAM audiences. Google documents both the deterministic
tag URL format and untagged audience requirement. The live task target remains
the stable private service URL; old/new task payload compatibility is a gate.

Create a local verification JSON containing exactly `release`, `image`, `commit`,
`verifiedAt` (timezone-qualified ISO UTC), plus these booleans set true only after
the checks actually pass: `apiReady`, `authReady`, `syntheticSearchPassed`,
`clientIPIsolationPassed`, `loggingExclusionVerified`, `jobsBudgetVerified`,
`privateIAMVerified`, `artifactVerified`, `filteredBackupRestorePassed`, and
`liveTaskCompatibilityPassed`, `xffPrefixResistancePassed`,
`idleScaleToZeroPassed`, `databasePerformancePassed`. Keep request bodies, tokens and private backup
identifiers out of this evidence file and CI output.

```bash
python3 deploy/gcp-run/release.py promote --project nextstop-tech-testing \
  --config /private/tmp/staging-config.json --output /private/tmp/staging-release \
  --expected-plan-sha256 REVIEWED_PLAN_HASH --verification /private/tmp/staging-verification.json
```

Promotion requires evidence from the last hour and re-reads actual candidate
readiness, digest, identity, command and pinned environment. It expects the
post-apply candidate tags and queue to exist. Private defaults change first;
gateway traffic changes last. Older gateways keep their tagged API/auth targets.
No retained tag is automatically deleted or repointed. A partial failure stops
without guessing the current state; take a fresh snapshot, inspect which defaults
changed, and review a new plan before retrying.

Rollback selects the previous gateway revision and its preserved private tags;
retain old image digests and numeric secret versions while rollback is required.
Do not roll back the schema or replay a destructive migration. Confirm stable
live-task compatibility before reverting the live service. Never delete a
private revision tag still referenced by a retained gateway. Tag history is
bounded to12 entries per service in the config; explicit reviewed cleanup is
required when that limit is reached.

## Subsequent CI releases and reusable acceptance evidence

The existing `backend-staging.yml` keeps the trusted main push, repository,
successful Backend workflow, WIF and exact immutable artifact gates. The explicit
staging environment variable `NEXTSTOP_STAGING_HOSTING=cloud-run` selects
`deploy.py`; absent/`vm` retains the existing VM path and any other value fails.
`NEXTSTOP_RELEASES_ENABLED` must also be true. Production tooling is unchanged.
The shared concurrency group prevents two CI staging releases from overlapping.
Do not run a manual release alongside that workflow.

The operator populates `deploy/environments/staging-cloud-run.json` with actual
resource names and numeric secret pins, then enables the new hosting selector
only after the initial migration, DNS/TLS, schedules and acceptance checks pass.
The original `staging.json` keeps its registry region for the existing artifact
builder; do not rewrite that build-registry setting to Belgium.

`deploy.py` deliberately requires the five services and four schedules to exist.
It verifies the exact staging CI identity, a clean checkout at the source commit,
the registry manifest/config hashes and OCI revision. It reads only the pinned
private evidence object from `backupBucket`, verifies its generation and SHA256,
and checks the relevant source/config fingerprints before any mutation.

The operator evidence schema is:

```json
{
  "version": 1,
  "environment": "staging",
  "project": "nextstop-tech-testing",
  "verifiedAt": "REPLACE_WITH_ACTUAL_UTC_VERIFICATION_TIME",
  "checks": {
    "clientIPIsolationPassed": {"passed": true, "sourceSha256": "REPLACE_WITH_SCOPE_HASH"},
    "filteredBackupRestorePassed": {"passed": true, "sourceSha256": "REPLACE_WITH_SCOPE_HASH"},
    "jobsBudgetVerified": {"passed": true, "sourceSha256": "REPLACE_WITH_SCOPE_HASH"},
    "liveTaskCompatibilityPassed": {"passed": true, "sourceSha256": "REPLACE_WITH_SCOPE_HASH"},
    "idleScaleToZeroPassed": {"passed": true, "sourceSha256": "REPLACE_WITH_SCOPE_HASH"},
    "databasePerformancePassed": {"passed": true, "sourceSha256": "REPLACE_WITH_SCOPE_HASH"}
  }
}
```

This example is a schema, not successful evidence. Record a check only after the
real test passes. `--acceptance-hashes` prints the current fingerprints locally
without cloud requests or inventing `passed` values:

```bash
python3 deploy/gcp-run/deploy.py --config deploy/environments/staging-cloud-run.json \
  --acceptance-hashes
```

The fingerprints cover each check's critical runtime files, dependencies,
renderer and stable config including numeric secret versions. Docs-only source
commits can reuse the same real evidence; a relevant source/config change blocks
release until that check is repeated and a new private object generation is
pinned. Whole-image hashes/OCI labels are checked independently on every release.
The evidence cannot claim distinct real client-IP isolation from forged header
tests alone: demonstrate a limited source receives429 while a second real source
receives its valid response, storing only booleans, never those addresses.

The automated order is: verify source/artifact/evidence; snapshot traffic and
original scheduler states; pause enabled schedules; preflight; run
`cloud-migrate.js` (expand-only migrations and role grants); apply definitions;
verify actual candidate metadata; run tagged API/auth readiness, broker mint,
synthetic search and forwarded-prefix resistance; promote private defaults and
then gateway; verify readiness/search through the fixed public staging domain;
restore only schedules that were previously enabled. The prefix test intentionally
uses the auth limiter, so a bounded10s refill separates it from the public check.

If a candidate check fails, no gateway handoff occurs. If promotion or the public
check fails, restore the original traffic allocations with gateway first, retain
all revision tags and leave changed job schedules paused for review. A command
failure is not proof that the requested cloud change had no effect; inspect the
sanitized phase status and current control-plane metadata before retrying. The
script never widens IAM or falls back to a shared bearer.

CI needs narrowly scoped service/job update and invocation, runtime-account
`actAs`, private gateway/broker invocation, its own ID-token generation, queue
update/metadata reads, schedule pause/resume/metadata reads, SQL metadata, log-sink
metadata, registry metadata, and get-only access to the evidence object prefix.
It does not need database passwords, backend secret values, backup archive reads,
DNS writes, SQL-instance creation or project-wide IAM changes. Actual grants are
a separately reviewed operator step. Verify IAMCredentials `generateIdToken` for
the exact staging deploy account under the real WIF identity before enabling this
branch. Its self-bound `roles/iam.serviceAccountOpenIdTokenCreator` permits only ID
tokens; the CI helper does not require the broader Token Creator role or
service-account access-token impersonation. `gcloud auth print-identity-token
--audiences` is not used because the CLI rejects WIF external-account credentials
for that combination.

## Cost baseline and acceptance gates

The user reported about€70/month for staging; its tax basis and exact billing
composition have not been verified. The measured initial corpus was22.78GiB,
provider cache0.883GiB. [cost-plan.json](cost-plan.json) records quantities, source
URLs, EUR SKU IDs, supplemental USD conversion and assumptions. Recalculate with:

```bash
python3 deploy/gcp-run/cost.py
python3 -m unittest discover -s deploy/gcp-run -p 'test_*.py'
```

| Monthly item | Model, net EUR |
| --- | ---: |
| g1-small,730h +50GiB SQL SSD | 29.964 |
| Reference30GiB filtered GCS backups alone | 0.528 |
| Full staging model before reserve | 37.52–50.17 |
| Full model including10% reserve | 41.27–55.19 |
| Illustration with19%VAT, including reserve | 49.12–65.67 |

The earlier39–52€ estimate preceded the explicit daily backup and extra scheduler
budget. This model includes those, request CPU for three separate services,
private live work,8–24h monthly imports, bounded maintenance,40–55GiB combined
backup/cache storage,5GiB registry retention, logging, secrets, builds and
10–50GiB internet egress. It assumes no free allowances or credits. Full SQL
backups are not charged because that report-containing backup path is disabled.

The model is below the reported baseline under these assumptions; it cannot
guarantee a bill ceiling. Traffic, retries, storage growth, provider sizes and
one-time overlap can differ. Billing data can lag24h or longer. Compare actual
service charges after at least48h and after the first import; revisit the model
at projected52€ net and obtain a decision before projected70€ net. Budget alerts
are notifications, not hard shutdowns. Retaining the old staging VM/disks after
acceptance would invalidate the intended steady-state saving.

Before accepting the cutover, measure cold/warm authenticated search latency,
connection/memory pressure, maximum SQL disk usage during the shadow import,
full import duration and a filtered-backup restore. Do not claim g1-small is
adequate because it is cheaper. CPU/RAM changes are an explicit restart/resize
operation, not latency-free autoscaling. No performance tradeoff changes the
domain filters, Apple place matching, EVSE counts or availability semantics.

Price and platform sources checked2026-10-04:
[Cloud SQL](https://cloud.google.com/sql/pricing),
[Cloud Run](https://cloud.google.com/run/pricing),
[Cloud Storage](https://cloud.google.com/storage/pricing),
[service URL format](https://docs.cloud.google.com/run/docs/triggering/https-request),
[service authentication](https://docs.cloud.google.com/run/docs/authenticating/service-to-service),
[domain mapping](https://docs.cloud.google.com/run/docs/mapping-custom-domains).
