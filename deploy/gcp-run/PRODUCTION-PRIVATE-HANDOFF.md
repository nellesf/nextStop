# Production private-state transfer

Use this procedure only for the first VM-to-Cloud-SQL cutover and its bounded
return window. The existing filtered backup restores the public corpus and the
initial auth tables. Reports and report deletion markers belong exclusively to
this short-lived transfer. Keep the Staging and Production projects separate.

## Prepare the operator

Use a reviewed, immutable Linux operator container on the original GCE VM
`nextstop-tech-staging/europe-west3-a/nextstop-backend`. Join the database
container's network namespace so `127.0.0.1:5432` reaches its PostgreSQL server.
Mount the dedicated Cloud SQL Auth Proxy Unix socket at
`/cloudsql/nextstop-tech-staging:europe-west1:nextstop-production`. Bind the
proxy to that exact instance with IAM, connector enforcement and the production
identity. The operator checks the GCE metadata identity, both PostgreSQL system
identifiers, the Cloud SQL Admin API creation timestamp and the two migration
histories. The existing, digest-pinned backend OCI image supplies Node 24,
the locked `pg` package and `/app/dist/migrations`. Mount only this reviewed
operator file from its verified commit read-only at
`/app/deploy/gcp-run/production-private-handoff.mjs` and run it with the image's
unprivileged user. The checkout layout with `backend/node_modules` and
`backend/migrations` also works. Never mount the Docker socket in the operator.

Use a fresh mode-0700 persistent journal directory owned by the operator on
that VM. Retain the **same directory** across container restarts and operators.
Keep each raw password in a separate owner-only file on protected tmpfs, disable
core dumps and shell tracing, and use a process context without swap, remote
debugging or request-body logging. The operator streams parameterized batches
in memory. No intermediate private archive is written. Both connections enforce
terse PostgreSQL error verbosity, `log_min_error_statement=panic`, disabled statement/duration/sampled transaction
and bind-parameter logging, and inactive pgAudit/auto_explain capture. Provision
`log_error_verbosity=terse` and `log_min_error_statement=panic` on the managed database (or grant the restricted
operator permission to set that parameter for its session). The trusted VM
owner overrides unsafe defaults in its own session. Review any additional
preloaded audit/log forwarding extensions as administrators before the transfer.
Keep Cloud SQL Query Insights and pgAudit disabled for this private operation.

Pass a mode-0600 JSON configuration with these fields. Obtain the numeric pins
independently from the source VM, its `pg_control_system()`, the real Cloud SQL
instance (including its separate PostgreSQL system identifier) and the
immutable filtered backup object in the verified **production** backup receipt. The
production operator's Google identity needs `cloudsql.instances.get` on the
exact managed database. All paths must be absolute and canonical.

```json
{
  "vmInstanceId": "VERIFIED_NUMERIC_GCE_INSTANCE_ID",
  "vmDatabaseSystemId": "VERIFIED_NUMERIC_OLD_POSTGRES_SYSTEM_ID",
  "cloudDatabaseSystemId": "VERIFIED_NUMERIC_CLOUD_SQL_POSTGRES_SYSTEM_ID",
  "cloudCreateTime": "EXACT_CLOUD_SQL_CREATE_TIME",
  "filteredRestoreGeneration": "VERIFIED_NUMERIC_FILTERED_ARCHIVE_GENERATION",
  "vmPasswordFile": "/run/nextstop-secrets/vm-owner",
  "cloudPasswordFile": "/run/nextstop-secrets/cloud-owner"
}
```

## Verify the public corpus before either switch

The private transfer deliberately does not copy the public provider corpus,
retention progress, demand leases, schedules or budgets. Keep a separate protected
public-baseline receipt alongside the transfer journal. The following evidence
is a release gate for both forward and reverse routing.

