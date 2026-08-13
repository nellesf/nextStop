# nextStop

nextStop is an Apple CarPlay-focused iOS app for EV drivers. Given a
destination and a small set of explicit criteria, it finds at most the next five
matching charging parks along the current MapKit route and hands the selected
park to Apple Maps. It does not provide turn-by-turn navigation.

Phase 1 research and the Phase 2 architecture were approved on 2026-08-13.
Implementation now starts with the portable, entitlement-independent Swift core,
followed by the vertical slice and the approved backend architecture.

## Non-negotiable product rules

- A charging park must be at most 5 km geodesic distance from the actual route
  polyline.
- Charging locations from different operators may form one park when the chosen
  clustering rule permits it within 200 m.
- EVSEs (simultaneously usable charging positions), not cabinets or connectors,
  are counted.
- Unknown availability never excludes a park by itself.
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
  NextStopCore/             # Pure Swift package: domain and use cases
  NextStopApp/              # SwiftUI app, MapKit, persistence, App Intents
  NextStopCarPlay/          # Entitlement-gated CarPlay adapter
  NextStopAppTests/
  NextStopCarPlayTests/
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

The CarPlay adapter is deliberately thin. The complete search flow and its
presentation model must be testable without the final CarPlay entitlement.

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

The portable Swift core can be built and tested with command-line Swift; see
[`docs/development.md`](docs/development.md). This Mac currently has Swift 6.3
command-line tools but no active full Xcode installation, Node.js, PostgreSQL, or
container runtime. Xcode-only app, simulator, CarPlay, and signing verification is
therefore performed on a separate development Mac after pulling the repository.
The checked-in `Swift Core` GitHub Actions workflow runs formatting and the full
package test suite on a matching hosted macOS toolchain after a push.

## Current next step

Build the vertical slice with the accepted decisions and one official, free
charging data source before broad European provider coverage.
