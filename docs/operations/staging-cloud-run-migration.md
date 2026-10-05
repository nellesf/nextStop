# Staging Cloud Run migration record

## Direct-domain acceptance and completed source retirement, 2026-10-05

At 11:25:43 UTC, absence was verified for the exact old staging VM, both source
disks and its reserved IP address in `nextstop-tech-testing`. API/Auth readiness
and an authenticated synthetic search passed again through the direct public
domain after removal, on release `88dc6b061c16`. Cloud SQL remains authoritative;
production was not changed. No new snapshot or job was created for retirement.

At 10:39:06 UTC, verified HTTPS succeeded from both the operator's computer and
the old staging VM through the direct Google domain path. Both sources resolved
away from the old VM and received a valid Google Trust Services certificate for
`api-staging.nextstop.tech`, with normal chain and hostname verification. API/Auth
readiness returned the expected `a6dd78dc…` image, and an authenticated synthetic
search passed on release `88dc6b061c16`. At 10:39:52 UTC, the direct-domain
client-IP isolation and forwarded-prefix resistance checks passed with nine
bounded requests from the two independent sources. Google's mapping status still
reported `CertificatePending`; these actual verified connections establish that
the data path was ready despite that stale control-plane condition. More than
three hours had elapsed since the verified DNS change with a 3,600-second TTL.

Fresh source ownership metadata at 10:40 UTC matched only staging project
`nextstop-tech-testing` (`353471052580`), VM `nextstop-backend` in
`europe-west3-a`, its exclusively attached 30 GiB boot disk `nextstop-backend`,
150 GiB disk `nextstop-data`, and reserved address `nextstop-staging-ip`
(`34.89.193.23`). The bounded Compute inventory found no managed/unmanaged
instance groups, templates, target instances, forwarding rules or snapshots.
At 10:42:58 UTC, the five original API/Auth/worker containers were still stopped
with exit code 0, unchanged IDs/images and no restarts; only the original database
and Nginx remained running. The reviewed bridge configuration was unchanged.

The independent readiness record confirmed no unfinished relevant jobs, valid
source-bound acceptance, the successful overnight filtered backup and the earlier
isolated restore. The restore evidence covers a prior filtered archive with
native PostgreSQL; it is not a new restore of the overnight backup. The 09:00 UTC
scheduled cleanup had failed with a nonzero exit, while the independent 10:00 UTC
cleanup succeeded. That later failure's cause has not been investigated and is
an operational follow-up; it is not assigned to the already reproduced empty-
version plan regression without evidence. No cleanup rerun was initiated for
this retirement check. The latest monthly check and report purge also succeeded.

At 10:45:04 UTC, the exact source VM ID was verified in `TERMINATED` state.
API/Auth readiness and an authenticated synthetic search still passed through
the direct public domain on release `88dc6b061c16` after the VM stopped. The
application therefore no longer depended on its Nginx bridge. A 10:48:42 UTC
readback still showed `TERMINATED`, deletion protection enabled, both disks
attached, and no deletion-start journal. At that intermediate point, active VM
compute charges had stopped while disk/address charges continued.

Automatic approval review initially rejected the permanent-deletion helper before
execution because the owner's first request authorized shutdown, not irreversible
removal of the VM, both disks and reserved address. No deletion or protection
change ran during that rejected attempt. The owner subsequently explicitly
approved that exact permanent removal. The guarded procedure rechecked identities
and stopped state, removed the VM while retaining its disks, checked exclusive
disk/address ownership, and then removed the two disks and released the address.
The final absence checks and post-removal public search passed at 11:25:43 UTC.
This ended the source VM/disk/address resource overlap; the actual new billing
total remains unverified. The old VM is no longer a rollback destination.

A fresh 11:24:18 UTC read verified the latest successful backup's receipt and exact
archive/schema generations. The 2,807,737,577-byte archive matched its receipt;
the schema object was 1,455 bytes. CRC32C metadata was present, objects were
non-composite, and uniform bucket access plus enforced public-access prevention
remained enabled. No archive/schema body was read, no archive hash independently
recomputed, and no new restore performed. The prior isolated restore's evidence
hash remained unchanged. Cloud SQL was `RUNNABLE` with the expected connector,
TLS and capacity settings. All four schedules were ENABLED with their fixed
Cloud Run job API targets and expected service identity, independent of the VM
and custom-domain DNS.

The owner authorized merging the branch into main while preserving the running
production backend, and explicitly accepted the resulting internal TestFlight
build. Review confirmed that the production workflow and environment configuration
are unchanged: production promotion still requires a manual dispatch and reviewer
approval. Backend, image-security, Swift Core and iOS CI passed for `a4e0b1f`;
only this operational record changed afterward. The app remains compatible with
the existing production search response: without the optional availability context,
it makes no live-availability request and retains the existing displayed values.
Xcode Cloud's enabled `Default` workflow starts on main changes and distributes
its archive to the internal test group. No workflow configuration was saved;
unsaved editor state was discarded with owner approval. Activating staging CI
remains separate, and `NEXTSTOP_RELEASES_ENABLED` remains false.

