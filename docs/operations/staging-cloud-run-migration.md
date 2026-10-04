# Staging Cloud Run migration record

Date: 2026-10-04. This is an in-progress operator record, not a cutover receipt.
The source VM still serves `api-staging.nextstop.tech`. Production is unchanged.

## Isolated target

- Project: `nextstop-tech-testing` (`353471052580`), region `europe-west1`.
- Cloud SQL: `nextstop-staging`, PostgreSQL 17.11 / PostGIS 3.6.4, Enterprise
  `db-g1-small`, zonal, 50 GiB SSD, storage auto-growth disabled.
- Authenticated connector required; no authorized public client networks.
- Full instance backups/PITR disabled under ADR 0017. A restricted logical
  backup job excludes report values and exports their schema separately.
- Private buckets: `nextstop-tech-testing-download-cache` (90-day cache) and
  `nextstop-tech-testing-database-backups` (7-day filtered backups, separately
  retained operator evidence). Public access, soft delete and versioning disabled.
- Five private Cloud Run services and five job definitions created. Every service
  has minimum zero / maximum one instance and request-based billing. Four
  schedules were created away from their due times, immediately paused and
  verified without any execution. The gateway has not been made public.

The initial backend artifact is tied to source commit
`add51b336a6cec51f04d3f1e1eedb2037aac69bf`, image digest
`sha256:52d298b27c19ba7de836d2073de31bcf821063c0d4d1598d17c46c06e717693a`,
and release ID `1c907fe7c046`. Cloud Build completed successfully and the registry
manifest, configuration, platform and OCI revision were independently checked.
The registry remains the existing repository in `europe-west3`.

The subsequent private candidate uses commit
`e5592de9c96d4a2e144f32ee07a4a675d9273403`, digest
`sha256:7451101ee4c03cac414e72ded5df6c2c6dd0971df8b72b77564c54f662c40806`,
and release `a2939e6f73e9`. Only the IAM-private live service's stable traffic has
advanced to this candidate during commissioning; the public staging domain still
reaches the source VM. All four schedules remain paused.

## Performed checks

- The managed database accepted restricted-role bootstrap, including Cloud SQL's
  explicit administrator role grants. Runtime accounts have no inherited roles.
- A report-data-excluding snapshot of the existing staging database was captured
  without provider downloads. The 2,858,317,358-byte archive has SHA-256
  `473b326d8c104f586bd02a06c47311480ffcbe8fb733fd13a1368ce0b44daa8c`.
  Its table-data inventory was validated before the single-transaction restore.
- The initial restore completed in 5352 seconds. All indexes are valid, the
  charging and food active-version identities are preserved, and report rows
  remain zero. The real migration job applied all 18 migrations and verified the
  restricted object grants. Database size after restore was approximately 21.65 GiB.
- Raw Cloud Run request logs were excluded before sending test requests. No user
  routes, report values, client addresses or credentials enter operator evidence.
- All private services and job definitions reached platform Ready status. This
  does not establish database readiness or candidate-search correctness.
- The IAM-only simulator broker returned the expected short-lived token contract.
- A real two-source gateway probe passed with nine invalid-schema requests:
  source A was rate-limited, independent source B remained admitted, then A
  remained rate-limited. Changing caller-supplied forwarded prefixes did not
  bypass the limiter. The probe created no App Attest database state.
- The live release preflight confirmed the private IAM boundaries, immutable
  revision configuration, approved SQL sizing and raw-request-log exclusion.
- Five synthetic source-VM searches returned identical static results. Their
  latencies were 2333, 326, 340, 328 and 330 ms (median 330 ms). No availability
  requests or provider refreshes were triggered by this comparison.
- Five corresponding Cloud Run searches returned the same static result hash and
  50 candidates: 9391, 442, 459, 497 and 426 ms. The four follow-up requests had a
  median of 450 ms, versus 329 ms for the source follow-ups. The first observation
  is not a formally isolated cold-start measurement; initial database autovacuum
  was still completing during these checks. Three direct candidate SQL probes
  completed in 1770, 244 and 1112 ms with no temporary I/O. These search checks do
  not establish full import capacity.
- Two concurrent Swiss availability requests enqueued exactly one live task.
  The task published 15,240 observations but returned 503 approximately 30 seconds
  later. Code inspection and timing point to unbounded post-publication retention
  hitting the live SQL timeout; the exact database error code was not captured.
  The queue was temporarily paused with the retry preserved. The correction moves
  Cloud Run retention to the bounded hourly cleanup job, leaving the VM default
  unchanged. After advancing the private live service, the retained task retried
  successfully at 12:04 UTC: 15,240 observations published, lease released, queue
  empty. The queue is running. A subsequent concurrent-request gate observed a
  fresh successful publication but failed an ambiguous combined queue check.
  The gate now distinguishes actual task identities, dispatches and estimated
  queue size, retaining strict completion and cache-reuse checks. A fresh full
  gate pass remains pending.
