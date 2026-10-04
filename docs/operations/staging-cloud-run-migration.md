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

The backend artifact is tied to source commit
`add51b336a6cec51f04d3f1e1eedb2037aac69bf`, image digest
`sha256:52d298b27c19ba7de836d2073de31bcf821063c0d4d1598d17c46c06e717693a`,
and release ID `1c907fe7c046`. Cloud Build completed successfully and the registry
manifest, configuration, platform and OCI revision were independently checked.
The registry remains the existing repository in `europe-west3`.

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
  The queue was paused with the retry preserved. The branch correction moves
  Cloud Run retention to the bounded hourly cleanup job, leaving the VM default
  unchanged. A successful real task retry and fresh coalescence gate remain pending.
- A new Cloud Run filtered backup was started after capturing all 26 table counts
  in one read-only repeatable-read transaction. Schedules and the live queue
  remain paused while the backup comparison snapshot is held unchanged. Completion
  and restoration of this new backup remain separate acceptance checks.
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
