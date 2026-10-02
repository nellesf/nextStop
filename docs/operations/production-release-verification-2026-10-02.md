# Production release verification, 2026-10-02

## Status and authorized artifact

**Production promotion passed.** The first owner-approved attempt failed safely
in its backup phase. The authorized retry completed successfully with the same
staged application image. Production now serves the blue API/auth slot with one
replacement worker; the legacy API/auth containers remain available for rollback.
The final host audit and named production Simulator broker smoke also passed.

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
