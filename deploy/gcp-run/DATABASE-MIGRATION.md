# Cloud SQL database transfer

The staging procedure targets `nextstop-tech-testing:europe-west1:nextstop-staging`.
The first production restore has a separate mode for
`nextstop-tech-staging:europe-west1:nextstop-production`.
`database-transfer.py` prepares local review files. Use installed PostgreSQL 17 tools,
private service/password files, and the Cloud SQL Auth Proxy or mounted Cloud Run
connector. Never put passwords in argv, checked-in files, shell traces, or output.

## First production restore from the legacy VM

The separate `prepare-production` operation handles the existing migration-0015
VM archive. Use the trusted **production** operator in a private directory on
the production VM. Obtain the precise `gs://…dump#generation` from the approved
production backup run. Read the object metadata and download that exact
generation with authenticated GCS tooling. Keep the file mode 0600 throughout.
The backup workflow checked the original VM archive's SHA-256 before upload.
Its legacy receipt identifies the object generation. The preparation step
checks the size and GCS MD5 for that generation and records the local SHA-256.

```sh
umask 077
gcloud storage objects describe "$BACKUP_ID" --raw --format=json > "$PRIVATE_DIRECTORY/object.json"
gcloud storage cp "$BACKUP_ID" "$PRIVATE_DIRECTORY/backup.dump"
python3 deploy/gcp-run/database-transfer.py prepare-production \
  --purpose backup --source-migrations 15 --directory "$PRIVATE_DIRECTORY" \
  --connection-name nextstop-tech-staging:europe-west1:nextstop-production \
  --backup-id "$BACKUP_ID" --object-metadata "$PRIVATE_DIRECTORY/object.json"
```

The legacy archive includes extension-owned objects in other schemas. The
procedure selects the exact application table inventory and the empty report
table definition. On a new, empty production database bootstrap PostGIS,
`btree_gist` and the application owner before restoring. Independently check
the socket, database system identifier and Cloud SQL instance creation time
using the [production handoff procedure](PRODUCTION-PRIVATE-HANDOFF.md).
Run the reviewed list only against this empty target. A 55 GiB restore and its
index builds need an appropriate session statement timeout, sufficient free
disk and a monitored maintenance window.

```sh
pg_restore --dbname=service=nextstop_production_cloudsql --schema=nextstop \
  --no-owner --no-privileges --exit-on-error --single-transaction \
  --use-list="$PRIVATE_DIRECTORY/restore.list" "$PRIVATE_DIRECTORY/backup.dump"
```

Verify exactly 15 migration records, zero report rows and matching public data
before applying 0016–0019 and the reviewed role grants. Compare the active
projections, public writer state, authentication keys and representative queries
again before the final fenced transfer. Durable backups exclude reports.
Remove the transient archive on the operator after verifying restoration.

Before commissioning either managed environment, complete the separate
PostGIS owner step below. This applies equally to an isolated restore rehearsal.

## Staging bootstrap and role boundaries

Connect to the already-created `nextstop` database as the Cloud SQL administrator
(`postgres`, a non-superuser member of `cloudsqlsuperuser`). Load six process
environment variables from the private secret source: `OWNER_DATABASE_PASSWORD`,
`API_DATABASE_PASSWORD`, `AUTH_DATABASE_PASSWORD`, `SUPPORT_DATABASE_PASSWORD`,
`WORKER_DATABASE_PASSWORD`, and `BACKUP_DATABASE_PASSWORD`, each at least 32
characters. Required database log settings are `log_statement=none`,
`log_parameter_max_length_on_error=0`, `log_min_duration_statement=-1`, and
`log_min_duration_sample=-1`.

```sh
psql -Xq -v ON_ERROR_STOP=1 --dbname=service=nextstop_staging_admin \
  --file=deploy/gcp-run/database-bootstrap.sql
```

After bootstrap and again after restoration or a PostGIS upgrade, apply
`deploy/security/restrict-postgis-flatbuffer-decoder.sql` as the PostGIS owner.
Run `deploy/security/verify-postgis-flatbuffer-decoder.sql` with
`psql -X -v ON_ERROR_STOP=1` as `nextstop_api` on the same pinned database.
Both commands must succeed before that target is used for traffic or accepted
as a completed restore. Include their results and an ordinary populated spatial
search in the recovery evidence. The application migrator lacks the extension
owner's grant authority. [PostGIS security procedure](../security/POSTGIS-DECODER.md).

