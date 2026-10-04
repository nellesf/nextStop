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

The cleanup correction is deployed to private candidate definitions and jobs
from commit `42ac95d87a0475b744ce6f8e0a3a73e1f8ae206a`, digest
`sha256:5517a80839c50bb3a806e65999fb8955b5034298b97bc858eda3042156e88697`,
release `66307ff9d3a7`. Registry/OCI verification and candidate preflight passed.
Existing stable service traffic was preserved when applying these definitions.

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
  queue size, retaining strict completion and cache-reuse checks. The fresh gate
  passed at 12:38 UTC on release `a2939e6f73e9`: one expected task identity seen,
  one dispatch, one provider attempt, one publication, released lease and shared
  cache reuse. The later cleanup-only runtime change leaves this live-task
  acceptance source scope and its configuration unchanged.
- Five searches against the subsequent candidate returned the same static hash
  and 50 candidates in 904, 389, 375, 386 and 419 ms; the four follow-up median was
  388 ms. Readiness matched the immutable image. The two-source IP isolation and
  forwarded-prefix resistance check also passed again. These were not isolated
  cold-start measurements.
- The filtered Cloud Run backup completed in about 24 minutes. Its
  2,859,257,809-byte archive has SHA-256
  `f3648bc3cb9b67096de725883e477c952e5268a80f700512ad7289d3e4dde18a`.
  Generation-pinned download and hashes passed. Private local restore attempts
  restored all data, matched the pre-backup counts for all 26 tables, verified
  all 18 migrations, valid indexes, active versions and restricted grants.
  Initial runs stopped during post-restore statistics preparation because the
  local rehearsal helper passed a timeout as a positional database name. After
  making database/timeout keyword-only and testing the actual wrapper, the full
  rehearsal passed: 413 seconds for data restoration, all 26 statistics passes,
  and three actual API-role synthetic SQL searches returning 51/34/51 rows in
  341/126/127 ms. The private local cluster was stopped and removed. This proves
  recovery using PG 17.11/PostGIS 3.5.6, not identical Cloud SQL runtime behavior;
  the managed target uses PostGIS 3.6.4 and has separate real search checks.
- The first bounded cleanup deleted 64 expired live snapshots and 975,360
  observations, then stopped during charging projection retention. A worker-role
  probe reproduced the parent-delete timeout at 2 seconds. Rollback-only EXPLAIN
  isolated a foreign-key cascade choosing the spatial GiST index for empty
  version/park lookups. A transaction-local generic-plan setting used the compound
  primary key in the comparison and reduced measured 250/1,000-row cleanup
  batches to 36/60 ms. The branch applies this setting only within cleanup
  transactions. The corrected real job `nextstop-cleanup-5xlzw` succeeded in
  41.79 seconds, deleting the remaining 50 expired live snapshots and 32,000 old
  park rows within its batch limit. Charging/food active versions are unchanged;
  20,607 park rows remain for a later bounded cleanup. No expired live snapshots
  remained at the follow-up check. Five searches against release `66307ff9d3a7`
  passed during this commissioning interval with identical static results and
  latencies of 799/428/388/390/397 ms.
- The real report-purge job succeeded against an empty report table. Deletion of
  expired report rows is covered by synthetic tests, not by that empty live run.
