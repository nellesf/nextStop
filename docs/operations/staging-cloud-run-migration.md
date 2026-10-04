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

Complete and verify the database restore, additive migration and grants; measure
full-corpus search/import capacity and cold starts; exercise live Tasks and job
budgets; restore a new filtered backup; prove idle scale-to-zero using Monitoring;
verify the restricted deployment identity and final writer handoff. Only then
switch DNS, check managed TLS and authenticated public searches, activate reviewed
schedules and retire the obsolete paid VM resources after recovery verification.

Staging's `NEXTSTOP_RELEASES_ENABLED` override is false while migration is active,
preventing the old main-branch workflow from redeploying the VM during handoff.
The production release control is unchanged. The feature branch has not been
merged into main, and the new Cloud Run workflow must not be enabled before its
configuration and actual acceptance evidence have been committed and reviewed.

## Cost evidence

The user-provided baseline is approximately EUR 70/month, with unknown tax basis.
The dated list-price model in `deploy/gcp-run/cost-plan.json` estimates EUR
41.27–55.19 net/month including 10% reserve, or EUR 49.12–65.67 with illustrative
19% VAT. This is a model, not measured billing. The source VM and target temporarily
overlap during migration. Stopping the VM alone would retain disk/address costs.
Keep actual billing validation and the first full import as separate acceptance
evidence; report a projected overrun before any unapproved resize or teardown.
