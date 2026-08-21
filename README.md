# nextStop

nextStop is an Apple CarPlay-focused iOS app for EV drivers. Given a
destination and a small set of explicit criteria, it finds at most the next five
matching charging stops along the current MapKit route and hands the selected
restaurant or charging campus to Apple Maps. Without a food filter, one stop is a
bounded charging campus. With a food filter, one stop represents one restaurant
and combines all qualifying nearby fine parks by charging operator. It does not
provide turn-by-turn navigation.

Phase 1 research and the Phase 2 architecture were approved on 2026-08-13; the
charging-park clustering decision was amended on 2026-08-20.
Implementation includes the portable, entitlement-independent Swift core, a
localized SwiftUI profile editor with local SwiftData persistence, and the first
ride flow: precise current location, a canonical MapKit route, privacy-scoped
candidate search, exact per-candidate MapKit driving distances, versioned OSM
restaurant checks, distance-only ranking, per-operator EVSE counts, and Apple Maps
handoff. Each charging operator appears once per restaurant result with its
combined EVSE count and one 48-point Apple Maps button; the restaurant has one too.
A tap performs a bounded, conservative place match
and opens the native Apple place by stable Place ID so Apple Maps can show its own
current details and navigation action. A missing unambiguous match is reported
instead of opening a guessed place. CarPlay keeps its direct navigation handoff;
when a restaurant is selected, it keeps the original destination and inserts the
restaurant as a waypoint.
The same application flow is connected to a template-native CarPlay scene with
profile and saved-destination selection, ride-scoped fixed filter choices, stable
maximum-five POI results, explicit refresh, no-result relaxation, and Apple Maps
handoff. Local favorites and the capped recent-destination list are shared by the
iPhone and CarPlay surfaces. A localized App Intent lets Siri resolve a spoken
destination through MapKit and open the same ride preparation. The strict
TypeScript/Fastify backend now discovers and imports the current official
Bundesnetzagentur register automatically, joins the official Swiss
`ich-tanke-strom` static and live feeds by EVSE identity, builds deterministic
complete-link charging parks plus bounded no-food campuses, publishes versioned
PostGIS static/live snapshots atomically, and serves exact 5 km route-corridor
candidates through signed stable snapshots. Supported physical devices use Apple
App Attest to obtain short-lived search access tokens; Debug Simulator builds use
a loopback Mac broker authenticated through Google Cloud IAP and contain no shared
staging secret. A
separate daily OSM projection imports supported chains from cached Geofabrik PBF
extracts and enforces the exact 500 m restaurant predicate.

## Non-negotiable product rules

- The selected power-specific candidate navigation coordinate must be at most 5 km
  geodesic distance from the actual route polyline.
- A fine charging park uses deterministic complete-link clustering: every pair of
  member locations is at most 200 m apart.
- Without a food filter, fine parks are indivisible seeds of a
  `charging-campus-v1` result. Deterministically ordered cross-park edges of at
  most 200 m may merge seeds only while the union diameter remains at most 500 m.
  The backend chooses and aggregates this campus before filtering and pagination.
- EVSEs (simultaneously usable charging positions), not cabinets or connectors,
  are counted.
- The minimum-power filter is applied to individual EVSEs before candidate-wide
  deduplication, per-operator counts, minimum size, and informational availability
  are derived. Counts cover the whole campus without food and one fine park before
  restaurant grouping with food.
- Availability remains informational and never filters a candidate.
- A selected food chain must be within 500 m geodesic distance of the
  power-filtered fine-park navigation coordinate.
- With a selected food chain, fine parks that match the same stable restaurant POI
  are presented as one result. Exact operator names are combined and their
  qualifying EVSE counts are summed; the nearest member fine park by actual driving
  distance determines result order and displayed driving distance.
- Opening hours are informational only.
- Results are sorted only by actual MapKit driving distance from the current
  location and capped at five campuses without a food filter or five restaurants
  with one. Filters are never relaxed automatically.
- Profiles, favorites, and recent destinations remain local. CarPlay edits are
  ride-scoped and never mutate a saved profile.

## Architecture

```text
iPhone + CarPlay
  SwiftUI configuration UI
  CarPlay system templates
  App Intents / Siri
  MapKit route + exact per-candidate driving distance
  App Attest + memory-only short-lived search token
              |
              | TLS; route geometry + search criteria only
              v
Modular backend
  versioned HTTP API
  provider normalization and provenance
  conservative EVSE deduplication
  deterministic complete-link 200 m fine-park clustering
  deterministic 200 m-edge / 500 m-diameter no-food campus projection
  versioned OSM restaurant ingestion + attribution
  cached search projection
              |
              v
PostgreSQL + PostGIS
  raw provider records
  normalized charging entities
  field-level provenance and quality
  GiST-indexed fine-park and campus search projections
  separate OSM POI projection and fine-park/POI match cache
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
- [Google Cloud single-VM staging](deploy/gcp-vm/README.md)
- [Known limitations](docs/known-limitations.md)
- [OpenStreetMap food-POI import runbook](docs/operations/openstreetmap-food-poi-import.md)
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

Enable App Attest for `de.nextstop.app`, provide the exact App ID prefix to staging,
and verify one development-signed physical-device exchange plus one production
TestFlight exchange. Separately obtain Apple's managed EV-charging CarPlay
entitlement and matching provisioning. German authority records currently have no
official nationwide live state; Swiss `ich-tanke-strom` results do and German
results remain explicitly unknown.