- Five searches against the subsequent candidate returned the same static hash
  and 50 candidates in 904, 389, 375, 386 and 419 ms; the four follow-up median was
  388 ms. Readiness matched the immutable image. The two-source IP isolation and
  forwarded-prefix resistance check also passed again. These were not isolated
  cold-start measurements.
- The filtered Cloud Run backup completed in about 24 minutes. Its
  2,859,257,809-byte archive has SHA-256
  `f3648bc3cb9b67096de725883e477c952e5268a80f700512ad7289d3e4dde18a`.
  Generation-pinned download and hashes passed. Two private local restore runs
  restored all data, matched the pre-backup counts for all 26 tables, verified
  all 18 migrations, valid indexes, active versions and restricted grants.
  Both stopped during post-restore statistics preparation before synthetic
  searches. Full recovery acceptance remains pending diagnosis of that phase;
  successful data restoration alone is not a completed recovery gate.
- The first bounded cleanup deleted 64 expired live snapshots and 975,360
  observations, then stopped during charging projection retention. A worker-role
  probe reproduced the parent-delete timeout at 2 seconds. Rollback-only EXPLAIN
  isolated a foreign-key cascade choosing the spatial GiST index for empty
  version/park lookups. A transaction-local generic-plan setting used the compound
  primary key in the comparison and reduced measured 250/1,000-row cleanup
  batches to 36/60 ms. The branch applies this setting only within cleanup
  transactions. Active versions are unchanged; a new complete job run is pending.
- The real report-purge job succeeded against an empty report table. Deletion of
  expired report rows is covered by synthetic tests, not by that empty live run.
- Monitoring observed zero active and zero idle instances for every service:
  API at 10:29 UTC, live at 10:30, and auth/broker/gateway at 10:37. These are
  explicit per-service zero measurements, not missing time-series points.
- Domain ownership for `nextstop.tech` was confirmed with Google. The new mapping
  requires CNAME `api-staging` to `ghs.googlehosted.com.`. Existing DNS is unchanged;
  certificate issuance and cutover remain pending.
- Backend, Swift Core and iOS CI passed for infrastructure commit `40cccf9`.
  The earlier artifact-commit iOS run failed at
  `testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable` because
  `info-error-report` was not reachable; the subsequent run passed without a
  Swift source change. This intermittent failure remains a recorded limitation.
- Deployment IAM is restricted to the existing stage services/jobs/queue,
  runtime identities, SQL metadata and the acceptance-evidence object prefix.
  It grants no direct secret payload or database-backup reads. Fourteen actual
  principal permission/contract checks passed, including SQL-list and backup-
  prefix read denials plus self-OIDC/private-broker access. Probe markers and
  temporary permissions were removed. The original cleanup misclassified a
  canonicalized Google-account alias; a separate corrective receipt confirms
  removal of the exact remaining probe binding and role. Actual scheduler
  pause/resume by CI and the main-branch WIF workflow remain unexercised.

## Remaining acceptance work

Measure full import capacity, disk peaks and isolated cold starts; deploy and
exercise the corrected live Tasks, cleanup, purge and monthly job budgets; restore
the new filtered backup; refresh artifact-bound checks and verify the final writer
handoff. Only then
switch DNS, check managed TLS and authenticated public searches, activate reviewed
schedules and retire the obsolete paid VM resources after recovery verification.

Staging's `NEXTSTOP_RELEASES_ENABLED` override is false while migration is active,
preventing the old main-branch workflow from redeploying the VM during handoff.
The production release control is unchanged. The feature branch has not been
merged into main, and the new Cloud Run workflow must not be enabled before its
configuration and actual acceptance evidence have been committed and reviewed.

## Cost evidence

The user-provided baseline was approximately EUR 70/month. The Google Cloud Billing
report for October 1–3 was subsequently checked for the staging project alone,
without credits: EUR 6.80 before tax over 72 hours, equivalent to EUR 68.94 net
at 730 hours. This is a comparison rate, not a full monthly invoice.
The dated list-price model in `deploy/gcp-run/cost-plan.json`, including hourly
bounded cleanup, estimates EUR 42.04–59.13 net/month including 10% reserve, or
EUR 50.02–70.36 with illustrative 19% VAT. New-runtime usage is not yet present in
that billing period, so actual new charges are still unverified. Compare like tax
bases. The source VM and target temporarily
overlap during migration. Stopping the VM alone would retain disk/address costs.
Keep actual billing validation and the first full import as separate acceptance
evidence; report a projected overrun before any unapproved resize or teardown.
