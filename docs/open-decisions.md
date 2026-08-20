# Approved decisions and external blockers

The owner approved all recommendations on 2026-08-13 and selected centrally
configured defaults for non-profile rides. The owner amended the charging-park
clustering decision on 2026-08-20. Implementation is authorized within the
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

## 3. Fine-park and no-food-campus semantics

**Decision amended 2026-08-20: retain deterministic complete-link parks with a
maximum 200 m diameter, and derive a separate bounded campus identity only for
searches without a food chain.** Fine parks are indivisible campus seeds.
Deterministically ordered member-location cross-edges of at most 200 m may merge
seed groups only while every underlying member pair in the union remains within
500 m. A `charging-campus-v1` ID is derived from sorted constituent fine-park IDs.

The backend selects the result unit before filters and pagination. Without food,
power filtering, campus-wide EVSE deduplication, minimum count, operators,
availability, navigation coordinate, corridor, and origin bound all apply to the
campus. With food, the complete-link fine park remains the candidate unit and the
existing exact restaurant predicate and restaurant-centric client grouping remain
unchanged.

The full 2026-07-28 Bundesnetzagentur snapshot produces 48,664 fine parks and
45,869 no-food campuses, with no campus over 500 m. Wertheim changes from three
fine parks to one campus with 66 qualifying EVSEs at >=150 kW. The problematic
Stuttgart 200 m-edge area is boundedly split from 12 fine parks into six campuses.
Universal complete-link would keep Wertheim duplicated; universal unbounded
connected components would merge urban chains over much larger distances.

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
- nearby restaurant required: no (`foodChain = nil`).

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
