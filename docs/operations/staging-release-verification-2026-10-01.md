# Staging release verification, 2026-10-01

This is the historical staging and restore record for 2026-10-01. For the later
owner approval and first production attempt, see the
[production verification record for 2026-10-02](production-release-verification-2026-10-02.md).

## Scope and final state

The release-switching tests used the separate `nextstop-tech-testing` project, its
`nextstop-backend` VM in `europe-west3-a`, and
`https://api-staging.nextstop.tech`. Production application services, database,
credentials and DNS were unchanged. Staging uses its own database and keys,
seeded only with public provider data. The real staging ingestion worker ran
during the rehearsal; no idle worker substitute was used.

The operator rehearsal and subsequent CI rollout used these trusted-main artifacts in
`europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend`:

| Label | Commit | Image digest | Successful explicit staging deployment |
| --- | --- | --- | --- |
| A | `621fabc007f5257cf6f82c75f20d5d4be7a55002` | `sha256:750322806ce4e2aaa378abffbb8d2d2ab12f6e7dc614d7001906c3652d211ff9` | `6782540724` |
| B | `58c73458a8bde7763bf145d5e2923d6797e2b571` | `sha256:6cc43eb3f13ada9de2c7e9dcacba17e71fbbe4323a351d4405bd85e1f9087d49` | `6782615411` |
| CI | `9ec36e860f1abc0c4f1872888eb83483d5249156` | `sha256:21083d7cc09f376c7fe90fb9eebf3b78a5ee83a19916d2fe79dd0060d8173a08` | `6783984468` |

The backend application code is identical between A and B; their commits differ
in deployment identity verification and documentation. Distinct images exercised
actual digest selection and retained-slot recovery, not an application feature
change. GitHub builds verified the commit/OCI revision binding and reused the
immutable registry tags. `verify-promotion.py` accepted the exact B commit,
image and successful explicit staging deployment.

At the end of the operator rehearsal, green B was active and blue A retained. Both API/auth pairs
were ready, all five application containers were running with zero restarts,
and exactly one worker was running B. Nginx matched release state; no pending
release journal or temporary registry credential directory remained.

