# Approved decisions and external blockers

The owner approved all recommendations on 2026-08-13 and selected centrally
configured defaults for non-profile rides. Implementation is authorized within the
accepted ADR boundaries.

## 1. Minimum iOS version

**Decision: iOS 18.0.** It keeps a contemporary support window in 2026,
supports modern SwiftUI, MapKit, App Intents, and SwiftData, and still leaves the
CarPlay code on mature system templates. iOS 17.0 is the compatibility alternative
and is technically sufficient for the core MVP, but expands the test matrix and
support horizon.

See ADR 0001.

## 2. Backend implementation stack

**Decision: a TypeScript modular monolith on Node.js active LTS with
Fastify, PostgreSQL, and PostGIS.** It provides strong runtime schema validation,
good ingestion ergonomics, and a small operational footprint. Alternatives:

- Swift server stack: language sharing, but a smaller PostGIS/provider ecosystem.
- Python/FastAPI: excellent data tooling, but weaker compile-time guarantees and a
  second set of strictness conventions.

The database recommendation is PostgreSQL + PostGIS under every option. See ADRs
0003 and 0004.

## 3. Exact 200 m clustering semantics

**Decision: deterministic diameter-bounded agglomeration (complete-linkage),
so no two member locations in a park are more than 200 m apart.** A transitive
DBSCAN/connected-component rule can chain locations A–B–C into one park even when
A and C are more than 200 m apart. That conflicts with the phrase “maximum cluster
distance,” but DBSCAN may better represent long physical service areas.

See ADR 0006.

## 4. First real provider for the vertical slice

**Decision: Germany's official Bundesnetzagentur charging-station register
for the first ingestion and unknown-availability path, followed immediately by
Switzerland's official `ich-tanke-strom` static + real-time feeds for live status.**
Starting with Switzerland instead would demonstrate live availability sooner;
starting with Open Charge Map would cover more countries but would lower authority
and introduce mixed-license filtering from day one.

See ADR 0008 and the source research.

## 5. Criteria when the user chooses a destination without a profile

Use an explicit central default set that is always visible on the ride summary and
editable before search:

- charging stop: 50–100 km;
- minimum charging points: 4 EVSEs;
- minimum power: 100 kW;
- fast food: any.

See accepted ADR 0012. These defaults are not persisted back into a profile and
are never automatically relaxed.

## 6. Availability semantics

**Decision: availability is informational and never filters candidates.** The MVP
does not expose a minimum-free-EVSE criterion in profiles, ride drafts, CarPlay, or
the backend API. Live data remains visible wherever an authorized provider supplies
it. See ADR 0013.

## 7. Recent-destination limit

**Decision: 20, centrally configured, with newest-first de-duplication.**
Favorites and profiles need no low arbitrary limit for MVP beyond defensive local
storage limits. This is easy to change but should be product-owned.

## External blockers, not architecture choices

- Apple must approve the EV-charging CarPlay entitlement before end-to-end CarPlay
  execution and distribution.
- A full Xcode installation must be selected locally before iOS builds.
- A production EU/EEA hosting vendor, managed PostGIS service, and operational
  secret manager still require owner selection before deployment.
