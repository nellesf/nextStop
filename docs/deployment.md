# Deployment architecture

Status: the owner approved the two-VM staging/production scope on 2026-10-01.
[ADR 0018](adr/0018-staging-production-releases.md) replaces the earlier
managed-database production target for this deployment phase. Provisioning and
release activation are tracked in the [infrastructure runbook](../deploy/gcp/README.md).

## Selected deployment

Retain the existing `e2-standard-2` VM, local PostgreSQL/PostGIS database and
persistent volumes as production. Its Google Cloud project keeps the historical
ID `nextstop-tech-staging`; its endpoint stays `api.nextstop.tech`. Add one isolated
staging VM in `nextstop-tech-testing` at `api-staging.nextstop.tech`. Both VMs are
named `nextstop-backend` and run in Frankfurt (`europe-west3-a`). There is no
production database move or production DNS cutover.

Each environment runs the API, App Attest auth, one charging/Swiss-live/OSM worker
and a release-scoped migrator as separate processes with separate database roles.
A persistent data disk holds local PostGIS and provider caches. Nginx terminates
TLS; database and internal API/auth ports remain private, and SSH uses Google IAP.
The scope has no load balancer, redundant hosts, managed database or separate
worker VM.

The candidate-search login is read-only and table-scoped with a 15-second
statement timeout. A separate authentication login can modify only App Attest
challenge and credential tables. The worker login has DML and projection-function
privileges but no DDL or access to the migration registry. The legacy bootstrap
owner is used only by the one-shot migrator and idempotent grant initializer.
Deployments add or rotate the restricted roles on an existing volume without
recreating data or rebuilding projections.

Physical-device production search uses Apple App Attest and server-issued
15-minute tokens. Production rejects legacy bearer and development-attestation
bypasses. The Debug Simulator uses a loopback Mac broker to obtain a short-lived
token through IAP for its explicitly selected environment. Release builds exclude
this fallback. `/health` remains unauthenticated process liveness; `/ready` checks
serving prerequisites. The API rejects routes outside its size, point-count,
region, segment-length and total-length budgets before PostGIS search.

Staging is disposable and isolated from private production data. Production DDL
requires a recent verified backup of its existing local database in private GCS.
Exclude submitted report payloads from durable application backups and verify
restoration in an isolated database before production release activation. This
backup gate does not provide continuous point-in-time recovery.

## Topology

API, auth, worker and migrator use one immutable application image. Their
processes and credentials are separate, but they share the environment's VM and
local database. Run resource-heavy OSM PBF ingestion in exactly one worker with a
persistent private cache; API/auth never run ingestion. A charging-only worker
can set `OSM_INGESTION_ENABLED=false`.

Two API/auth slots on the same VM allow a candidate application to pass readiness
and synthetic search gates before a graceful Nginx switch. They provide release
continuity, not host/database redundancy. Production imports can still contend
for CPU, memory and database I/O. Preserve published projections, bound work, and
monitor contention. No additional infrastructure or failover is implied by this
phase.

## Environments

- Development: local PostGIS container or local service with public test fixtures.
- CI: ephemeral PostGIS per integration test job.
- Staging: independent project, VM, database, credentials, signing keys and caches;
  public provider data, no copied production authentication or support state.
- Production: existing Google Cloud Frankfurt VM and local PostGIS, with the
  unchanged public origin, data and keys.

The central immutable image repository remains in `nextstop-tech-staging`, even
though staging compute is in `nextstop-tech-testing`. The EUR 200/month combined
budget uses a planning estimate of EUR 155–175/month on the owner's reported
current cost basis. Report expected overruns; do not automatically stop services.

## Release sequence

1. Pass unit, provider, API-contract, migration-policy and real PostGIS checks.
2. Build a trusted main commit once in the central registry with immutable tags;
   verify the selected digest and revision, then deploy it to staging.
3. Select that successfully staged commit and identical image in the protected
   production promotion workflow. No production rebuild occurs.
4. Verify a recent backup of the exact production local database in private GCS.
   Serialize additive migrations with short lock waits and finite deadlines.
