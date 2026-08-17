# nextStop

nextStop is an Apple CarPlay-focused iOS app for EV drivers. Given a
destination and a small set of explicit criteria, it finds at most the next five
matching charging parks along the current MapKit route and hands the selected
park to Apple Maps. It does not provide turn-by-turn navigation.

Phase 1 research and the Phase 2 architecture were approved on 2026-08-13.
Implementation includes the portable, entitlement-independent Swift core, a
localized SwiftUI profile editor with local SwiftData persistence, and the first
ride flow: precise current location, a canonical MapKit route, privacy-scoped
candidate search, exact per-candidate MapKit driving distances, optional MapKit
restaurant checks, distance-only ranking, per-operator EVSE counts, and Apple Maps
handoff. When a restaurant is selected, the handoff keeps the original ride
destination and inserts that restaurant as a waypoint. The same
application flow is connected to a template-native CarPlay scene with profile
and saved-destination selection, ride-scoped fixed filter choices, stable
maximum-five POI results, explicit refresh, no-result relaxation, and Apple Maps
handoff. Local favorites and the capped recent-destination list are shared by the
iPhone and CarPlay surfaces. A localized App Intent lets Siri resolve a spoken
destination through MapKit and open the same ride preparation. The strict
TypeScript/Fastify backend now discovers and imports the current official
Bundesnetzagentur register automatically, joins the official Swiss
`ich-tanke-strom` static and live feeds by EVSE identity, builds deterministic
charging parks, publishes versioned PostGIS static/live snapshots atomically, and
serves exact 5 km route-corridor candidates through signed stable snapshots.

## Non-negotiable product rules

- A charging park must be at most 5 km geodesic distance from the actual route
  polyline.
- Charging locations from different operators may form one park when the chosen
  clustering rule permits it within 200 m.
- EVSEs (simultaneously usable charging positions), not cabinets or connectors,
  are counted.
- The minimum-power filter is applied to individual EVSEs before per-operator
  counts, minimum park size, and informational availability are aggregated.
- Availability remains informational and never filters a park.
- A selected food chain must be within 500 m geodesic distance of the park.
- Opening hours are informational only.
- Results are sorted only by actual MapKit driving distance from the current
  location and capped at five. Filters are never relaxed automatically.
- Profiles, favorites, and recent destinations remain local. CarPlay edits are
  ride-scoped and never mutate a saved profile.

## Architecture

```text
iPhone + CarPlay
  SwiftUI configuration UI
  CarPlay system templates
  App Intents / Siri
  MapKit route + exact per-candidate driving distance
              |
              | TLS; route geometry + search criteria only
              v
Modular backend
  versioned HTTP API
  provider normalization and provenance
  conservative EVSE deduplication
  deterministic 200 m park clustering
  cached search projection
              |
              v
PostgreSQL + PostGIS
  raw provider records
  normalized charging entities
  field-level provenance and quality
  GiST-indexed charging-park projection
```

The full rationale and boundaries are in
[`docs/architecture/overview.md`](docs/architecture/overview.md).

## Repository layout

```text
ios/
  NextStop.xcodeproj        # Checked-in iOS app project
  project.yml              # Reproducible XcodeGen project definition
  NextStopCore/             # Pure Swift package: domain and use cases
  NextStopApp/              # SwiftUI app, MapKit, persistence, App Intents
  NextStopCarPlay/          # Presenter, shared ride use case, and thin CarPlay adapter
  NextStopAppTests/
  NextStopCarPlayTests/     # Entitlement-independent CarPlay tests
backend/
  src/
    domain/
    application/
    api/
    providers/
    persistence/
    jobs/
  migrations/
  tests/
deploy/
docs/
  adr/
  api/
  architecture/
  privacy/
  research/
```

The CarPlay adapter is deliberately thin. Its presentation and search flow are
testable without the final CarPlay entitlement; launching the vehicle scene still
requires Apple's managed capability and matching provisioning.

## Documentation map

- [Local development](docs/development.md)
- [Architecture](docs/architecture/overview.md)
- [Requirements analysis](docs/architecture/requirements-analysis.md)
- [Domain data model](docs/architecture/data-model.md)
- [Routing and search](docs/architecture/routing-and-search.md)
- [Provider concept](docs/architecture/providers.md)
- [Clustering and deduplication](docs/architecture/clustering-and-deduplication.md)
- [CarPlay architecture and screen flow](docs/architecture/carplay.md)
- [API contract](docs/api/openapi.yaml)
- [Apple platform research](docs/research/apple-platform.md)
- [Charging data source research](docs/research/charging-data-sources.md)
- [POI source research](docs/research/poi-sources.md)
- [Privacy data flow](docs/privacy/data-flow.md)
- [Testing strategy](docs/testing.md)
- [Deployment architecture](docs/deployment.md)
- [Known limitations](docs/known-limitations.md)
- [Approved decisions and remaining external blockers](docs/open-decisions.md)
- [Architecture decision records](docs/adr/)

## Build and test status

The checked-in `ios/NextStop.xcodeproj` opens the iPhone app and its local
`NextStopCore` package directly. On 2026-08-15, the Xcode 26 CI suite compiled and
tested the iPhone app, CarPlay adapter, local destination persistence, and App
Intent metadata successfully; the Swift core and backend/PostGIS workflows were
also green. This machine has Node.js 24 LTS for backend checks but no active full
Xcode installation, so interactive MapKit, signing, and provisioned CarPlay checks
still run on the separate Xcode Mac. See
[`docs/development.md`](docs/development.md).

## Current next step

Obtain Apple's managed EV-charging CarPlay entitlement for the App ID and matching
provisioning. After that external gate is satisfied, perform one integrated
acceptance run with the automatic authority-provider pipeline. German authority
records currently have no official nationwide live state; Swiss
`ich-tanke-strom` results do and German results remain explicitly unknown.