The SQL owns its transaction. It creates restricted roles, installs `postgis` and
`btree_gist`, assigns database/schema ownership to `nextstop_app`, and retains
bootstrap CONNECT access. Unsafe existing role attributes/memberships fail closed.
Cloud SQL suppresses PostgreSQL 17's ordinary creator grant, so the script creates
it explicitly only when absent. The administrator may administer runtime roles but
cannot SET or inherit them; only the migration owner permits administrator SET.
Runtime roles are never members of another role.

The canonical object-grant and verification SQL lives in `backend/operations`;
the deployment files include that source. The Cloud Run migration job executes
`node dist/src/jobs/cloud-migrate.js`: additive migrations first, then these grants
and verification as the restricted owner. It does not create or administer roles.

After restore, apply pending reviewed migrations as `nextstop_app`, including
`0018_monthly_import_budget.sql`, then run:

```sh
psql -Xq -v ON_ERROR_STOP=1 --dbname=service=nextstop_staging_cloudsql \
  --file=deploy/gcp-run/database-roles.sql
```

This grants and verifies API search reads, auth challenge/key CRUD, support report
CRUD, and worker ingestion/availability/control-table access. Only the worker gets
TEMP and the projection rebuild/statistics functions. `nextstop_backup` has SELECT
on the explicit non-report table list, including auth state and migration metadata;
it cannot read reports, write rows, create schema objects, or use the application's
privileged functions. New tables need an explicit reviewed grant/inventory update.

## Transfer and retained backups

A `handoff` snapshot may contain staging auth and report rows solely for a private
transfer of at most four hours. It must never become a durable backup. Pause old
staging writers for the final snapshot, preserve staging signing keys, and delete
the exact temporary copies after verification. A normal `backup` excludes report
contents under ADR 0017. Instance backups/PITR must not reintroduce their retention.

Prepare a private directory and command plan; this executes no database commands:

```sh
python3 deploy/gcp-run/database-transfer.py plan \
  --directory /private/tmp/nextstop-staging-transfer \
  --purpose backup --source-migrations 17 \
  --connection-name nextstop-tech-testing:europe-west1:nextstop-staging
```

Review both service-file endpoints before executing the plan. The source must be
staging. Restore as `nextstop_app`; the administrator has already installed the
extensions and namespace. The plan uses one restore transaction, no owner/ACL
restoration, bounded lock waits, and no provider downloads. After dumping:

```sh
python3 deploy/gcp-run/database-transfer.py prepare \
  --directory /private/tmp/nextstop-staging-transfer \
  --purpose backup --source-migrations 17
```

`prepare` checks the exact TABLE DATA inventory for 17 or 18 migrations, hashes the
archive, and writes private `restore.list` and receipt files. It cannot attest to
endpoint identity or arbitrary archive SQL safety; use only the operator's trusted
dump. Execute the reviewed restore argv with its filtered list.

Recurring backups use `nextstop_backup` with
`--exclude-table=nextstop.user_error_reports`. Excluding only TABLE DATA still needs
a dump lock on that table and correctly fails without SELECT. Export its structure
separately from catalogs, without report-table access:

```sh
psql -XqAt -v ON_ERROR_STOP=1 --dbname=service=nextstop_staging_source \
  --file=backend/operations/export-report-schema.sql
```

Capture stdout directly to an exclusive mode-0600 `report-schema.sql` or immutable
storage object; suppress raw errors. Unknown schema features fail before any DDL
is emitted. Keep the supplement with its archive and bind both hashes and storage
generations in the successful receipt. Serialize backup creation with schema
releases so both describe the same migration state.

After restoring the archive, restore that supplement as `nextstop_app` with
`psql -Xq -v ON_ERROR_STOP=1 --single-transaction --file=...`, before pending
migrations and grants. It recreates an empty report table with constraints/indexes.
An initial owner-created archive using `--exclude-table-data` already includes its
DDL. The receipt identifies this with `restoreSupplementRequired=false`; do not
also apply a supplement. Handoff archives need no supplement either.

Before cutover compare aggregate metadata only: migration names, public/auth table
counts, active projection IDs, extension versions, owned objects, and unchanged
private key-file equality booleans. Never print auth values, reports, precise
routes, or keys. A backup restore must contain zero report rows. Bounded readiness
and authenticated search checks do not prove real-device App Attest continuity.
Never run the destructive integration suite on the restored staging database.