5. Start candidate API/auth beside the serving slot. Verify both services and an
   authenticated synthetic corridor search before gracefully switching Nginx.
6. Let existing requests drain and retain the previous slot for rollback. Replace
   the singleton worker only after the serving gates pass.
7. Monitor aggregate latency, errors and freshness. Failed candidate checks retain
   or restore the serving application; application rollback never reverses DDL.

## Secrets

- Provider/API credentials, DB credentials, App Attest configuration and token
  signing material use restricted host configuration; TLS private keys remain
  restricted to the proxy. Never commit them to Git or include them in release
  archives. CI authenticates through Workload Identity Federation.
- iOS contains no provider or production search secrets. A private Debug Simulator
  may request a short-lived token from a loopback-only Mac helper authenticated
  through Google Cloud IAP; Release builds exclude that provider.
- Rotate independently by environment. Document owner, purpose, creation, expiry,
  and emergency revocation without storing the value in Git.

## Database

- Local PostgreSQL with the PostGIS extension, a persistent disk and a verified
  production pre-DDL backup to private GCS. No automatic database failover or
  point-in-time recovery is part of this scope.
- GiST indexes on fine-park, campus, and normalized locations; conventional indexes
  on provider keys, EVSE identity, observation time, and projection version.
- Multicolumn GiST-indexed fine-park and campus power-search projections keyed by
  projection version, supported minimum-power option, and coordinate, plus
  normalized fine-park/location and campus/fine-park memberships. Retained snapshot
  versions therefore do not enlarge current spatial index scans.
- The serial power-projection rebuild has a function-local `work_mem` override;
  API sessions retain PostgreSQL defaults and cannot multiply that memory budget.
- Power builds use indexed temporary inputs with fresh per-version statistics and
  commit before publication. The worker receives TEMP and a fixed-table statistics
  refresh function, with bounded SQL deadlines. Static feed files use a persistent
  `PROVIDER_CACHE_DIRECTORY`. See the [refresh runbook](operations/charging-refresh.md)
  for input reuse, derived-history retention and incident recovery.
- A separate GiST-indexed OSM food-POI projection and version-pinned derived
  fine-park/POI cache; do not merge it into redistributed charging source tables.
- Separate roles for migrations, worker writes, API read/search, App Attest auth
  state, and operations.
- Retain provider raw payloads only as allowed/needed for replay; route requests are
  never stored in domain tables or backups.

## Health and observability

- Liveness: process loop only.
- Readiness: required migrations and queryable published charging/food projections;
  auth verifies its configuration and database access separately.
- Provider health/freshness: separate operational status, never make the API
  process unready solely because one provider is down.
- Metrics: candidate latency/count, DB timings, coarse App Attest outcome,
  provider import counts/failures, quarantine, source age, projection age. No
  route coordinates, key identifiers/hashes, assertions, or access tokens.
- Alerts: no active projection, expiry beyond policy, repeated import failure,
  elevated 5xx/429, DB saturation, projection publish failure.

## Rollback and recovery

- Keep at least the previous valid search projection and atomically switch the
  active version.
- Application rollback must remain compatible with the expanded schema; destructive
  migrations require a separately approved multi-release plan.
- Provider rollback disables its new observations and rebuilds from the prior valid
  projection without deleting raw audit history.

## iOS distribution

- One bundle ID and signing configuration, with named Debug Simulator schemes for
  staging and production. Physical devices and every archive/TestFlight build
  always use production; no runtime environment picker.
- Enable App Attest for `de.nextstop.app`, configure the exact App ID prefix on
  the backend, and regenerate provisioning profiles. App Attest signing
  environment comes from the shared entitlement/Info.plist build setting. Physical
  Debug may fail closed against production; use Release/TestFlight for device
  verification without enabling development proofs globally.
- Verify App Attest on a physical device. The iOS Simulator is covered only by the
  compile-time Debug loopback provider and cannot satisfy the distribution gate.
- Managed EV-charging entitlement must match the App ID and provisioning profile.
- No entitlement file with an unapproved capability in a distribution build.
- TestFlight/App Store release requires current privacy manifest, German
  localization, Maps/Siri/location disclosures, attribution, and CarPlay review.