Private evidence: `retirement-public-domain-checks-20261005.json`,
`retirement-public-ip-check-20261005.json`, `retirement-readiness-20261005.json`,
`source-retirement-final-20261005T104052Z-30d59973.json`,
`source-container-final-20261005T104258Z-fac30f0a.json`,
`retirement-vm-stopped-20261005.json`,
`retirement-readiness-refresh-20261005T112418Z-688b78d3.json` and
`retirement-completed-20261005.json`. The following earlier
DNS/TLS and release snapshots retain their original times and are superseded by
this later direct-domain verification.

## Earlier DNS transition snapshot, 2026-10-05

The owner completed the IONOS change. At 07:26:45 UTC, all four authoritative
IONOS nameservers plus Google and Cloudflare public resolvers returned exactly
`api-staging.nextstop.tech CNAME ghs.googlehosted.com.` with a 3,600-second TTL.
No restrictive CAA records were observed on the checked domain/alias path.
The existing Cloud Run mapping still targets `nextstop-gateway` with automatic
certificate management and returns that same required CNAME.

At 07:28:23 UTC, the mapping still reported `CertificatePending`; an ordinary
verified HTTPS connection to the custom domain failed with `SSLEOFError`.
Its retry condition reported a 24-hour polling interval from a 05:41:14 UTC
transition, which is not a guaranteed issuance deadline. Separate readiness and
an authenticated synthetic search passed through the stable public `run.app`
gateway for release `7db74d556e33`. This isolates the observed failure to the
custom-domain path; it is not a successful post-DNS search or client-IP gate.
Staging clients resolving the new DNS can be unavailable until the certificate
is ready. Cached old DNS can still use the retained VM bridge.