1. Before the final source backup, disable every producer of public state and
   wait for active transactions and jobs to finish. Include VM systemd timers,
   both deployment slots and listenerless workers, direct/admin imports,
   Cloud Scheduler, Cloud Run Jobs and Cloud Tasks dispatch/publishers.
   Prevent updates by independent deployment identities during the change.
   Record UTC freeze/drain times, the paused resources and identities, worker
   CONNECT denial, outstanding queue tasks and the last completed executions.
   Keep queued provider work replayable, honoring its original deduplication and
   budget. A paused scheduler alone says nothing about an already running job.
2. Create and verify the filtered production backup **after** that freeze. Record
   its exact GCS generation, SHA-256 and snapshot time. Use the production
   inventory check in `database-transfer.py prepare-production` for the old
   VM archive. If any import, live publication, retention run, other writer or
   unknown period occurred between the archived snapshot and the freeze, take
   a fresh frozen baseline and restore it. The alternative requires an exact
   captured delta with a rehearsed, verified replay before proceeding. Matching
   counts alone cannot detect an in-place update.
3. On the frozen source and restored target, inventory the same regular
   `nextstop` tables at schema 0015. Exclude the three private tables and the
   migration registry. Compare exact `count(*)` per common table. Compare
   the full active/retired charging and food projection IDs, source dataset
   hashes, publication/retention state, and per-provider availability version
   IDs, source hashes and observation counts. Compare the static provider
   input-check metadata and pending/failed build states. Check stable candidate
   IDs on representative public searches through the restricted API role.
   Keep aggregate results and hashes in the protected receipt. The schema
   registry must correspond to 0015 on the VM and 0019 on Cloud SQL.
4. Record separately the managed-only `live_refresh_control` lease/cooldown,
   `monthly_ingestion_schedule` due dates and `monthly_import_budget`
   month/attempts immediately after migration. Record queue state including
   outstanding tasks against this release. Leave both environments' public
   writers, cleanup jobs and task dispatch stopped through the decision to
   keep or return. Only the auth/report writes covered by the private operator
   may advance while testing the new active endpoint.
5. Immediately before returning, freeze ingress and drain again. Compare the
   new active and retained VM common-table counts, version/hash/retention
   manifests and the three managed-only control tables against the recorded
   baseline. Reconcile intervening job/queue history, including manually
   triggered and newly introduced jobs. If public state advanced, the VM
   cannot simply replay schema-0016–0019 control state. Require a separately
   rehearsed transfer/replay of every new public write and its job/budget
   semantics, or keep the managed endpoint authoritative. Missing evidence,
   a mismatch, or an unaccounted foreign writer blocks both the private
   operation and the corresponding route change.
6. After the keep/return decision and verification, resume public writers on
   exactly one side. Record which deferred tasks were processed or safely
   deduplicated. Never run the same provider import or consume an attempt on
   both environments.

## Close and verify writers

Complete the independent PostGIS owner ACL step on the fully restored and
migrated target before the first cutover. Repeat the ordinary application-role
SQL verification on the intended active side before a forward or reverse
switch. For the legacy VM, include its connectable `template_postgis` database.
A failed check blocks switching ingress. [PostGIS security procedure](../security/POSTGIS-DECODER.md).

1. Restore the verified production filtered backup into the new production
   instance with its verified empty report schema, apply 0016–0019, then verify
   extensions, grants, valid indexes, correct active projections and bounded
   search. Verify identical deployed App ID, signing identities and key values
   privately. Keep the new gateway closed to users. Never use the app's destructive
   integration suite on either database.
