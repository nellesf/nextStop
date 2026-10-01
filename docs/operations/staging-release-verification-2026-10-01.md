# Staging release verification, 2026-10-01

## Scope and final state

The tests used the separate `nextstop-tech-testing` project, its
`nextstop-backend` VM in `europe-west3-a`, and
`https://api-staging.nextstop.tech`. Production application services, database,
credentials and DNS were unchanged. Staging uses its own database and keys,
seeded only with public provider data. The real staging ingestion worker ran
during the rehearsal; no idle worker substitute was used.

Two trusted-main builds produced these immutable artifacts in
`europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend`:

| Label | Commit | Image digest | Successful explicit staging deployment |
| --- | --- | --- | --- |
| A | `621fabc007f5257cf6f82c75f20d5d4be7a55002` | `sha256:750322806ce4e2aaa378abffbb8d2d2ab12f6e7dc614d7001906c3652d211ff9` | `6782540724` |
| B | `58c73458a8bde7763bf145d5e2923d6797e2b571` | `sha256:6cc43eb3f13ada9de2c7e9dcacba17e71fbbe4323a351d4405bd85e1f9087d49` | `6782615411` |

The backend application code is identical between A and B; their commits differ
in deployment identity verification and documentation. Distinct images exercised
actual digest selection and retained-slot recovery, not an application feature
change. GitHub builds verified the commit/OCI revision binding and reused the
immutable registry tags. `verify-promotion.py` accepted the exact B commit,
image and successful explicit staging deployment.

At the final audit, green B was active and blue A retained. Both API/auth pairs
were ready, all five application containers were running with zero restarts,
and exactly one worker was running B. Nginx matched release state; no pending
release journal or temporary registry credential directory remained.

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

## Simulator connectivity and remaining gates

The named staging broker on loopback port 8765 and the explicit production
legacy broker on port 8766 each minted a token and completed exactly one public
synthetic search successfully. Both searches returned HTTP 200 with a snapshot
and 50 backend candidates. Tokens stayed in memory; both brokers stopped and
released their ports. This validates broker/API connectivity, not a complete
Simulator UI session or real-device App Attest continuity. The production
transition command is in [development.md](../development.md#connected-debug-simulator-search).

CI identity/protection setup and real OIDC image builds passed. The deployments
in this rehearsal used the authorized operator account; GitHub deploy-service-
account execution still needs its first live run. `NEXTSTOP_RELEASES_ENABLED`
remains `false`. The production backup and isolated full restore have not run;
the synthetic restore harness is not evidence of production backup recovery.
Production adoption, protected promotion activation and real-device continuity
verification remain outstanding.

Backend and Swift Core CI passed for B. Its
[iOS CI run](https://github.com/nellesf/nextStop/actions/runs/36852498463)
reported 267 passed, one failed and one skipped test. The failure was
`UserErrorReportUITests/testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable`:
the test could not reveal `info-error-report` after scrolling. This occurred
before report submission or backend access. App/CarPlay unit suites, including
environment and authentication guards, passed. There are no iOS source or iOS
workflow changes between the earlier successful `585f890` run and B; that alone
does not establish the failure's cause. The UI failure remains open for rerun;
do not describe the complete iOS suite as green.