## Runtime connection

Cloud Run must explicitly set `NEXTSTOP_RUNTIME=cloud-run`,
`NEXTSTOP_ENVIRONMENT=staging`, `DATABASE_TRANSPORT=cloud-sql-socket`, and a validated
`CLOUD_SQL_CONNECTION_NAME`. Role URLs use
`postgresql://nextstop_<role>:<escaped-password>@localhost/nextstop` without port,
query, or fragment. The driver fixes `/cloudsql/<connection-name>` and rejects URL
host overrides. The Cloud SQL connector handles remote encryption, so PostgreSQL
TLS is disabled only on that explicit local socket. Direct connections require
verified TLS. VM defaults are unchanged. Session connections preserve advisory
locks and temporary tables; do not add transaction pooling.

## Local proof

Set `NEXTSTOP_TEST_PG_BIN` to an existing PostgreSQL 17 bin directory with PostGIS,
and `NEXTSTOP_TEST_NODE` to an existing Node 24 binary for the budget concurrency
check. Tests create and stop their own temporary Unix-socket-only cluster:

```sh
python3 -m unittest discover -s deploy/gcp-run -p 'test_database*.py' -v
```

Coverage includes non-superuser bootstrap/repetition, unsafe membership rejection,
role isolation, worker session locks/TEMP/rebuilds, actual report-excluding dump and
restore with auth preserved, equivalent empty report DDL, and 20 concurrent actual
TypeScript budget reservations. The local dummy `cloudsqlsuperuser` does not emulate
managed extension privileges; those and Cloud SQL's explicit creator-grant path
need the separate managed-service check.

### Filled private-state handoff and return

The `test_filled_private_handoff_and_rollback` integration test creates two
databases from `template0`, installs migrations through 0015 and 0019 respectively,
and seeds synthetic App Attest keys, challenges, reports and deletion markers.
It closes both writer logins on each inactive database, drains a transaction
already in progress, and checks every field after the forward and reverse copies.
The return includes a newer assertion counter and revocation, a consumed
challenge, a new challenge, a withdrawn report and a newly submitted report.
An expired challenge remains unusable and the report purge retains live deletion
markers. A deliberately interrupted import rolls back the whole transaction. A
divergent inactive database fails the comparison before the copy.

On 2026-10-31 the test passed locally on PostgreSQL 17.11 and on the actual
Staging Cloud SQL instance after maintenance `POSTGRES_17_11.R20260712.01_44`.
Managed rehearsal `5fa2e55d291e2f` used two empty databases on that instance,
an ephemeral administrator and two restricted writers. Both databases and all
three logins were confirmed removed after the run. This exercises schema-15
and schema-19 private state on the managed engine. Production VM connectivity,
cross-instance transport, signing identities and ingress cutover are separate
release checks.

For an actual handoff, establish the following conditions on **both** endpoints.

1. Pin each connection to its intended project, database and restricted owner.
   Verify the private table definitions and the App ID/signing-key equality
   without printing key material. Freeze deployment, Auth, Report and purge
   writers, deny reconnections and allow in-flight transactions to finish.
   Verify effective writer access is denied and no writer sessions remain.
2. Record an exact private baseline for the inactive destination and a consistent
   source snapshot of `nextstop.app_attest_keys`, `nextstop.app_attest_challenges`
   and `nextstop.user_error_reports`. Preserve nulls and absolute timestamps.
   Keep comparison data private. A row count cannot distinguish a consumed
   challenge or a withdrawal. Use the report-inclusive transfer solely for the
   immediate handoff within the existing four-hour limit.
3. Check that the inactive destination still matches its baseline. While both
   sides remain frozen, replace just these three tables in one transaction
   using the completed, verified snapshot. Compare all their rows and columns.
   If any check fails, keep both endpoints frozen while resolving which has the
   latest state. Enable writers on exactly one verified destination.
4. To return, freeze and drain the **new active writer**, check the retained
   inactive baseline, and repeat the transaction in reverse using the **current**
   state, including post-cutover writes and withdrawals. Validate readiness and
   authenticated search before reopening ingress. Remove transient private
   copies, including stale payloads on the inactive server, within the handoff
   window. Retained backups must continue to exclude reports.
