# Deployment architecture

Status: Accepted architecture; no deployment artifacts exist yet.

## Topology

Use one regional deployment of the backend modular monolith and one managed
PostgreSQL service with PostGIS. Start with a single API/worker artifact that runs
separate process roles:

- `api`: stateless HTTP candidate search;
- `worker`: scheduled provider ingestion and transactional projection rebuilds.

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
- iOS contains only the public backend base URL and no provider keys.
- Rotate independently by environment. Document owner, purpose, creation, expiry,
  and emergency revocation without storing the value in Git.

## Database

- PostgreSQL with the PostGIS extension and automated point-in-time recovery.
- GiST indexes on park/normalized locations; conventional indexes on provider keys,
  EVSE identity, observation time, and projection version.
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
