# Staging demand-driven ingestion, 2026-10-04

## Scope and cost baseline

The owner authorized staging only and supplied approximately **EUR 70/month**
as the comparison ceiling. The tax basis, credits and exact invoice period were
not supplied. Production and TestFlight remain on their existing configuration.

The initial implementation removes idle Swiss live polling and changes static
charging/OSM imports to monthly runs. It reuses the existing VM, database, disks,
cache, IP and TLS proxy. It does **not** implement scale-to-zero hosting or claim
a reduction in the fixed VM bill. A later hosting migration needs a measured
workload, a separate cost comparison and the required provider access.

Read-only inventory at approximately 05:48 UTC on 2026-10-04:

| Item | Existing staging allocation or measurement |
| --- | --- |
| Project / VM | `nextstop-tech-testing` / `nextstop-backend`, `europe-west3-a` |
| Compute | One running `e2-standard-2`: 2 vCPU, 8 GiB RAM |
| Persistent disks | 30 GiB boot + 150 GiB balanced data disk |
| Network | One reserved external IPv4; no load balancer, NAT or router |
| Other paid infrastructure | No snapshots, reservations, commitments or buckets found in this project |
| Database size | 24,463,199,379 bytes (22.78 GiB) |
| Existing OSM/provider caches | 948,291,609 bytes combined (0.883 GiB) |

Cache size is an observation, not a peak-storage guarantee. Downloads can retain
old and new copies, and the configured per-source download bound is larger.

The current public EUR list-price estimate for the existing VM and disks is
approximately EUR 74.47 per 730-hour month, before IP/usage, discounts, credits
and tax. It is **not an actual billed amount** and does not replace the owner's
EUR 70 baseline. An accessible Billing export was not found. The existing local
cost dashboard omits `nextstop-tech-testing` and estimates inventory prices;
it cannot establish billed costs for this change.

No extra always-on allocation is required by this implementation. Holding the
allocation constant keeps its fixed infrastructure charge unchanged. Usage,
artifact storage and one-time release activity still require a later billing
comparison; an invoice-level non-increase cannot be certified in advance.
Budget alerts must not automatically stop or delete service resources.

## Activation and recovery

Use [ADR 0019](../adr/0019-demand-driven-staging-ingestion.md) and the existing
immutable-image release runner. Build off the serving VM, and require successful
backend/PostGIS CI for the exact branch commit before deployment. Do not weaken
main-only production or CI federation rules to stage an experiment.

On the verified staging host, install and run
`deploy/releases/configure-staging-ingestion.py --enable` with the existing
root-only host and private environment files. The helper checks both staging
identity and hostname before writing. It creates a dedicated private signal
credential without printing it. Then deploy the tested digest through
`deploy/gcp-vm/deploy.sh --environment staging --image <registry@sha256:digest>`.

The helper changes configuration only; activation occurs with the gated release.
Port 8091 stays inside the Docker network. Additive migrations preserve old
application readers/writers. Existing search readiness, authenticated synthetic
search, proxy-switch and retained-slot rollback gates continue to apply.

To restore the previous schedule, run the helper with `--disable`, then deploy
the selected tested digest through the same gates. A prior image ignores the
new opt-in flags. Never reverse the additive migrations during rollback.

## Exact artifact and release

- Branch: `codex/staging-demand-driven`, application commit
  `eaa0076851be8f8b1bdb0300bacfc495324c8839`.
