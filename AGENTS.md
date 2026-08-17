# AGENTS.md

## Product goal

Build a low-distraction Apple CarPlay experience that shows at most the next five
charging parks a driver actually wants along a MapKit route. The iPhone app is a
minimal local profile editor. Apple Maps performs navigation.

Read `README.md`, `docs/architecture/overview.md`, and all accepted ADRs before
changing architecture or core search behavior.

## Current phase

The architecture and recommendations were approved by the owner on 2026-08-13.
Implementation is authorized under the accepted ADRs. New changes to an accepted
decision still require the explicit approval described at the end of this file.

## Critical domain rules

1. Use the actual route geometry. Corridor membership is geodesic distance to the
   route line and must be no more than 5,000 m; a bounding box alone is invalid.
2. User-facing distance is actual driving distance from the current location to
   the charging park, including the exit/detour. Never label straight-line or
   main-route progress as driving distance.
3. Count EVSEs, not cabinets and not connectors.
4. Availability is informational only and never affects candidate inclusion.
5. The selected food chain must be within 500 m geodesic distance. Opening status
   is informational and missing hours never fail a filter.
6. Apply all filters first, sort only by actual driving distance ascending, and
   return at most five. Never introduce a hidden score or automatically relax a
   filter.
7. A saved profile is immutable from CarPlay. Copy it into a ride-scoped search
   draft before edits.
8. Do not add vehicle profiles, state of charge, payments, reservations, accounts,
   tracking, ads, cloud sync, or turn-by-turn navigation to the MVP.
9. User-facing strings start in German but must live in localization resources.
   Source code and documentation are English.

## Architecture boundaries

- `NextStopCore` owns platform-neutral domain rules and use cases.
- SwiftUI and CarPlay depend on application interfaces; they contain no filtering,
  ranking, provider, or persistence logic.
- MapKit is the canonical route and actual driving-distance provider.
- The backend receives no profiles, favorites, account IDs, or destination text.
- Charging providers implement the provider protocol and normalize into the domain
  model before any search projection is built.
- Provider payloads are untrusted: validate, time out, rate limit, retain provenance,
  and never log secrets or precise user routes.
- PostgreSQL/PostGIS is the system of record and spatial query engine.
- No global mutable singleton. Use constructor/protocol-based dependency injection.

## Repository structure

```text
ios/NextStopCore/       pure Swift domain/application package and unit tests
ios/NextStopApp/        SwiftUI, persistence, MapKit, networking, App Intents
ios/NextStopCarPlay/    CPTemplateApplicationScene and template presenters
backend/src/domain/     normalized entities and policies
backend/src/application/ingestion and candidate-search use cases
backend/src/providers/  one adapter directory per source
backend/src/api/        versioned transport DTOs and validation
backend/src/persistence/PostGIS repositories and migrations
backend/src/jobs/       scheduled provider ingestion and projection rebuilds
docs/                   research, ADRs, API, privacy, operations
```

## Intended commands after scaffolding

```bash
cd ios/NextStopCore && swift test
xcodebuild -scheme NextStopApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
cd backend && npm ci
cd backend && npm run lint
cd backend && npm test
cd backend && npm run test:integration
```

Do not claim these commands work until the projects and the required full Xcode,
Node.js, and PostGIS/container tooling exist. Keep actual commands synchronized
with `README.md`, CI, and `docs/development.md`.

## Coding conventions

- Swift 6 strict concurrency; value types and `Sendable` domain values by default.
- Decimal quantities use integer base units (`meters`, `kilowatts`, UTC instants),
  never binary floating-point for identifiers or user selections.
- The TypeScript backend uses strict mode, no unchecked `any`, runtime
  validation at all I/O boundaries, and exhaustive domain enums.
- Inject clocks, ID generators, HTTP clients, and providers for deterministic tests.
- Keep provider DTOs private to their adapter. Never leak them into domain/API DTOs.
- Make thresholds and option lists central configuration/domain values, not magic
  numbers scattered across business code.
- Every data merge must preserve source, source record ID, observed time, fetched
  time, quality tier, and conflict information.

## Adding a charging provider

1. Create a provider ADR or update the accepted source decision.
2. Add the adapter under `backend/src/providers/<provider-name>/`.
3. Define and validate source DTOs; reject or quarantine malformed records.
4. Map cabinets/connectors to EVSE semantics correctly.
5. Emit normalized records with stable source keys and provenance.
6. Add mapping fixtures, idempotency tests, deduplication tests, quality/staleness
   rules, rate limits, timeouts, retry policy, and attribution/license notes.
7. Verify that a provider outage degrades coverage rather than failing the whole
   search.
8. Update the source matrix and operational runbook.

## Especially critical files (once present)

- Domain search policy and central search option catalog.
- Route geometry and exact-driving-distance orchestration.
- EVSE identity/deduplication and park clustering.
- Availability aggregation and informational presentation.
- Database migrations and spatial indexes.
- Versioned OpenAPI contract.
- CarPlay scene manifest and entitlement files.
- Privacy manifest, location usage text, and log redaction.

Require explicit owner approval before changing any rule above, the 5 km/200 m/
500 m thresholds, result limit, availability semantics, canonical routing source,
minimum iOS version, backend stack/database, clustering semantics, data licensing
strategy, CarPlay template family, or CEAP migration boundary.
