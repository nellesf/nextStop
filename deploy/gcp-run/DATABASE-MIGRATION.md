# Staging Cloud SQL database procedure

This targets `nextstop-tech-testing:europe-west1:nextstop-staging` and PostgreSQL 17
only. Production is unchanged. `database-transfer.py` prepares local review files;
it never connects to a database or cloud API. Use installed PostgreSQL 17 tools,
private service/password files, and the Cloud SQL Auth Proxy or mounted Cloud Run
connector. Never put passwords in argv, checked-in files, shell traces, or output.

## Bootstrap and role boundaries

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