- Image: `europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend@sha256:0ed923ded08c8d4a28cfc3a2e96eb49d26a63b944aa6a5db62f6480712b4cc0b`.
- [Backend CI](https://github.com/nellesf/nextStop/actions/runs/37182637888)
  passed, including 159 unit tests, all real PostGIS integration tests, 17
  reviewed migrations and the release-control tests. The preceding failed run
  found a spacing error in the enlarged pagination fixture; its corrected
  geometry retains the whole-campus assertions and adds a direct SQL ordering check.
- [Swift Core CI](https://github.com/nellesf/nextStop/actions/runs/37182637882)
  passed. [Full iOS CI](https://github.com/nellesf/nextStop/actions/runs/37182637918)
  reported 242 passed app tests, one skipped app test and 54 passed CarPlay tests. Its only failure
  was the unchanged UI test
  `testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable`, unable
  to reveal `info-error-report` before opening the report or accessing a backend.
  The runner log records a SpringBoard interruption and an approximately 47-second
  keyboard snapshot query consuming the reveal deadline. The same test was
  previously intermittent in the 2026-10-01 release record. A targeted
  [UI-only rerun of the exact same commit](https://github.com/nellesf/nextStop/actions/runs/37183500996)
  failed before any tests because that hosted runner had no available iOS
  Simulator destinations. Neither hosted run is being described as fully green.
  The exact failed UI case subsequently passed locally on the repaired iOS 27
  Simulator using the unchanged application commit. This complements the green
  app/CarPlay suites; it does not turn the failed hosted runs into green runs.
- Existing Cloud Build `42be4103-f5fb-456f-b20f-fc8ac5af5490` built the exact public
  Git commit outside the serving VM, without source/log buckets or IAM changes.
  The first submit with an explicit service-account selector was rejected before
  creating a build; using the existing default selected the same account.
  The successful build ran from 06:28:26 to 06:29:15 UTC. Its 49.2 seconds of
  compute represent less than USD 0.01 at the published Frankfurt e2-medium
  list price, excluding logs, registry storage and transfer; this is not invoice data.
  See [regional build prices](https://cloud.google.com/build/pricing-update).
- Immutable registry tag/digest, manifest/config SHA-256, OCI revision label and
  `linux/amd64` were independently checked before deployment.
- The existing staging release runner passed migrations, role setup,
  readiness/search and proxy-switch gates. Green API/auth started at 06:31:49 UTC;
  the new singleton worker started at 06:33:01 UTC. Blue remains the retained
  release. Database container identity and start time did not change.

No main merge or production promotion was performed. A subsequent automatic
main deployment can replace this explicitly staged branch experiment.

## Live verification

All times below are UTC on 2026-10-04.

| Check | Observed result |
| --- | --- |
| Search continuity during release | 48/48 authenticated synthetic searches succeeded, one every five seconds over four minutes |
| Sampled latency | Median 254.55 ms; p95 546.2 ms; maximum 1,952.2 ms |
| Static import activation | Charging/food projection IDs unchanged; no new attempt; both next due 2026-11-01 02:00 UTC |
| Idle / German-only demand | At 06:34:12, no refresh-control row and the last old-worker live snapshot still active; German secondary response 200, 96.3 ms, refreshPending false |
| Concurrent Swiss demand | Two requests returned 200 in 236.5/238.8 ms with refreshPending true; one shared attempt at 06:34:26.792, successful at 06:34:28.268 |
| Follow-up availability | Twelve seconds later: 200 in 91.7 ms, refreshPending false, newer provider observation; total/count invariants retained |
| API permissions | No SELECT or write rights on either scheduling/control table |
| Worker signal | No published host binding for port 8091 |
| Release state | Correct API/worker digest, no pending journal, checked containers running with zero restarts |
| Cost allocation | Same one e2-standard-2 and 30+150 GiB balanced disks after release |
| Production | Public readiness still reports original `sha256:e93e7f3a622169b74507a3c3fe5712d6641ef600b6c99ae30ef5b22b285890f7` |

The German response's entire static candidate data matched its prerelease hash.
At 06:37:23, identical synthetic Swiss searches against retained blue and active
green each returned 50 candidates, in 209/168 ms respectively. Membership and
ordering matched exactly. Differences were confined to `availability` and
`sources[].liveObservedAt`. After excluding only those live fields, all 50 complete
candidate objects were identical, including operator counts, coordinates, food
and static source metadata. Neither comparison triggered an availability refresh.
At 06:38:15, the control row and live snapshot were still exactly unchanged from
the one successful 06:34:28 refresh, well beyond the 06:35:28 cooldown expiry.
The worker had no restarts. There was no subsequent idle refresh in that window.

At 06:49:39, exact index-only counts with two-second statement limits measured
583,004 derived rows across the seven retention tables in the active version.
Including table-boundary batches, an equally sized retired version takes 585
batches, or 19 successful daily 32-batch cleanup runs. This fits even a 28-day
month without requiring increasing cleanup capacity. Repeated lock contention
or timeouts can still delay cleanup. Two rollback versions and the seven-day
grace are deliberately retained; normalized source and audit data are outside
this derived-row cleanup. This is not a claim of permanently constant storage.

These bounded samples establish the exercised behavior, not an SLA or the absence
of failures between requests. The monthly boundary, restart persistence, stale
availability, provider failure, read-only queries, cross-worker lease fencing,
EVSE deduplication and operator/power selection were additionally exercised with
synthetic records in real PostGIS CI. No expensive full corpus refresh or
intentional provider outage was introduced on the running staging database.

## Local Simulator incident

The local iOS test attempt exposed a broken ClockPoster/StandBy store on the
existing iOS 27.0 (24A434) Simulator. Five Ambient configurations lacked descriptor
identifiers, and their ordering metadata referenced five absent descriptor
directories. A controlled reproduction captured the corresponding
`PRPosterDescriptor.m:73` assertion, `descriptors must have descriptorIdentifiers`.
Neither a full restart nor clearing only the stale ordering key repaired it.

With explicit owner authorization to repair the cause, the Simulator was shut
down and the SQLite/WAL/SHM files plus the affected ClockPoster configuration
folder were privately backed up. Only the five invalid configurations and their
related role/attribute rows were quarantined. All other database rows were
verified unchanged. SQLite integrity and foreign-key checks passed. On restart,
Apple regenerated five complete descriptors and valid configuration identifiers.

Two cold boots each passed the original 243 app test cases (242 passed, one
existing skip) and 54 CarPlay tests, followed by 90 seconds of observation.
Each observation retained one PosterBoard process ID, with no assertion, restart
or new crash report. This checks the system process separately from the app test
exit code, since crash-report rate limiting can suppress new IPS files.
No global crash reporting setting, app data, other Simulator device or HomeKit
Accessory Simulator was changed. The private rollback backup is retained locally.

The defective state and its repair are established; the original action that
created that state is not. A related Poster path crash already existed on
2026-09-30 with the same system binaries. No runtime update or parallel-test race
is asserted as its cause.