The later [staging CI run for `9ec36e8`](https://github.com/nellesf/nextStop/actions/runs/36860547909)
completed successfully. Its explicit deployment record `6783984468` is successful,
public readiness identifies the CI image above, and `verify-promotion.py` accepted
the exact commit, image and successful staging deployment binding. The final
host audit at 12:22:22 UTC passed: blue API/auth returned HTTP 200 readiness with
the exact CI digest, retained green B was ready, exactly one worker was running,
and checked containers had zero restarts. The database was healthy with 15
migrations applied. Nginx matched saved state; no pending release journal,
temporary registry credential directory or temporary upload remained.

## Live release and recovery checks

Times below are UTC.

1. Deploy A, then start authenticated public search probes and deploy B. Both
   public readiness endpoints identified the selected image. Normal deployment
   included migration/readiness/search gates, graceful Nginx switching and real
   singleton worker replacement.
2. At 11:12:01–11:13:14, deploy a candidate using an intentionally absent
   certificate directory and `--skip-migrations`. Candidate private readiness
   and search gates passed; the missing-certificate activation gate then
   rejected the release before proxy switching. The entire prior release state,
   Nginx bytes, active green API/auth container identities/start times and worker
   identity/start time remained unchanged. Retained blue A was recreated and
   passed readiness. Temporary registry credentials were removed afterward.
3. At 11:13:34–11:13:42, explicitly roll back B to retained A. Public API and
   auth readiness both reported A; searches continued successfully.
4. At 11:14:29–11:15:16, roll forward by selecting retained B. Public API and
   auth readiness both reported B at 11:15:17. Continue search samples before
   stopping the probe cleanly.

The controlled rejection verifies activation failure recovery. It is not a
malformed-build/readiness-failure test. Rollbacks used retained local images and
did not restore or reverse database schema changes.

## Sampled search continuity

The bounded probe held a short-lived token only in memory and used one fixed
synthetic search. It sent sequential requests at a minimum five-second interval,
with a 20-second timeout and no overlapping requests or catch-up bursts. Logs
contained only timestamps, status, outcome and latency, never tokens, search
payloads or responses.

| Measurement | Result |
| --- | --- |
| First / last completed sample | 11:03:12.733 / 11:16:25.449 UTC |
| Successful searches | 146 / 146, HTTP 200 with valid nonempty candidates and snapshot |
| Failed searches | 0 |
| Median latency | 451.25 ms |
| p95 latency | 7,866.7 ms |
| Maximum latency | 8,411.4 ms |
| Requests exceeding five seconds | 29 |
| Maximum interval between request starts | 8.41 seconds |

These samples found no failed search during the exercised transitions. They
cannot exclude interruptions between samples or establish a load/SLA guarantee.
The high tail latency remains a material observation; successful status codes
do not establish consistently fast responses. The configured Nginx limiter uses
`nodelay` and the API concurrency guard rejects excess work immediately; neither
introduces a waiting queue. All samples returned 200, and the probe stayed below
the configured rate. A later aggregate VM snapshot at 11:18:40 showed no current
CPU or memory saturation, but it cannot establish the cause of earlier spikes.
CPU/database contention during ingestion or switching remains a hypothesis;
client timing also includes DNS, TLS and network time. No cause was isolated and
no performance tuning was added. This setup retains the existing single-VM
resource and failure model.

## Real production backup and isolated restore

The owner explicitly authorized a consistent production backup including private
App Attest state and excluding all `user_error_reports` data. The existing backup
helper validated and uploaded the archive to the designated private bucket. A
separate private download of its exact immutable generation passed checksum and
size verification. The backup object identifier, receipt and private contents
are not part of this repository record.

The full application schema was restored into a disposable native macOS
PostgreSQL cluster with a private Unix socket, fresh credentials and no production
signing keys or worker. The test used artifact B's exact source commit. Ordinary
staging received no production authentication or report data.

| Verification | Result |
| --- | --- |
| Archive size | 2,534,700,328 bytes / 2.361 GiB |
| Restore and verification duration | 251 seconds |
| Exact-generation archive integrity | Passed |
| Full application-schema restore | Passed |
| Private auth preservation and report-data exclusion | Passed |
| Candidate migration, function ownership, runtime grants and valid indexes | Passed |
| API and auth readiness | Passed |
| Authenticated synthetic campus and food searches | Passed |
| Private local archives, credentials, cluster and test-process cleanup | Passed |

The source was PostgreSQL 17.5/PostGIS 3.5.2; the target was native PostgreSQL
17.11/PostGIS 3.5.6 with `btree_gist` 1.7 and locale `C`. This establishes logical
restore compatibility, not an exact Linux/container copy, production recovery
cutover or auth-counter continuity after reverting production state. No production
application, schema, worker, credentials or DNS was changed. The exact-image and
one-hour receipt requirements remain in force for every production migration.
Only the private receipt and sanitized technical evidence were retained locally.

A separate bounded production probe returned HTTP 200 for **21 of 21** synthetic
search requests, sampled once per minute during the backup activity. No private
auth contents or individual registration counts were emitted. These samples
cannot exclude interruptions between requests or establish a latency/load SLA.

## Simulator connectivity and remaining gates

The named staging broker on loopback port 8765 and the explicit production
legacy broker on port 8766 each minted a token and completed exactly one public
synthetic search successfully. Both searches returned HTTP 200 with a snapshot
and 50 backend candidates. Tokens stayed in memory; both brokers stopped and
released their ports. This validates broker/API connectivity, not a complete
Simulator UI session or real-device App Attest continuity. The production
transition command is in [development.md](../development.md#connected-debug-simulator-search).

CI identity/protection setup and real OIDC image builds passed. The initial
deployments in the recovery rehearsal used the authorized operator account. Automatic
releases were briefly enabled for a direct staging CI attempt, but
[run `36858146070`, attempt 2](https://github.com/nellesf/nextStop/actions/runs/36858146070/attempts/2)
failed early at 12:00 UTC before any SSH operation was observed. Automatic releases
were paused. Investigation of the SDK/account-selection code confirmed a stale
gcloud `core/account`: after
builder authentication and SDK setup, switching to deploy authentication without
another SDK setup left OS Login profile lookup selecting the builder account
while token authentication used the deploy identity. A second SDK setup and
explicit identity guard corrected the selection; `actionlint` passed. The later
successful live staging CI run `36860547909` validated the correction under the
deploy identity. No IAM expansion was required. `NEXTSTOP_RELEASES_ENABLED=true`
was active at the close of this record. Production still served its legacy deployment.
[Production promotion run `36861316291`](https://github.com/nellesf/nextStop/actions/runs/36861316291)
targets the exact `9ec36e860f1abc0c4f1872888eb83483d5249156` commit and CI image
listed above and was **waiting for owner review** at the close of this record.
Review had been requested; the run was not yet approved or deployed. First
production adoption and real-device App Attest continuity verification remained
outstanding at that point.

Backend and Swift Core CI passed for B. Its earlier
[iOS CI run](https://github.com/nellesf/nextStop/actions/runs/36852498463)
reported 267 passed, one failed and one skipped test. The failure was
`UserErrorReportUITests/testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable`:
the test could not reveal `info-error-report` after scrolling. This occurred
before report submission or backend access. App/CarPlay unit suites, including
environment and authentication guards, passed. The subsequent complete
[iOS CI run for `6c33d4b`](https://github.com/nellesf/nextStop/actions/runs/36854802506)
passed without an app change, closing the outstanding rerun check. The earlier
UI failure did not reproduce; its precise cause was not isolated. The later full
[iOS CI run for `e106f2e`](https://github.com/nellesf/nextStop/actions/runs/36857990355)
also passed. Backend and Swift Core CI passed for `9ec36e8`; its iOS run is still
running. The iOS app sources are unchanged since the last complete green
`e106f2e` run, but the new iOS run is not yet recorded as successful.