2. Freeze releases and operator jobs. Pause schedulers, VM timers, Cloud Tasks
   clients, auth/report endpoints and purge, cleanup and backup jobs targeting the
   side being fenced. Disable route fallback. On that endpoint record the current
   runtime CONNECT grants and their grantors in the operator change record.
   The standard installation already revokes PUBLIC access to `nextstop`.
   Revoke CONNECT **on that database only** from every existing runtime login
   among `nextstop_api`, `nextstop_auth`, `nextstop_support`, `nextstop_worker`
   and `nextstop_backup`. Stop/drain connection pools and operator sessions.
   Take care to retain the sole trusted maintenance login. Administrative and
   backup jobs using the owner credential must remain stopped.
   In a separate authenticated owner session on the **verified** database, the
   following psql statements record the existing direct CONNECT grants and
   revoke the runtime access. Retain the grants as permission metadata. Close
   this psql session afterwards. Reapply exactly the recorded grants only on
   the endpoint to be made active. A nonstandard membership or another writer
   that still has effective access causes the transfer to stop.

   ```sql
   \set ON_ERROR_STOP on
   BEGIN;
   SELECT r.rolname, g.is_grantable, g.grantor::regrole
   FROM pg_database d CROSS JOIN LATERAL aclexplode(d.datacl) g
   JOIN pg_roles r ON r.oid=g.grantee
   WHERE d.datname='nextstop' AND g.privilege_type='CONNECT'
     AND r.rolname IN ('nextstop_api','nextstop_auth','nextstop_support','nextstop_worker','nextstop_backup');
   SELECT format('REVOKE CONNECT ON DATABASE nextstop FROM %I', rolname)
   FROM pg_roles WHERE rolname IN
       ('nextstop_api','nextstop_auth','nextstop_support','nextstop_worker','nextstop_backup')
   \gexec
   COMMIT;
   ```

3. With the newly restored target fenced, record its verified baseline. The source
   may still serve during capture. Supply only configuration and journal paths
   on the command line.

```sh
node deploy/gcp-run/production-private-handoff.mjs capture /run/handoff/config.json /var/lib/nextstop/handoff-01
```

4. Freeze and drain the old VM with the same procedure. The implementation
   checks effective rights, known worker/backup roles, all other nonadministrative logins and outstanding client sessions. It locks all three private tables
   on both endpoints before their contents are read for replacement. At this
   point both sides must be fenced. The owner must coordinate the control plane
   to prevent an independent administrator from restarting a writer.

## Copy, switch or return

Run the same command with `forward` instead of `capture`. It compares the
inactive database to its recorded baseline, transfers the complete current
private tables in one destination transaction, and compares every field before
commit. Field encoding preserves byte values, JSON numbers, SQL and JSON nulls,
and microsecond timestamps. It reports `new` only after it has durably recorded
the result. Keep ingress closed until then. Enable **only** the managed endpoint
using its recorded grants, start its services and check the public and authenticated
paths before resuming jobs. Keep the VM closed to writes.

For a return within four hours, close and drain the managed services and their
jobs, deny database reconnections there and verify that the VM is still fenced.
Run `rollback` against the same endpoints and journal. It uses the **latest
managed state**, including all counters, consumed challenges, withdrawals and
new rows since cutover. `old` confirms the verified reverse commit. Restore
only the VM's original grants and ingress, and repeat readiness/authentication
and search checks before resuming its jobs.

A timeout or connection loss leaves the control plane closed. Repeat the same
operation with the same journal. The recorded intent distinguishes an unchanged
destination from a committed copy with a lost acknowledgement. A changed source
or third destination state stops the transfer. `abort` cancels a preparation or
uncommitted intent while its original destination baseline still matches. A
committed copy is reconciled by retrying its operation. Keep the journal and
resolve any divergence before making either endpoint writable.

The four-hour window starts at capture. Reconciliation of a verified preexisting
commit and guarded removal are available after expiry. New private copies then
fail closed. When the stable endpoint is healthy, run `purge-inactive` while
the other database is still fenced. The operator checks the live CONNECT grants
and the full inactive fingerprint and deletes **only** the three private tables'
rows from the inactive endpoint. Other databases and public data are untouched.
Verify `clean`, remove tmpfs secrets and retire inaccessible inactive storage
under the existing privacy policy. The purge discards the retained rollback
baseline. Keep filtered backup/PITR policy and protected retention separate.

The local regression runs with `NEXTSTOP_TEST_NODE` and `NEXTSTOP_TEST_PG_BIN`:
`python3 -m unittest discover -s deploy/gcp-run -p test_production_private_handoff.py -v`.
It exercises the production transfer engine on two independent synthetic PG17
clusters. The CLI host/instance guard deliberately has no test or staging bypass.
