# Deployment architecture

Status: Accepted target architecture with an owner-approved single-VM staging
exception implemented on 2026-08-18. See ADR 0014.

## Private staging exception

The two-to-three-user TestFlight phase runs the complete modular monolith and
PostgreSQL/PostGIS on one `e2-standard-2` Compute Engine VM in Frankfurt. The API,
one charging/Swiss-live/OSM worker, and a release-scoped migrator use the same
artifact as separate processes and separate database credentials. A separately
attached persistent disk holds the database and OSM cache. Nginx terminates TLS at
`api.nextstop.tech`; only the API has a listener, PostgreSQL is not publicly
reachable, and SSH uses Google IAP.

The API login is read-only and table-scoped with a 15-second statement timeout.
The worker login has DML and projection-function privileges but no DDL or access to
the migration registry. The legacy bootstrap owner is used only by the one-shot
migrator and idempotent grant initializer. Deployments add or rotate the restricted
roles on an existing volume without recreating data or rebuilding projections.

Private staging requires a revocable bearer credential for candidate search;
`/health` remains unauthenticated. The credential is injected into the private
TestFlight build and provides only a staging abuse barrier because an app-bundled
shared secret is extractable. Public production must replace it with attested,
short-lived client credentials and per-client quotas. The API also rejects routes
outside its explicit size, point-count, region, segment-length, and total-length
budgets before PostGIS search.

The owner explicitly declined scheduled backups for this disposable staging
corpus. This exception does not satisfy the production availability or recovery
target below and must be replaced or re-approved before public production.

## Topology

Use one regional deployment of the backend modular monolith and one managed
PostgreSQL service with PostGIS. Start with a single API/worker artifact that runs
separate process roles:

- `api`: stateless HTTP candidate search;
- `worker`: scheduled provider ingestion and transactional projection rebuilds.

Run the resource-heavy OSM PBF ingestion in exactly one designated worker with a
persistent private cache volume. API processes never run ingestion; a
charging-only worker can set `OSM_INGESTION_ENABLED=false`.

They share code and database but can scale/restart independently. Do not introduce
microservices, Redis, Kafka, Elasticsearch, or a server-side router before measured
need.

## Environments

- Development: local PostGIS container or local service with public test fixtures.
- CI: ephemeral PostGIS per integration test job.
- Staging: production-like TLS, secrets, provider sandbox/public endpoints, no real
  user route retention.
- Production: EU/EEA hosting preferred for the initial audience and GDPR data-flow
  simplicity; exact vendor requires owner approval.

## Release sequence

1. Build immutable artifact and generate SBOM.
2. Run unit, provider fixture, OpenAPI, and PostGIS integration tests.
3. Scan dependencies and image; sign artifact.
4. Back up database and apply forward-compatible migrations with a least-privilege
   migrator role.
5. Deploy worker disabled, then API; run health/readiness and synthetic corridor
   checks.
6. Enable providers one at a time; shadow/build new projection and atomically
   publish after count/quality validation.
7. Roll traffic gradually; monitor only aggregate latency/error/source freshness.

## Secrets

- Provider/API credentials, DB credentials, signing material, and edge keys live in
  the deployment secret manager.
- iOS contains no provider keys. Private staging injects its revocable shared
  search credential at build time from an ignored local configuration file.
- Rotate independently by environment. Document owner, purpose, creation, expiry,
  and emergency revocation without storing the value in Git.

## Database

- PostgreSQL with the PostGIS extension and automated point-in-time recovery.
- GiST indexes on fine-park, campus, and normalized locations; conventional indexes
  on provider keys, EVSE identity, observation time, and projection version.
- Multicolumn GiST-indexed fine-park and campus power-search projections keyed by
  projection version, supported minimum-power option, and coordinate, plus
  normalized fine-park/location and campus/fine-park memberships. Retained snapshot
  versions therefore do not enlarge current spatial index scans.
- The serial power-projection rebuild has a function-local `work_mem` override;
  API sessions retain PostgreSQL defaults and cannot multiply that memory budget.
- A separate GiST-indexed OSM food-POI projection and version-pinned derived
  fine-park/POI cache; do not merge it into redistributed charging source tables.
- Separate roles for migrations, worker writes, API read/search, and operations.
- Retain provider raw payloads only as allowed/needed for replay; route requests are
  never stored in domain tables or backups.

## Health and observability

- Liveness: process loop only.
- Readiness: schema version and ability to query the active projection.
- Provider health/freshness: separate operational status, never make the API
  process unready solely because one provider is down.
- Metrics: candidate latency/count, DB timings, provider import counts/failures,
  quarantine, source age, projection age. No route coordinates or persistent IDs.
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

- Separate bundle/team configurations for development and production.
- Managed EV-charging entitlement must match the App ID and provisioning profile.
- No entitlement file with an unapproved capability in a distribution build.
- TestFlight/App Store release requires current privacy manifest, German
  localization, Maps/Siri/location disclosures, attribution, and CarPlay review.