- One full shadow monthly import, `nextstop-monthly-9wr7x`, started at 12:45 UTC
  against release `66307ff9d3a7`. A fresh preflight verified its exact definition,
  four paused schedules, no unfinished jobs, 22.45 GiB physical database storage,
  and zero previous monthly attempts. Only the two next-due timestamps were
  advanced; existing import/hash/publication state was not reset. The persistent
  budget records attempt one. Charging succeeded after 382 seconds and published
  active version `9ee02b82-b3b0-476c-a275-14a3352bcbe9`; its next due date is
  November 1. Food failed within 0.36 seconds, preserving its prior active
  version and October 5 12:52 UTC retry date. The whole execution correctly failed.
  The observed maxima were 23.22 GiB SQL disk, 63.5% SQL CPU, 50.9% SQL memory
  and a 955 MB sampled worker memory mean, below the fixed limits. These sampled
  values are not continuous exact peaks, and food capacity remains unverified.
  The canonical German Geofabrik URL was independently observed returning 307
  to the exact `ftp5.gwdg.de` German latest-file mirror, which the existing
  same-host response validator rejected. The [GWDG index](https://ftp.gwdg.de/)
  identifies Geofabrik as upstream, and its
  [mirror inventory](https://ftp5.gwdg.de/pub/misc/openstreetmap/download.geofabrik.de/)
  confirms that exact public file. The branch permits only that additional
  canonical-to-mirror mapping, validates each redirect before requesting it and
  cancels rejected responses. The Swiss canonical download still redirects to
  a dated file on the same Geofabrik host. 218 unit/broker tests, 17 targeted
  downloader/cache tests, lint, typecheck and build passed for this correction;
  the corrected artifact `3367b57` is deployed privately as release
  `e6e199e52f6f` (digest `sha256:cacaa7e3735545d1bac39f94033084e249dc1e0bdb05f57ae9b0210c7f7d2a0a`).
  All eleven definition steps and the candidate preflight passed. Five searches
  returned the same 50-candidate static hash as the VM in 1,224/408/406/407/400 ms;
  readiness, exact API/Auth digest and forwarded-prefix resistance also passed.
  A successful food import remains pending. The owner explicitly authorized one
  early food retry on October 4 after the correction; this exception does not
  change the normal 24-hour retry policy or reset the monthly attempt budget.
  The failed job did not
  log its precise exception, so the Cloud Run failure reason itself was not
  captured beyond the failed food outcome; the redirect rejection is independently
  reproducible from the deployed validator and observed response.
- The authorized retry `nextstop-monthly-xg8qd` started at 13:22:41 UTC on the
  corrected image. The ordinary job reserved attempt two; charging remained due
  November 1. The German 4,853,352,453-byte and Swiss 547,603,457-byte PBF objects
  and manifests were successfully cached at 13:25:41 and 13:26:03 UTC. Subsequent
  processing reads generation-pinned cache streams, not repeated provider
  downloads. Three concurrent synthetic searches with the McDonald's filter at
  13:31 UTC returned the same 31 static candidates in 2,399/2,389/2,477 ms while
  that processing continued. This is a small concurrent check, not a broad load
  benchmark. Final food publication and capacity acceptance remain pending.
  Some Cloud Run CPU distributions had a finite mean outside their reported
  occupied histogram bounds. The revised read-only monitor preserves means and
  other metrics, marks these histogram conflicts for review and reports their
  derived upper bound as unknown. It does not shift bucket indices or claim an
  exact continuous resource peak.
- Monitoring observed zero active and zero idle instances for every service:
  API at 10:29 UTC, live at 10:30, and auth/broker/gateway at 10:37. These are
  explicit per-service zero measurements, not missing time-series points.
- The five `66307ff9d3a7` revisions separately reported zero active and idle
  instances at 13:02 UTC. After that observation and no intervening service
  requests, searches at 13:03 UTC took 5,780/413/405/386/397 ms and returned the
  same static result hash even after the charging publication. This first search
  followed observed scale-to-zero; broker token acquisition occurred separately
  before its measured interval. It is not a full end-user fresh-login latency.
- Domain ownership for `nextstop.tech` was confirmed with Google. The new mapping
  requires CNAME `api-staging` to `ghs.googlehosted.com.`. Existing DNS is unchanged;
  certificate issuance and cutover remain pending.
- Backend, Swift Core and iOS CI passed for infrastructure commit `40cccf9`.
  The earlier artifact-commit iOS run failed at
  `testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable` because
  `info-error-report` was not reachable; the subsequent run passed without a
  Swift source change. This intermittent failure remains a recorded limitation.
  All three CI workflows also passed for commits `e5592de`, `42ac95d` and
  downloader artifact `3367b57`.
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

Complete the food import after the downloader correction, its capacity checks and
the monthly budget checks; refresh artifact-bound checks and verify the final writer
handoff. Only then
switch DNS, check managed TLS and authenticated public searches, activate reviewed
schedules and retire the obsolete paid VM resources after recovery verification.

Provider source changes now invalidate the import-budget and database-performance
acceptance fingerprints. Regression coverage checks modification, addition and
deletion of provider files while retaining unrelated IP, recovery, live-task and
idle evidence. A changed downloader must not silently reuse an old import check.

Staging's `NEXTSTOP_RELEASES_ENABLED` override is false while migration is active,
preventing the old main-branch workflow from redeploying the VM during handoff.
The production release control is unchanged. The feature branch has not been
merged into main, and the new Cloud Run workflow must not be enabled before its
configuration and actual acceptance evidence have been committed and reviewed.

## Pending final writer handoff and DNS bridge

This procedure is prepared, not executed. It applies only to the source VM
`nextstop-backend` in `nextstop-tech-testing/europe-west3-a` and the reviewed Cloud
Run/Cloud SQL target in the same project, region `europe-west1`. Production is
unchanged. Keep the staging CI release override false and the four target
schedules paused while completing the existing acceptance work above.

The source configuration exactly matched the repository HTTPS template rendered
for the green slot. Both prepared freeze/bridge configurations passed `nginx -t`
on that VM using temporary alternative main configurations. No serving file was
changed and no reload occurred; all temporary test files were removed.

1. **Prepare the final routing change.** Review the entire proposed Nginx
   configuration before touching the source. Reuse its current staging TLS
   certificate, route allowlist, method/body limits, rate limits and redacted
   diagnostics. The temporary upstream is the fixed public gateway origin
   `https://nextstop-gateway-353471052580.europe-west1.run.app`, never
   `api-staging.nextstop.tech` itself. Set upstream Host and TLS SNI to that
   `run.app` host and explicitly verify its certificate with the system CA.
   Preserve the app Authorization header; remove caller-provided
   `X-Forwarded-For`, `Forwarded`, `X-Real-IP` and
   `X-Serverless-Authorization`. Disable request/response buffering and upstream
   retries, and provide no fallback to the old application containers. No new
   proxy product, permanent VM proxy or trusted-forwarded-header exception is
   required.

2. **Freeze old writers and recheck private state.** Keep the target gateway
   private during the final state transfer. Briefly block new source Auth/Report
   requests, drain in-flight requests, then gracefully stop all source API/Auth
   containers, including retained/legacy slots, and the worker. Leave the source
   database and Nginx running; confirm the old application writer sessions have
   ended. Recheck `app_attest_keys`, `app_attest_challenges` and
   `user_error_reports` on both staging databases, recording only empty/nonempty
   booleans. If all are empty, no private delta archive is needed. Preserve the
   staging signing keys and verify equality without printing values. This is a
   brief deliberate write freeze, not a proven uninterrupted Auth handoff.

   If unexpected private rows exist, stop the zero-row shortcut. Transfer only
   these three tables privately with both old and target writers quiescent,
   preserving original counters, challenge consumption, report deletion state
   and expiry timestamps. The checked-in `database-transfer.py --purpose handoff`
   prepares a full-schema snapshot; it is not a delta importer for the already
   populated target. Review that narrow transfer before executing it, and remove
   its exact temporary copies within the existing four-hour handoff window.
   Never upload report-containing handoff data as a durable backup.

3. **Activate one writer destination.** After the final state check/transfer,
   expose only the reviewed gateway, with API/Auth/live/broker still IAM-private.
   Apply the reviewed Nginx bridge once, using `nginx -t` followed by a graceful
   reload. Check readiness and an authenticated synthetic search through the old
   endpoint before changing DNS. Clients with a cached old address then reach
   the same Cloud SQL-backed services as new clients. They temporarily share the
   VM's source-IP budget at the Cloud Run gateway; accept this bounded staging
   limitation without trusting forged forwarded headers. Keep all old
   application writers stopped. Once the target accepts writes, a rollback must
   keep that authoritative database; routing back to the stale VM database is
   not a safe rollback.

4. **Switch DNS and verify the public path.** Replace the staging DNS record
   with the already requested CNAME `api-staging` to `ghs.googlehosted.com.`.
   Check the managed domain/certificate status and HTTPS readiness on
   `api-staging.nextstop.tech`, including the expected API/Auth release digest.
   Use the existing `verify.verify_public` helper for the broker-authenticated
   synthetic search. This proves the public route and token path, not a real
   device App Attest assertion. The Nginx bridge covers cached old DNS; it does
   not establish readiness of the newly issued managed certificate. Retain it
   only through the observed DNS transition, rather than as ongoing hosting.

5. **Resume schedules and retire paid VM resources.** After the reviewed
   public and recovery checks pass, explicitly resume the four commissioned
   schedules (`nextstop-monthly`, `nextstop-cleanup`, `nextstop-report-purge`,
   `nextstop-backup`) with ordinary scoped Cloud Scheduler commands. The
   commissioning helper intentionally leaves them paused, and `deploy.py`
   restores only schedules that were enabled before its run. Preserve the
   measured monthly due dates/budget; do not force another import when enabling
   the daily due check. Once the DNS bridge is no longer required, retire the
   exact source VM, its boot disk, the separately retained `nextstop-data` disk
   and the regional `nextstop-staging-ip` reservation, checking ownership and
   attachments first. The VM was provisioned with deletion protection and the
   data disk with `auto-delete=no`; stopping/deleting the VM alone is not proof
   that its disk/address charges ended. Use the existing GCP CLI, without adding
   a teardown framework or retaining report-bearing disk snapshots as backups.

6. **Keep CI separate from initial commissioning.** The branch may be deployed
   manually under the staging migration authorization. Main has not been
   authorized for merge. Before any later CI activation, commit the actual
   `deploy/environments/staging-cloud-run.json` with numeric secret versions and
   generation/hash-pinned real acceptance evidence, and obtain the separate
   main-merge instruction. Only when main contains the reviewed Cloud Run path
   may staging select `NEXTSTOP_STAGING_HOSTING=cloud-run` and re-enable
   `NEXTSTOP_RELEASES_ENABLED`. Enabling the old main workflow early could
   redeploy the VM. The first trusted-main WIF release still has to exercise the
   real CI path; an operator service-account probe is not that evidence.

## Cost evidence

The user-provided baseline was approximately EUR 70/month. The Google Cloud Billing
report for October 1–3 was subsequently checked for the staging project alone,
without credits: EUR 6.80 before tax over 72 hours, equivalent to EUR 68.94 net
at 730 hours. This is a comparison rate, not a full monthly invoice.
The dated list-price model in `deploy/gcp-run/cost-plan.json`, including hourly
bounded cleanup and the actual 2 CPU/8 GiB daily due-check allocation, estimates
EUR 42.09–59.18 net/month including 10% reserve, or EUR 50.09–70.43 with
illustrative 19% VAT. New-runtime usage is not yet present in
that billing period, so actual new charges are still unverified. A fresh Billing
UI check at 13:18 UTC still showed usage only through October 3. Compare like tax
bases. The source VM and target temporarily
overlap during migration. Stopping the VM alone would retain disk/address costs.
Keep actual billing validation and the first full import as separate acceptance
evidence; report a projected overrun before any unapproved resize or teardown.