The DNS and gateway receipts are `dns-cutover-20261005.json` and
`domain-and-gateway-20261005.json` in the private commissioning workspace. No
mapping recreation, TLS-verification bypass, new infrastructure or source-resource
retirement occurred. Google documents checking DNS/domain ownership and waiting
at least 24 hours for this certificate-provisioning condition; its domain-mapping
API exposes no explicit certificate retry action. See
[Cloud Run troubleshooting](https://docs.cloud.google.com/run/docs/troubleshooting#custom-domain-stuck-while-provisioning-certificate).

The final read at 08:21:37 UTC again confirmed the correct CNAME through Google
and Cloudflare resolvers, while HTTPS remained unsuccessful and the mapping
still reported `CertificatePending`. This is recorded in
`domain-final-16eea07.json`; the cleanup release did not resolve the external
certificate-provisioning gate.

Keep the old applications stopped and Cloud SQL authoritative. Direct-domain
certificate/readiness/search and two-source client-IP verification must pass
before retiring the VM, disks or address. The two-source probe uses the VM as its
second source, so it must run while that VM still exists and both sources resolve
the new path. Preserve the bridge through the observed old DNS-cache transition.
Production and the disabled staging CI release switch are unchanged.

## Cleanup correction and verified release, 2026-10-05

Status through 08:21:37 UTC: all five stable services now send 100% of traffic to
release `88dc6b061c16`, and the four original schedules are ENABLED again after
the bounded 08:03 UTC release pause. The latest custom-domain check, at 08:21:37 UTC,
still reported `CertificatePending`; release success through the stable `run.app`
origin does not establish custom-domain TLS readiness. Production, stopped source
VM writers and the disabled staging CI release switch are unchanged.

The first scheduled overnight checks exposed a real cleanup failure. The 05:00,
06:00 and 07:00 UTC cleanup executions exited with code 1, while the scheduled
backup, monthly due check and report-purge executions succeeded. The cleanup
container used the expected image, 1 CPU / 512 MiB, a 300-second application
budget and a 330-second platform timeout, with no automatic retry. Fixed logs
reported `maintenance_job_failed`; they did not preserve the phase or SQLSTATE.
The latest failed event was about 5.8 seconds after its container Started
condition, not a 300-second job deadline or a demonstrated out-of-memory failure.

A separately guarded, zero-row, rollback-only probe then reproduced the exact
Node/Postgres path. The failed projection's stage-1 power table was empty, but
transaction-wide `force_generic_plan` made the parameterized bounded DELETE
scan the shared table of approximately 4.2 million rows. The original statement
hit SQLSTATE `57014` after 2,019 ms. The proposed custom-plan bounded selection
completed in 24 ms. All diagnostic transactions rolled back, leaving the target
and active projection unchanged. A direct EXPLAIN utility had initially selected
a misleading literal plan; the actual parameterized Node query supplied the
conclusive reproduction.

The correction first selects at most the existing batch limit of physical row
identities with `force_custom_plan` and `FOR UPDATE`. For a nonempty selection it
switches to `force_generic_plan` and deletes only those locked CTIDs, preserving
the efficient foreign-key lookup behavior. An empty selection advances its
existing retention stage without issuing a DELETE. A selected/deleted count
mismatch rolls back. Publication locks, transaction boundaries, two-second
statement and 500 ms lock limits, seven retention stages, grace period, batch
caps and protection of active/rollback versions are unchanged.

The candidate is commit `16eea076d082e92c402d378662349abffa537367`, immutable image
`europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend@sha256:a6dd78dc266bb2d001d7ce8f5919a1d85d40da79a8a0607aa6a079175560abe5`,
release `88dc6b061c16`. Typecheck, lint, build and all 226 unit/broker tests passed.
A fresh private, Unix-socket-only PostgreSQL 17.11 / PostGIS 3.5.6 cluster passed
all 26 integration tests and was then stopped and removed. The added regression
checks empty failed-stage progress, a real bounded deletion, mismatch rollback,
transaction-local plan restoration and the existing active/rollback/audit and
snapshot protections. [Backend CI run 37279944656](https://github.com/nellesf/nextStop/actions/runs/37279944656)
and Cloud Build `f2acd3b7-95ba-43de-9c87-ebbad194a09e` also succeeded. Registry
readback binds the candidate to the exact source revision and image digest.

Candidate preflight passed at 08:03 UTC with unchanged sizing and stable traffic.
API/Auth readiness, an authenticated synthetic search and forwarded-prefix
resistance passed at 08:06:26 UTC. The one ordinary cleanup execution
`nextstop-cleanup-nvqd6` succeeded from
08:11:03.951 to 08:11:40.902 UTC: 36.950 seconds overall, including provisioning,
and 6.127 seconds within the actual task start/completion window. The failed
projection advanced from retention stage 1 to stage 3. Active charging/food
projections, rollback versions, monthly budget and import schedules remained
unchanged. All 22 authenticated synthetic search samples returned HTTP 200 with
identical static results; the maximum warm latency was 560.2 ms. Two complete
samples fell inside the actual task window, at 532.3 and 560.2 ms. This is bounded
measured availability evidence, not a general latency guarantee.

The initial local checker rejected an absent `lastTransitionTime` on the task's
Started condition after that execution had already succeeded. A separately
reviewed, read-only recovery used the actual `task.status.startTime`, corroborated
by the execution Started condition, and the actual task completion time. It
preserved the original failed receipt, execution/start journals and all original
search samples. Recovery passed at 08:18:12 UTC without starting another job,
retrying cleanup, making another search request or forcing an import.

The local acceptance validator retained five unchanged source/config-bound gate
proofs with their original observation times and added this fresh database
performance proof. It did not represent those five historical observations as
newly executed on the replacement image. Artifact security, candidate smoke,
preflight and promotion remain separate checks. The resulting acceptance object
is `operations/evidence/f1036d3965d8e7b6a22cfd926315003ffbcc6c74e0e8d8f8289fe940f314b8cd.json`,
generation `1791188326551526`, with its content SHA-256 pinned in the final
configuration.

All five service promotions then passed. At 08:20:19 UTC, actual traffic metadata
showed 100% on release `88dc6b061c16`; API/Auth readiness and an authenticated
synthetic search passed through the stable, untagged public `run.app` origin.
The four internal services remained IAM-private. At 08:20:25 UTC, all four
original schedules were read back as ENABLED. No extra heavy import, cleanup
retry, source VM retirement, CI activation or main merge occurred. Custom-domain
TLS/search and the post-DNS two-source IP gate remain pending.

The private evidence includes `cleanup-empty-target-plain-rollback-oct5.json`,
`cleanup-draft-empty-rollback-oct5.json`, `release-preflight-16eea07.json` and
`candidate-smoke-16eea07.json`, plus
`cleanup-acceptance-16eea07/evidence-recovered.json`,
`postpromotion-run-app-16eea07.json` and
`release-schedulers-restored-16eea07.json`. Independent source metadata at 07:38 UTC matched
the exact staging VM and its exclusively attached 30 GiB boot disk and 150 GiB
`nextstop-data` disk; the reserved address also matched. Deletion protection is
still enabled. No source resources were retired, and the custom-domain TLS,
post-DNS search and two-source IP gates remain open.

## Commissioning snapshot, 2026-10-04

Date: 2026-10-04, status through 18:16:54 UTC. All five stable Cloud Run services
use security release `7db74d556e33`. Only the gateway is public; API, Auth, live
and simulator broker remain IAM-private. A fresh writer handoff and Nginx bridge
completed successfully. The source VM retains its database and Nginx, but all five
old application containers are stopped. Cloud SQL is now the authoritative writer
destination. Production is unchanged.

DNS still points `api-staging.nextstop.tech` to the source VM. Its temporary bridge
already reaches the new release: public-domain API/Auth readiness and an
authenticated synthetic search passed at 18:12 UTC. The owner has been asked to
replace the IONOS `api-staging` record with CNAME `ghs.googlehosted.com.`; the direct
managed-domain certificate and post-DNS checks remain pending. All four existing
schedules were enabled and read back at 18:16:54 UTC, without changing import due
dates or the budget. No VM/disk/address retirement, CI activation or main merge has
occurred; overlapping infrastructure costs continue.

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
- Five Cloud Run services and five job definitions exist. Only `nextstop-gateway`
  has a scoped `allUsers` / `roles/run.invoker` binding. The four internal services
  reject anonymous invocation. Each service has configured minimum zero / maximum
  one instance and request-based billing. Four schedules were created away from
  their due times, immediately paused and verified without execution. They were
  enabled at 18:16 UTC after the authoritative target, public bridge and
  backup/release gates passed; this did not require the external DNS change.

## Security release and completed writer handoff, 2026-10-04

The replacement staging candidate is application commit
`923f811d26c637b87923c9dab688d9581422d971`, immutable image
`europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend@sha256:64d018644b0c57c9775c94aee641b23ed5a50dfb8b0e9102a98bd0ee076b2e8a`,
release `7db74d556e33`. Cloud Build
`0cf35319-6909-479e-be51-ce45ba4f3534` succeeded at 17:31:31 UTC.
[Backend CI run 37220687771](https://github.com/nellesf/nextStop/actions/runs/37220687771)
also passed, including the dependency/container security job and actual PostGIS
integration tests. Production was not changed.

The first security build, commit `09dcf33`, was blocked before push by real
base-system/global-package findings. The replacement image updates the supported
Alpine runtime and system packages, retains only the required PostgreSQL 17 client
tools, and removes runtime npm/Yarn. It runs as the unprivileged Node user. Build-time
checks execute dependency imports, compression, German timezone formatting and the
three PostgreSQL client tools inside that final runtime image. This base-image
change required fresh runtime evidence; prior acceptance hashes were not silently
reused across the package/runtime change.

The successful Cloud Build ran the prescribed source, dependency audit, image
build/export, pre-push Trivy scan, push and digest-binding steps in order. Its
Trivy 0.75.0 receipt reported zero findings in every reported severity at
17:31:12 UTC. The policy includes unfixed vulnerabilities and blocks HIGH and
CRITICAL findings without suppressions; npm audits separately block MODERATE or
higher findings. A later registry read independently matched the published
manifest digest, Linux/amd64 platform, OCI source revision and image config digest
to that same scan receipt. The full Trivy workspace report was not retained by
Cloud Build; evidence consists of the actual successful build definition/status,
its logged digest-bound receipt and verified registry metadata. The separate CI
image scan is additional evidence, not a substitute image identity. These are
dated scanner results, not proof that all vulnerabilities are known or absent.

Gateway admission now combines the existing per-IP buckets with per-process
ceilings: API 120/minute (burst 20), Auth 60/minute (burst 10), Reports 12/minute
(burst 3), and invalid requests 60/minute (burst 10). The configured gateway
instance limit is one. Header, URL, body and in-memory IP-table bounds apply before
upstream work; unknown paths and malformed requests consume the invalid-request
budget. An exact, bodyless `/health` remains a constant, dependency-free 200 so
public traffic cannot exhaust a shared bucket and force platform liveness
restarts. `/ready` and `/ready/auth` consume their respective API/Auth budgets.
The limits are local to each process and reset on restart; they do not constitute
a WAF or a hard monetary spending cap. App Attest and application token checks
remain in place, and the private simulator broker has no gateway route.

Release preflight now rejects Cloud SQL security/cost-policy drift: connector
access must be REQUIRED, authorized networks must be empty, TLS must require a
trusted client certificate, and automatic storage growth must remain disabled.
It requires the seven reviewed redaction flags exactly (`log_connections=off`,
`log_disconnections=off`, `log_min_duration_statement=-1`,
`log_min_error_statement=panic`, `log_parameter_max_length=0`,
`log_parameter_max_length_on_error=0`, `log_statement=none`), rejects duplicate
flag definitions, and permits sampled-statement logging only when unset/default
or explicitly `-1`. The real candidate preflight passed these checks; no actual
configuration drift was found.

At this evidence snapshot, private candidate checks had passed for API/Auth
readiness, authenticated synthetic search, two-source client-IP isolation and
forwarded-prefix resistance, live-task single-flight/cache behavior, fresh search
performance, registry/security binding, and the current SQL function permissions.
A normal execution of the new monthly job succeeded with future due dates and
unchanged aggregate import state: both sources remain due on November 1 at 02:00
UTC, active projections are unchanged, and October's shared heavy-import budget
remains 2/3. The current CI run separately exercised the budget's real PostGIS
concurrency/restart/month-boundary checks. This proves the normal due-check path;
it is not a new heavy provider import on the replacement image.

The fresh isolated recovery exercise completed at 17:15:54 UTC. It verified the
filtered archive, the 18-to-19 expand migration, restored counts/indexes, native
SQL/data/grants and search queries, then removed its local cluster. Its exact
migration, SQL, transfer, policy and search source pins still match this release.
This is native PostgreSQL recovery evidence, not Node/OCI runtime recovery. New
image runtime behavior is covered separately by the build, CI and live candidate
checks above.

A fresh 18:00 UTC Monitoring sample explicitly reported zero active and zero idle
instances for each of the five new service revisions: all ten required
measurements were present and zero. The final local acceptance validation passed
all seven gate groups at approximately 18:01 UTC. Its candidate promotion receipt
binds the exact release, immutable image and application commit above; the source
and evidence hashes are recorded in the accompanying provenance file. No older
runtime's idle result was substituted.

The validated acceptance document was stored at
`operations/evidence/10e0c04e537843aa8a41cfca0ffdbbaf3f4d76f71881c9d9f8e171c69ea742c0.json`,
generation `1791136890425623`, in the private staging backup bucket; pinned
readback passed. The final configuration uses that exact object generation and
SHA-256. The local artifacts are `acceptance-evidence-security.json`,
`promotion-receipt-security.json` and `acceptance-provenance-security.json` for
release `7db74d556e33`. Candidate acceptance was completed before the subsequent
guarded traffic
promotion, public IAM change and writer handoff described below.

The new runtime's filtered-backup job `nextstop-backup-v8p85` completed successfully
at 18:06:09 UTC after 23 minutes 33 seconds. It created a 2,814,406,126-byte archive
and a separate report-schema object, excluding report values. The job streamed its
archive SHA-256 and the storage SDK validated CRC32C before publishing the
receipt; a metadata read confirmed the generation and byte count. The schema
SHA-256 was independently checked. The archive was not downloaded or independently
rehashed in this check, and no restore of this new archive was performed. This
runtime backup test and the completed native PostgreSQL recovery exercise have
separate evidence scopes.

All five stable services were promoted to release `7db74d556e33`. The five older
gateway tags were removed before public exposure, because a service-level public
invoker binding also applies to tagged revisions. A fresh source baseline and
new handoff journals verified private state and key equality, froze the old write
endpoints, drained requests and stopped the exact five source app containers.
The source database and Nginx were preserved. Only then was the scoped public
invoker binding applied to the gateway and the Nginx bridge activated. Bridge
completion at 18:10:55 UTC confirmed exact-image API/Auth readiness and an
authenticated synthetic search with all old app writers stopped.

The 18:11 UTC public-boundary check confirmed that only the gateway was public:
all four internal service origins rejected anonymous requests, a valid search
without an application token returned 401, and all five removed gateway-tag URLs
returned 403/404. At 18:12:18 UTC, API/Auth readiness and an authenticated synthetic
search also passed through `api-staging.nextstop.tech` using its existing DNS and
the VM bridge. This proves the bridge path, not the still-pending direct Google
managed-domain certificate or client-IP separation after the CNAME change.

All four existing schedules were resumed and verified ENABLED at 18:16:54 UTC:
`nextstop-monthly`, `nextstop-cleanup`, `nextstop-report-purge` and `nextstop-backup`.
No due-date or budget override occurred. The normal daily monthly-import trigger
still checks the November 1 due dates and retains October's 2/3 attempt count;
cleanup and report purge run hourly. Job invocations target the Cloud Run job API
and do not depend on the IONOS DNS change. Hourly report retention therefore
resumes while the public bridge accepts reports.

The IONOS CNAME change has been requested from the owner. DNS/TLS propagation,
public-domain two-source client-IP verification and VM retirement remain pending. The old applications must stay stopped: Cloud SQL is
now authoritative, so routing back to the stale VM database is not a safe
rollback. CI remains disabled for this transition and the branch has not been
merged into main. Overlapping infrastructure charges have not ended.

## Earlier candidate artifacts (historical)

The initial backend artifact was tied to source commit
`add51b336a6cec51f04d3f1e1eedb2037aac69bf`, image digest
`sha256:52d298b27c19ba7de836d2073de31bcf821063c0d4d1598d17c46c06e717693a`,
and release ID `1c907fe7c046`. Cloud Build completed successfully and the registry
manifest, configuration, platform and OCI revision were independently checked.
The registry remains the existing repository in `europe-west3`.

The subsequent private candidate used commit
`e5592de9c96d4a2e144f32ee07a4a675d9273403`, digest
`sha256:7451101ee4c03cac414e72ded5df6c2c6dd0971df8b72b77564c54f662c40806`,
and release `a2939e6f73e9`. At that commissioning stage, only the IAM-private live
service's stable traffic had advanced to the candidate; the public domain still
reached the original VM application. The four schedules remained paused.

The cleanup correction was deployed to private candidate definitions and jobs
from commit `42ac95d87a0475b744ce6f8e0a3a73e1f8ae206a`, digest
`sha256:5517a80839c50bb3a806e65999fb8955b5034298b97bc858eda3042156e88697`,
release `66307ff9d3a7`. Registry/OCI verification and candidate preflight passed.
Existing stable service traffic was preserved when applying these definitions.

## Earlier commissioning checks (historical)

The following records retain the observations and limitations of their named
artifacts. They do not override the current release and handoff state above.

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
  The owner explicitly authorized one
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
  benchmark. Food publication succeeded at 13:53:37 UTC and the execution finished
  successfully at 13:53:41 UTC, about 31 minutes after starting, without platform
  retries. Both sources are next due November 1, and the monthly budget remains
  two of three attempts. No further import or budget reset is needed.
  Some Cloud Run CPU distributions had a finite mean outside their reported
  occupied histogram bounds. The revised read-only monitor preserves means and
  other metrics, marks these histogram conflicts for review and reports their
  derived upper bound as unknown. It does not shift bucket indices or claim an
  exact continuous resource peak.
- The completed retry's lagged monitoring showed sampled SQL maxima of 19.7%
  CPU, 46.1% memory and 23.22 GiB disk. Worker memory reached a 468.4 MiB sample
  mean; the highest consistent occupied memory bucket ended at 531.3 MiB. CPU
  sample means reached 70.8%, with eight inconsistent histograms whose upper
  bounds remain unknown. The job/time-window SQL samples include post-job search
  checks; these are not execution-exclusive or continuous peak measurements.
- Post-publication food searches exposed stale planner statistics: three warm
  concurrent API requests took 3,774/5,803/3,763 ms. An exact API-role SQL probe
  using runtime defaults took 1,971 ms and 1,067,449 buffer hits for 31 rows.
  Refreshing only `food_poi_projection` and `charging_park_food_poi_matches`
  reduced the same query to 99 ms and 8,351 hits; three concurrent API requests
  then took 438/526/442 ms with unchanged results. Expand migration 0019 adds a
  fixed, restricted statistics function. Both publishers invoke it after match
  insertion inside their existing publication transaction. The worker receives
  only EXECUTE on this function, not general MAINTAIN privileges. Real PostgreSQL
  regression tests cover stale estimates, both publication paths, restricted
  worker permissions and preservation of the old active version on failure.
  Commit `0a0d8c232b713cecacc96adb10c76d48ac566761` was built and verified as
  digest `sha256:eeeead40a7e3558a563e345039c82f258503e864d17ec0796c67f100f4a75342`,
  release `3c4afa8ccb29`. Migration job `nextstop-migrate-4tjzc` succeeded at
  14:17:37 UTC, followed by all eleven candidate-definition steps. The real
  restricted worker executed the function in Cloud SQL; the API role received
  SQLSTATE 42501. The subsequent API-role query returned 31 rows in 140 ms with
  8,351 buffer hits. Three concurrent candidate API searches returned the same
  static result hash in 642/835/757 ms. Exact-image readiness, synthetic search,
  forwarded-prefix resistance and the full candidate preflight passed.
- A second full restore rehearsal verified the existing generation-pinned
  migration-18 backup against its original 26-table count baseline, then applied
  only migration 0019. All non-registry counts remained identical; the registry
  changed explicitly from 18 to 19. Current grants, actual worker execution and
  API denial passed, as did three API-role SQL searches (51/34/51 rows in
  347/93/111 ms). The rehearsal took 305 seconds, including 269 seconds restoring
  the archive, and removed its private local cluster. The same local-versus-Cloud
  PostGIS version limitation applies. No new import or archive download was needed.
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
  downloader artifact `3367b57`, and for statistics artifact `0a0d8c2`.
- The six operator acceptance gates were reconciled against their actual source
  and stable configuration scopes. IP isolation, live-task behavior and idle-zero
  measurements retain their unchanged earlier scopes; recovery and database
  performance use the new checks above. The receipt explicitly retains the CPU
  histogram and delayed-billing limitations. The acceptance document was uploaded
  to the private evidence prefix and read back by exact generation and SHA-256.
  `deploy/environments/staging-cloud-run.json` pins the actual resources, numeric
  secret versions and that evidence. At that stage, all five stable Cloud Run
  services used release `3c4afa8ccb29`; the gateway was still private. The security
  release and fresh acceptance above supersede that runtime and receipt.
- Deployment IAM is restricted to the existing stage services/jobs/queue,
  runtime identities, SQL metadata and the acceptance-evidence object prefix.
  It grants no direct secret payload or database-backup reads. Fourteen actual
  principal permission/contract checks passed, including SQL-list and backup-
  prefix read denials plus self-OIDC/private-broker access. Probe markers and
  temporary permissions were removed. The original cleanup misclassified a
  canonicalized Google-account alias; a separate corrective receipt confirms
  removal of the exact remaining probe binding and role. Actual scheduler
  pause/resume by CI and the main-branch WIF workflow remain unexercised.

## Remaining transition work

The authorized food import, statistics correction, new security acceptance,
filtered-backup runtime test, traffic promotion and fresh writer handoff have
completed. Direct-domain verified TLS, readiness/search and two-source IP
isolation also passed on October 5. The separately recorded cleanup correction
and release are complete, and all four reviewed schedules are enabled. Public
operation passed both with the old VM stopped and after its owner-approved
removal together with both disks and reserved IP. Source retirement is complete;
retain the filtered-backup and isolated-recovery evidence. Investigate the
separately observed 09:00 cleanup failure without assuming that the later 10:00
success explains it.

Provider source changes now invalidate the import-budget and database-performance
acceptance fingerprints. Regression coverage checks modification, addition and
deletion of provider files while retaining unrelated IP, recovery, live-task and
idle evidence. A changed downloader must not silently reuse an old import check.

Staging's `NEXTSTOP_RELEASES_ENABLED` override remains false, preventing the old
main-branch workflow from attempting to redeploy the retired VM. Production release
control is unchanged. The owner authorized the main merge and its internal
TestFlight build after the compatibility and automation review. The running
production backend must remain unchanged; no production promotion is included.
The new Cloud Run release workflow remains disabled until its separate activation
prerequisites are completed.

## Earlier handoff interruption and temporary VM restoration (historical)

This earlier attempt preceded the completed security-release handoff above. Its
markers and temporary restored VM state were not reused to authorize that later
transition.

The source write freeze was installed. Its first operator check stopped before
any app container was stopped; a read-only inspection confirmed the exact freeze
configuration, all five original running app containers, a healthy unchanged
database and no remaining draining Nginx workers. Both frozen write endpoints
then returned 503. The original probe's precise failure was not captured, so a
reload timing race is a hypothesis, not an established root cause.

A separately reviewed, journaled continuation accepted only that exact partial
state. It stopped the five source app containers without reinstalling Nginx or
resetting earlier markers. Both databases' three private tables were empty,
source writer connections were zero, signing keys and App ID matched, and the
database and Nginx remained running. No private data export was needed.

Automatic approval review then rejected granting `allUsers` the `roles/run.invoker`
role on the staging gateway, requiring explicit owner approval for that exact
public-access scope. No public binding was applied during that attempt, and the
owner was asked for explicit approval. The later scoped gateway binding and fresh
handoff are recorded above. Application-level App Attest checks remained enabled.

While this permission remained pending, a separately reviewed restoration put
the original VM installation back into service. It first rechecked that the
Cloud Run gateway still rejected anonymous access, both private data states were
empty and signing keys matched. It restarted only the five retained container
IDs, verified all four loopback readiness endpoints against their original image
digests and ran a real synthetic search. Only then did it restore the exact
original Nginx configuration and pass local TLS/API/Auth/search checks. The
database, earlier handoff journals and new Cloud Run corpus were preserved; no
IAM change or database copy occurred. Staging was temporarily available through
the original VM application again. The four schedules remained paused and no VM
resources were retired. The fresh security-release handoff later stopped those
application writers again and replaced the original upstream with the bridge.

That freeze receipt became historical when the source writers restarted. The
completed security-release handoff therefore captured a fresh source/container
baseline, repeated the private-state/key checks and used new journals. Its
bounded checks waited for both write endpoints to return 503 after Nginx reload
before draining and stopping the old writers; the earlier one-time execution
markers were preserved.

## Recorded handoff procedure and resource-retirement guards

Steps 1–3 below describe the completed guarded handoff and must not be rerun.
The October 4 scheduler activation and October 5 release resumption are complete.
Direct-domain TLS/search/IP checks, VM shutdown, and explicitly owner-approved
VM/disk/address removal subsequently passed. The main merge and internal
TestFlight build were then authorized; later staging CI activation remains separate. This procedure applies only to the source VM
`nextstop-backend` in `nextstop-tech-testing/europe-west3-a` and the reviewed Cloud
Run/Cloud SQL target in the same project, region `europe-west1`. Production is
unchanged. Keep the staging CI release override false. The four exact reviewed
schedules resumed after the authoritative target, public bridge and backup/release
gates passed on October 4; after the temporary cleanup-release pause, all four were
verified ENABLED again at 08:20 UTC on October 5. The external DNS change is
complete; actual direct-domain TLS passed despite the stale mapping condition.

Before either handoff, the original source configuration matched the repository
HTTPS template rendered for the green slot. The prepared freeze/bridge
configurations first passed `nginx -t` with temporary alternative main
configurations, without changing serving configuration. The later guarded
handoff activated the bridge, with readiness and authenticated search verified
before requesting the DNS change.

1. **Routing preparation — completed.** The reviewed Nginx configuration reuses
   the existing staging TLS certificate, route allowlist, method/body limits,
   rate limits and redacted diagnostics. The temporary upstream is the fixed
   public gateway origin
   `https://nextstop-gateway-353471052580.europe-west1.run.app`, never
   `api-staging.nextstop.tech` itself. Upstream Host and TLS SNI use that
   `run.app` host with certificate verification against the system CA.
   Application Authorization is preserved; caller-provided `X-Forwarded-For`,
   `Forwarded`, `X-Real-IP` and `X-Serverless-Authorization` are removed.
   Request/response buffering and upstream retries are disabled, with no fallback
   to the old applications. This is a temporary DNS bridge, not a permanent proxy
   product or trusted-forwarded-header exception.

2. **Writer freeze and state verification — completed.** With the gateway still
   private, the fresh handoff blocked new source Auth/Report requests, waited for
   both freeze endpoints to return 503, drained in-flight work and stopped all
   five source API/Auth/worker containers. The source database and Nginx remained
   running. The original application writer sessions ended, both staging
   databases' three private tables were empty, and signing keys/App ID matched
   without printing values. No private delta archive or data copy was required.
   This was a deliberate brief write freeze, not a claim of uninterrupted Auth.

   A future nonempty private-state transfer requires a separately reviewed narrow
   procedure preserving counters, consumed challenges, report deletion state and
   expiry timestamps. The checked-in `database-transfer.py --purpose handoff`
   creates a full-schema snapshot; it is not a delta importer for an already
   populated target. Report-containing handoff data must not become a durable
   backup and any exact temporary copies remain subject to the four-hour window.

3. **One writer destination — activated.** Only the reviewed gateway received the
   scoped public invoker binding. API/Auth/live/broker remain IAM-private. The
   bridge passed configuration validation, readiness/auth checks and an
   authenticated synthetic search after reload. Public searches through the
   existing staging domain also passed at 18:12 UTC. During the DNS transition,
   clients retaining the old address reached the same Cloud SQL-backed services
   through the bridge and temporarily shared the VM's source-IP budget. The
   bridge never trusted forged forwarded headers. After direct-domain acceptance,
   the source VM and disks were removed; Cloud SQL remains authoritative.

4. **DNS and direct HTTPS verified.** The owner replaced the
   IONOS staging record with CNAME `api-staging` to `ghs.googlehosted.com.` on
   October 5. Authoritative and public DNS checks passed at 07:26 UTC; Google's
   managed certificate initially remained pending at 07:28 UTC. Verified TLS from
   both sources, public search and two-source IP checks passed at 10:39 UTC.
   The verification contract checks domain/certificate status and HTTPS readiness on
   `api-staging.nextstop.tech`, including the expected API/Auth release digest.
   `verify.verify_public` supplied the broker-authenticated synthetic search;
   the two-source client-IP/forwarded-prefix check ran on the direct domain before
   the source VM was removed. The earlier 18:12 bridge-domain result was not used
   as post-DNS evidence. These checks prove routing/token behavior, not a new
   real-device App Attest assertion. The temporary bridge ended with the verified
   source retirement.

5. **Schedules enabled; source resources retired.** The authoritative target,
   authenticated public bridge and backup/release gates passed. The four exact
   commissioned schedules (`nextstop-monthly`, `nextstop-cleanup`,
   `nextstop-report-purge`, `nextstop-backup`) were resumed and verified ENABLED
   at 18:16:54 UTC. Their target job invocations do not depend on staging-domain
   DNS. Hourly report purge is enabled while public report intake is available.
   The commissioning helper initially left the schedules paused, and `deploy.py`
   restores only schedules that were enabled before its run. Preserve the
   measured monthly due dates/budget; do not force another import when enabling
   the daily due check. After successful public checks with the VM stopped and
   explicit owner approval for permanent removal, the exact source VM, 30 GiB
   boot disk, 150 GiB `nextstop-data` disk and regional `nextstop-staging-ip`
   reservation were removed. Final absence and direct-domain API/Auth/search
   checks passed at 11:25:43 UTC on October 5. The procedure retained both disks
   during VM deletion, then verified their detached ownership before removal;
   it did not rely on automatic disk deletion. No replacement snapshot or job
   was created, and production resources were untouched.

6. **Keep CI separate from initial commissioning.** The branch may be deployed
   manually under the staging migration authorization. The owner has now
   authorized the main merge and its internal TestFlight build after review, while
   preserving the running production backend. Before any later CI activation,
   commit the actual `deploy/environments/staging-cloud-run.json` with numeric
   secret versions and generation/hash-pinned real acceptance evidence. Only when
   main contains the reviewed Cloud Run path
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
bases. The temporary source VM/disk/address overlap ended with confirmed
retirement at 11:25:43 UTC on October 5; stopping the VM alone had retained the
disk/address costs. Actual new-runtime billing still needs separate verification.
Keep billing and measured import evidence distinct; report a projected overrun
before any unapproved resize or teardown.
