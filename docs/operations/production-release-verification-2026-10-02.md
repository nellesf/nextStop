# Production release verification, 2026-10-02

The latest production promotion is the permanent build-admission fix,
`fbd2489` / `sha256:e93e7f3…`, approved by the owner and successfully deployed at
06:22:33 UTC. Its evidence follows the earlier promotion and incident records in
the final section below. The legacy compatibility credential remains unchanged.

## First production promotion and authorized artifact

**Production promotion passed.** The first owner-approved attempt failed safely
in its backup phase. The authorized retry completed successfully with the same
staged application image. That promotion activated the blue API/auth slot with one
replacement worker; the legacy API/auth containers were retained for rollback.
The final host audit and named production Simulator broker smoke also passed.
The later TestFlight incident below exposed a separate build-version admission
failure. Its immediate configuration correction activated the green slot with
the same image; synthetic promotion checks alone did not verify device access.

The owner explicitly approved the following exact staged artifact at 03:57 UTC.
All times in this record are UTC.

| Item | Verified value |
| --- | --- |
| Commit | `9ec36e860f1abc0c4f1872888eb83483d5249156` |
| Image repository | `europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend` |
| Image digest | `sha256:21083d7cc09f376c7fe90fb9eebf3b78a5ee83a19916d2fe79dd0060d8173a08` |
| Successful staging CI | [Run `36860547909`](https://github.com/nellesf/nextStop/actions/runs/36860547909) |
| Successful explicit staging deployment | `6783984468` |
| First production CI attempt | [Run `36861316291`](https://github.com/nellesf/nextStop/actions/runs/36861316291) |
| First explicit production deployment | `6800933975`, failed before deployment |
| Successful production retry | [Run `36963689673`](https://github.com/nellesf/nextStop/actions/runs/36963689673) |
| Retry control commit | `345e258`; application commit/image unchanged |
| Successful explicit production deployment | `6801142334` |

The staging public readiness and exact commit/image/deployment promotion binding
had passed. The [2026-10-01 staging record](staging-release-verification-2026-10-01.md)
contains that evidence and the completed real production backup/isolated restore
rehearsal. That rehearsal used artifact B, a 2.361 GiB archive and 251 seconds of
restore/checks. It establishes logical recovery compatibility; it does not replace
the current release's exact-image, one-hour backup receipt requirement.

## First attempt and backup failure

The read-only production preflight at 03:56:40 matched the preserved baseline.
Existing production service/container identities, images, start times, mounts
and checked configuration were unchanged, and the health checks passed.

At 04:08:18, the workflow failed while parsing the remote dump metadata as JSON.
The SSH command's stdout was not a valid JSON document. The failure occurred in
the backup gate: no deployment phase, production migration, role initialization,
proxy switch or application/worker replacement ran. The source temporary archive
cleanup completed. Existing production application services and database state
were not changed by a release operation.

Inspection of the installed Google Cloud SDK source confirmed that initial SSH
key generation can emit a banner on stdout even with `--quiet`. A fresh CI SSH
identity producing that prefix is the code-supported explanation for the JSON
parse failure. The raw stdout was not retained, so the exact banner in this
attempt is inferred rather than directly captured. No private command output,
backup object identifier, receipt, token or credential is included in this record.

The transport correction initializes the SSH identity with suppressed output
before invoking the command whose stdout must contain only metadata JSON. The
subsequent successful CI retry exercised this correction without expanding IAM.
The failed first attempt was not treated as a successful backup gate.

## First-attempt search samples and cleanup

A bounded probe used the checked-in release gate's fixed synthetic search and
the documented legacy production Simulator broker. Tokens stayed in memory.
Requests were sequential at one-minute intervals, with a 20-second HTTP timeout,
no overlapping requests and no catch-up burst. The first sample began after the
backup had already started; the probe does not cover the whole attempt.

| Measurement | Result |
| --- | --- |
| First / last sample | 04:01:43.516 / 04:10:43.552 |
| Successful searches | 10 / 10, HTTP 200 with valid nonempty candidates and snapshot |
| Failed searches | 0 |
| Health-only fallback samples | 0 |
| Median latency | 983.5 ms |
| Maximum latency | 3,266 ms |
| Requests exceeding five seconds | 0 |

The probe stopped after the failed-attempt signal at 04:10:46. Its owned broker
stopped, loopback port 8766 was released, and private temporary probe files were
removed. Only sanitized aggregate evidence remains locally. No search payload,
response or token was logged. The prepared named production broker smoke test
was not executed because production had not been deployed.

These samples found no failed search during the sampled part of the backup
attempt. They cannot exclude interruptions between samples, establish a load or
latency SLA, or prove search continuity across a production switch that did not
occur.

## Successful retry and final host audit

The authorized retry used control commit `345e258`, preserving the approved
application commit and image. Its backup phase completed at 04:31:20, then the
deployment phase ran from 04:31:20 to 04:35:39. The workflow and explicit
production deployment `6801142334` both succeeded. Public API and auth readiness
returned HTTP 200 with the exact approved digest at 04:34:50.

The backup metadata audit at 04:37:24 confirmed one new archive for this retry,
completed at 04:31:11.542, with 2,576,666,593 bytes matching the source archive.
The generation and CRC32C/MD5 metadata were valid; the object was not a composite
upload. The backup helper had compared source and downloaded SHA-256 hashes,
and the storage CLI had checked the upload checksum. No temporary upload parts
remained. Public-access prevention and uniform
bucket access remained enforced. The object identifier and private receipt are
omitted from this record. The archive includes the authorized private App Attest
state and excludes `user_error_reports` data.

This particular archive was not restored again. The previous full isolated
restore used artifact B; its backend runtime and migration source match the
current candidate. That prior recovery rehearsal and this release's fresh,
structurally validated, checksum-bound backup are separate pieces of evidence.
Neither substitutes for the other's scope.

The independent final host audit at 04:36:29 passed:

| Check | Result |
| --- | --- |
| Baseline secret/key hashes, App Attest configuration and database connection settings | Unchanged |
| Database container identity, image, version and start time | Unchanged; no database restart |
| Applied migrations | 14 to 15; only additive readiness migration `0015` newly applied |
| Authentication schema and runtime grants | Correct |
| Retained legacy API/auth identities, images and start times | Unchanged; both health checks HTTP 200 |
| Blue API/auth and exactly one running worker | Approved image; zero restarts |
| Private and public readiness | HTTP 200, exact approved digest |
| Release state and Nginx | Production/blue active, prior legacy state retained; Nginx matches saved state |
| Pending journal, registry credentials, temporary uploads and source backup archive | None remaining |
| Stable token helper and release tooling | Installed |

GitHub protection readback at 04:37:26 confirmed the owner reviewer and main-only
production environment restriction remained in place. Automatic releases remained
enabled. CI passed 42 GCP release-control tests and 35 host release tests; Backend
and Swift Core checks passed. The complete [iOS run for control commit `345e258`](https://github.com/nellesf/nextStop/actions/runs/36963649399)
succeeded at 04:31:13: 268 tests passed, one skipped, including all four UI tests.

A later 04:38 public readiness check also passed for both environments:
production still reported the approved `sha256:21083d7…` digest, while staging
reported `sha256:434b5a1d4268cbf1691d53d70c5d3d62ea3bba0193d923bee6cef605a41a5569`
from the successful [staging run for control commit `345e258`](https://github.com/nellesf/nextStop/actions/runs/36963800573).
The production promotion retained its originally approved application image;
staging subsequently advanced through its normal trusted-main workflow.

## Retry search continuity and named production broker

The retry used the same bounded synthetic search procedure, starting after the
backup had begun. One preliminary local token-client mistake sent a body to an
endpoint that requires an empty POST. The broker correctly rejected it; that
initial probe recorded only a successful public health check. After correcting
the local client, the search probe ran separately and included exactly two
additional samples after the deployment-success signal at 04:35:55.

| Measurement | Result |
| --- | --- |
| First / last search sample | 04:18:37.398 / 04:37:37.517 |
| Successful searches | 20 / 20, HTTP 200 with valid nonempty candidates and snapshot |
| Failed searches / health-only fallback samples in the corrected probe | 0 / 0 |
| Median latency | 763.5 ms |
| Maximum latency | 3,498 ms |
| Requests exceeding five seconds | 0 |

After the continuity probe stopped and released its port, the documented
`NEXTSTOP_BACKEND_ENVIRONMENT=production` broker on loopback 8766 used the installed
stable helper to mint a token. Exactly one synthetic public search at 04:38:34
returned HTTP 200 with valid candidates and a snapshot in 738 ms. An initial
local harness configuration accidentally combined named and legacy modes; the
broker rejected it before remote minting. The successful smoke used only the
named preset. This confirms the documented broker/API connection, not a complete
Simulator UI session or real-device App Attest continuity.

Both owned probe brokers stopped and released port 8766. All private temporary
probe scripts and files were removed; only sanitized aggregate evidence remains
locally. Tokens stayed in memory, and no route payload, response, private auth
content or credential was logged. The normal production connection is now
recorded in [development.md](../development.md#connected-debug-simulator-search).

No search failure was observed in the 20 one-minute samples spanning the sampled
backup and deployment period. Gaps between samples remain unobserved. This is not
a load/SLA guarantee, real-device attestation test, database recovery cutover or
TLS-certificate fingerprint comparison. The existing single-VM outage and
failover model is unchanged.

## TestFlight build 19 and immediate configuration correction

At 04:47:39 UTC a real-device challenge returned 200, followed by an assertion
returning 401 in 17 ms. The owner confirmed TestFlight version `0.1.0 (19)`.
Both the new and retained legacy auth processes had the same explicit build list
`1,10`, which excludes that shipped build. The App ID, production-environment
flag, signing key and auth database connection matched; the required auth grants
were present. No database or resource error explained this exchange. Diagnostics
intentionally retain no proof, key identifier or internal cryptographic reason.

A local cryptographic HTTP reproduction confirmed that a valid assertion for
an unlisted build returns 401, while adding that build permits the same existing
key to authenticate. This was a missing release configuration step, not evidence
that the environment split changed the app identity or keys.

The operator used the installed release controller's existing `--skip-migrations`
path to add only `19` to the host value, first on staging and then production.
Both releases used the already approved `9ec36e8` / `sha256:21083d7…` image.
The existing lock, candidate readiness, authenticated search, Nginx switching,
public gates and drain were retained. There was no DDL or role initialization,
and no backup receipt was fabricated or treated as covering another image.

| Configuration correction | Verified result |
| --- | --- |
| Staging deployment `6801627463` | Success; blue serving, effective list `1,10,19` |
| Production deployment `6801711757` | Success by 05:09 UTC; green serving, effective list `1,10,19` |
| Database and prior serving containers | Identity, image and start time unchanged |
| Other host configuration, signing key and App ID | Unchanged; development proofs still rejected |
| Temporary registry credentials and original config backup | Removed after successful checks |

The owner was then asked to repeat the search on the actual TestFlight device;
this record does not substitute synthetic gates for that confirmation.

The owner also requested a durable fix that removes manual build admission.
The accompanying source change validates the signed version as bounded metadata
without exact membership, while retaining all other App Attest checks; see
[ADR 0015](../adr/0015-app-attest-search-authentication.md#build-version-policy-clarification-2026-10-02).
Local validation passed 143 backend tests, lint, type checking, compilation and
77 deployment-tool tests. Auth-server startup passed with both an absent version
setting and the stale `1,10` setting. That source change is separate from the
configuration-only correction above and needs its own staged production release.

## Staging storage incident during the permanent fix

The permanent policy change is commit
`fbd248999625a6171e12986bba477b4e4c4a6ec4`, with immutable image digest
`sha256:e93e7f3a622169b74507a3c3fe5712d6641ef600b6c99ae30ef5b22b285890f7`.
Backend CI [36967749107](https://github.com/nellesf/nextStop/actions/runs/36967749107),
Swift Core CI [36967749129](https://github.com/nellesf/nextStop/actions/runs/36967749129)
and iOS CI [36967749127](https://github.com/nellesf/nextStop/actions/runs/36967749127)
passed. The first staging attempt
[36967899653](https://github.com/nellesf/nextStop/actions/runs/36967899653), explicit
deployment `6801796660`, failed early in the host-release step at 05:16:11.
No candidate containers or migration/role-initialization executions were observed;
the existing serving containers remained healthy.

At 05:20–05:22 the 30 GB system filesystem had only 27–104 MB free. The running
Docker daemon used `/var/lib/docker`, occupying approximately 24.7 GB, including
23.8 GB in the database volume. The separately provisioned data filesystem still
had about 149 GB free. `daemon.json` already specified `/srv/nextstop/docker`,
but that destination did not exist. The bootstrap installed Docker before writing
the configuration, allowing the package installation to start the daemon with its
default directory; `systemctl enable --now` did not reload the already running
daemon. This capacity evidence is consistent with disk exhaustion causing the
early release failure; the exact failed operation's private output was suppressed,
so no specific `ENOSPC` error was captured as incident evidence.

The operator moved only staging's existing Docker store under the release lock:

| Storage recovery | Verified result |
| --- | --- |
| Services stopped | Worker, four API/auth processes, then database at 05:32:39–05:32:40 |
| Quiescent copy verified | 2,282 entries / 24,536,846,631 bytes at 05:38:46 |
| Copy comparison | File SHA-256, sizes, ownership/modes, modification times, links and special-file metadata matched |
| Services recovered | Same six container identities/images; database on data filesystem; public readiness and synthetic search passed at 05:39:11 |
| Original preserved | Second verified copy on the existing data disk; only the inactive system-disk copy removed |
| Completed | 05:43:50; 24,787,165,184 system bytes free and 99,978,547,200 data bytes free |
| Independent postflight | 05:44:28; healthy database, both ready slots, one worker, zero Docker restart-counter increments/OOM events, unchanged release state and matching Nginx |

The database was deliberately stopped and restarted on staging during this move.
No production service or database was restarted. Production's DockerRootDir
already pointed to `/srv/nextstop/docker`; its system filesystem had about
21.7 GB free.

All staging named volumes and container logs now resolve to the data filesystem.
The compatibility symlink `/var/lib/docker` preserves existing absolute paths.
A Docker systemd mount dependency and pre-start mountpoint check prevent starting
against an unavailable data disk. One original store copy remains on the data
disk for deliberate later cleanup; it was not reused as live database state.
The separate containerd image store remains on the system disk. No image prune,
new disk, enlarged VM, copied production data or additional paid resource was
needed.

The bootstrap source now prepares the data-root and mount dependency before
package installation and checks the actual running root before marking setup
complete. It stops on conflicting existing storage/configuration instead of
attempting an automatic migration. Seven isolated executable shell regression
tests cover first package startup, wrong daemon root, unavailable mounts,
existing storage/configuration and completed-host preservation. All 49 GCP
deployment tests passed; the first-start test fails against the original script
for the expected ordering error. Existing completed hosts are not automatically
reconfigured by this source change.

## Permanent build-policy fix: staging passed, production review pending

Staging run `36967899653`, attempt 2, reused the exact `fbd2489` / `e93e7f3…`
artifact. Deployment ran from 05:45:18 to 05:49:17 and passed, including the
release controller's readiness, authenticated search and public serving gates.
Explicit staging deployment `6802170605` succeeded. The registry commit/digest
and successful staging-deployment promotion binding was independently verified.

The independent host audit at 05:50:25 confirmed the green API/auth slot and
single worker on `e93e7f3…`, with the previous blue API/auth identities and
`21083d7…` image retained. The database container identity/image remained unchanged
from the storage recovery and was healthy. Both local slots and public API/auth
readiness passed with their expected digests. Nginx matched the committed release
state, no pending journal remained, and volumes/logs remained on the data disk.
The system filesystem had approximately 24.8 GB free; the original store copy
remained preserved on the data disk.

At this checkpoint production still runs the configuration-only correction that
allows build 19. The durable removal of manual build admission has passed staging
and awaits the separate protected production review. A real TestFlight-device
retry remains unconfirmed; synthetic serving checks do not establish that result.

## Owner-approved permanent build-policy production release

At approximately 06:03:35 UTC the operator applied the owner's explicit approval
to the prepared production run
[36970859420](https://github.com/nellesf/nextStop/actions/runs/36970859420).
Its application is the staged `fbd2489` / `e93e7f3…` artifact above; release control
comes from `0ccaa9b5c28e49f05ae7eca6a1b04074258815ac`. Registry, main ancestry and
explicit staging deployment `6802170605` were reverified before approval.
The workflow created explicit application deployment `6802390560`. The
approval preserves the existing backup and rollout gates. It does not authorize
disabling the legacy compatibility credential, which remains separately scoped.

The backup phase started at 06:03:56. A read-only production baseline captured at
06:04:58 found the active green API/auth slot and worker on `21083d7…`, a healthy
database, eight running persistent services, zero Docker restart counters and no
pending release journal. Local/public readiness passed. Development proofs were
disabled and the legacy compatibility flag was enabled. The system and data
filesystems had approximately 21.7 GB and 99.8 GB free respectively. One already
stopped legacy cache-initializer helper was recorded separately from the running
services; it was not a serving failure.

A bounded search-continuity probe began at 06:04:50 using the documented named
production Simulator broker and short-lived tokens, never the legacy shared
credential. It runs the release gate's fixed synthetic search at intervals of at
least one minute, without overlap or catch-up bursts, with a 20-second request
timeout and a 45-minute maximum duration. Only sanitized time/status/latency
aggregates are retained. It began after backup startup and therefore does not
cover the complete backup period or prove real-device App Attest.

The production backup gate passed at 06:18:24 and deployment began immediately
afterward. The independent metadata audit at 06:18:53 found exactly one fresh
archive since approval, completed at 06:18:16.733 with 2,644,443,357 bytes. Its
generation and CRC32C/MD5 metadata were structurally valid, it was non-composite,
and no temporary composite-upload components remained. The expected bucket's
public-access prevention and uniform bucket-level access remained enforced.
The successful workflow had compared source/download SHA-256 and size and checked
the uploaded object before issuing its image-bound receipt. The independent
metadata audit corroborates freshness and privacy; it does not itself bind the
archive to an application image or replace that receipt. This archive was not
downloaded again or subjected to a new restore rehearsal.

The production deployment and explicit outcome both succeeded at 06:22:33.
Workflow `36970859420` finished successfully; the public API and auth readiness
endpoints independently returned HTTP 200 and the exact approved `e93e7f3…`
digest. The owner was asked to retry the installed TestFlight app after activation;
no app update is required for this backend-only policy change.

The independent production postflight at 06:25:06, with the worker mount-set
comparison completed at 06:26:19, passed:

| Final production check | Verified result |
| --- | --- |
| Active API/auth | Blue, exact approved `e93e7f3…` image; local/public readiness passed |
| Retained API/auth | Green `21083d7…`; container identities, images and start times unchanged |
| Legacy API/auth | Unchanged |
| Database | Identity, image, start time and mounts unchanged; healthy; no database restart |
| Applied migration set | Same 15 migrations as the baseline |
| Worker | Exactly one running worker, counted from the original container list; approved image; same named mounts |
| New API/auth/worker | Docker restart counters zero |
| App ID, signing key, private connection/configuration values | Compared privately and unchanged |
| App Attest development / legacy compatibility flags | Disabled / enabled, unchanged |
| Release state and temporary files | No pending journal, Nginx matches committed state, temporary release/registry files absent |
| Storage | Docker root still on the data disk; 21,652,791,296 system bytes and 99,982,213,120 data bytes free |

The private baseline was removed after successful comparison; only sanitized
aggregate evidence remains. The audit did not change services, configuration or
database content.

| Final continuity-probe measurement | Result |
| --- | --- |
| First / last request start | 06:04:50.789 / 06:25:56.606 |
| Successful searches | 22 / 22, HTTP 200 with valid candidates and snapshot |
| Search / token failures | 0 / 0 |
| Median / maximum latency | 692 ms / 3,113 ms |
| Searches over five seconds | 0 |
| Two additional samples after the completion signal | 06:24:56.596 and 06:25:56.606, both successful |

The probe exited successfully, its owned broker stopped, loopback port 8766 was
independently confirmed free, and the private temporary harness was removed.
Tokens and search payloads were not persisted. This confirms successful sampled
searches across the observed backup/rollout period and after completion; it does
not establish continuous availability between samples, a load SLA, or physical
TestFlight-device authentication. The owner's post-release device retry remains
pending at the time this record was written.
