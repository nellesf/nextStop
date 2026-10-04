# nextStop

nextStop is an Apple CarPlay-focused iOS app for EV drivers. Given a
destination and a small set of explicit criteria, it finds at most the next five
matching charging stops along the current MapKit route and opens the selected
restaurant or operator's native place in Apple Maps. Without a food filter, one
stop is a bounded charging campus. With a food filter, one stop represents one
restaurant and combines all qualifying nearby fine parks by charging operator.
It does not provide turn-by-turn navigation.

Phase 1 research and the Phase 2 architecture were approved on 2026-08-13; the
charging-park clustering decision was amended on 2026-08-20. On 2026-10-02, the
owner approved counting and displaying only operators with an unambiguous Apple
charger match, with the selected minimum EVSE count checked again before results.
Implementation includes the portable, entitlement-independent Swift core, a
localized SwiftUI profile editor with local SwiftData persistence, and the first
ride flow: precise current location, a canonical MapKit route, privacy-scoped
candidate search, exact per-candidate MapKit driving distances, versioned OSM
restaurant checks, distance-only ranking, per-operator EVSE counts, and Apple Maps
handoff. Before final results, bounded sequential Apple charger matching confirms
each operator. Only confirmed operators appear and contribute to the EVSE total;
each campus or individual fine park must still meet the selected minimum count.
Each remaining operator appears once per restaurant result with its combined EVSE
count and one 48-point Apple Maps button. Handoff reuses the successful match and
original lookup scope to open the native Apple place by stable Place ID. The
restaurant has a separate button whose Apple lookup runs only on tap; OSM remains
the restaurant search predicate. CarPlay uses the same confirmed operator list,
counts and native-place handoff. Neither surface opens a guessed place; the user
may start navigation from Apple Maps.
The same application flow is connected to a template-native CarPlay scene with
profile and saved-destination selection, a ride summary with immediate search or
filter-edit actions and all four current criteria, ride-scoped fixed filter
choices, and stable maximum-five POI results. Each picker result shows its qualifying
EVSE total and actual driving distance on two lines. The selected result keeps its
place name and asks where to go when a restaurant is available; without a
restaurant it opens the operator list directly. The app supplies operator selection,
power, known availability, coverage, and attribution through native detail templates.
The [CarPlay layout audit](docs/testing/carplay-layout/visual-review.md) records
clipped text and detail summaries omitted by the native layout on some displays.
Explicit refresh, no-result
relaxation, and Apple Maps handoff remain available. Local favorites and the capped
recent-destination list are shared by the iPhone and CarPlay surfaces. A localized
App Intent lets Siri resolve a spoken destination through MapKit and open the same
ride preparation. The strict
TypeScript/Fastify backend now discovers and imports the current official
Bundesnetzagentur register automatically, joins the official Swiss
`ich-tanke-strom` static and live feeds by EVSE identity, builds deterministic
complete-link charging parks plus bounded no-food campuses, publishes versioned
PostGIS static/live snapshots atomically, and serves exact 5 km route-corridor
candidates through signed stable snapshots. Supported physical devices use Apple
App Attest to obtain short-lived search access tokens; Debug Simulator builds use
a loopback Mac broker authenticated through Google Cloud IAP and contain no shared
backend secret. A
separate daily OSM projection imports supported chains from cached Geofabrik PBF
extracts and enforces the exact 500 m restaurant predicate.

The iPhone includes voluntary error reporting with a free-text description and an
initially unchecked option to attach existing sanitized technical logs and the
app/build/iOS versions shown in the attachment preview. Local recording is on by
default, bounded to 200 events from seven days, and can be turned off and cleared
on iPhone. With no saved logs the form explains the empty state and links directly
to recording settings; it cannot recover past errors. Reports are sent
only after explicit submission, can be withdrawn in the app, and expire after
30 days with scheduled server cleanup. Search recovery remains silent. The report
flow includes localized privacy information and requires genuine controller/contact
configuration plus the matching backend deployment and public disclosures before
it can receive reports.

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
  restaurant grouping with food. Before final results, only operators confirmed by
  the existing Apple charger matcher remain visible and count toward the EVSE
  minimum, which is rechecked per campus or independently per fine park.
- Availability remains informational and never filters a candidate.
- A selected food chain must be within 500 m geodesic distance of the
  power-filtered fine-park navigation coordinate.
- With a selected food chain, fine parks that match the same stable restaurant POI
  are presented as one result. Exact operator names are combined and their
  qualifying EVSE counts are summed after Apple confirmation and the per-fine-park
  minimum-count recheck. The nearest surviving fine park by actual driving
  distance determines result order and displayed driving distance. Collect the
  complete original restaurant group before matching; preserve that group's
  power-qualified lookup evidence for matching, ride-local caching and handoff.
- Opening hours are informational only.
- Results are sorted only by actual MapKit driving distance from the current
  location and capped at five campuses without a food filter or five restaurants
  with one, after every eligibility filter; later candidates replace discarded
  results. Filters are never relaxed automatically. Failed or throttled Apple
  searches remain retryable errors, and cancellation never becomes a confirmed
  no-match. Sequential Apple lookups add latency without a promised search SLA.
- Candidate distance extraction accepts valid MapKit zero-distance responses even
  when their route line contains only one distinct point. Full route geometry is
  required for the destination corridor; candidate distances pass through the
  ordinary range filter before ranking.
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
              | TLS; search route geometry + criteria
              | separate, explicitly submitted support reports
              v
Modular backend
  versioned HTTP API
  provider normalization and provenance
  conservative EVSE deduplication
  deterministic complete-link 200 m fine-park clustering
  deterministic 200 m-edge / 500 m-diameter no-food campus projection
  versioned OSM restaurant ingestion + attribution
  cached search projection
  isolated support intake + bounded retention/deletion
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
  NextStopAppUITests/       # Synthetic iPhone UI flows and screenshot checkpoints
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

- [Product backlog and implementation status](docs/backlog.md)
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
- [App error reports and silent retries](docs/operations/app-diagnostics.md)
- [User-submitted report operations and retention](docs/operations/user-error-reports.md)
- [User-initiated reporting decision](docs/adr/0017-user-initiated-error-reports.md)
- [Backend and proxy request diagnostics](docs/operations/request-diagnostics.md)
- [Testing strategy](docs/testing.md)
- [Deployment architecture](docs/deployment.md)
- [Google Cloud staging and production releases](deploy/gcp-vm/README.md)
- [Known limitations](docs/known-limitations.md)
- [OpenStreetMap food-POI import runbook](docs/operations/openstreetmap-food-poi-import.md)
- [Charging refresh performance and recovery](docs/operations/charging-refresh.md)
- [Approved decisions and remaining external blockers](docs/open-decisions.md)
- [Architecture decision records](docs/adr/)

## Build and test status

The checked-in `ios/NextStop.xcodeproj` opens the iPhone app and its local
`NextStopCore` package directly. On 2026-10-01, Xcode 27.0 on this Mac passed the
targeted environment/authentication and report-receipt tests in Staging Debug
(28 tests) and Release (23 tests); the Simulator broker suite passed eight tests.
The Xcode 26 CI workflow continues to cover the wider app, CarPlay presenter, and
UI suites. Real-device App Attest and provisioned CarPlay still require their
separate acceptance checks.

Choose `NextStop-Staging` for the staging Simulator API or
`NextStop-ProductionTest` for the production Simulator API, with the matching Mac
broker. `NextStop-Release`, all physical-device builds, and every archive/TestFlight
build use `https://api.nextstop.tech`; staging is Simulator-only. All schemes keep
the same bundle ID and signing configuration. The original `NextStopApp` scheme
remains the production default for existing workflows. See the exact commands and
backend-scoped receipt migration in
[`docs/development.md`](docs/development.md#backend-environments-and-distribution).

Production retains the existing `nextstop-tech-staging` project, VM, and database.
The separate `nextstop-tech-testing` project is staging for tests and release
verification; this initial split does not move the production database or add
production redundancy.

## Current next step

Complete the environment rollout, configure the exact App ID prefix for
production App Attest, and verify a production-signed Release/TestFlight device
exchange. Production continues to reject development attestations. Separately
obtain Apple's managed EV-charging CarPlay entitlement and matching provisioning.
German authority records currently have no
official nationwide live state; Swiss `ich-tanke-strom` results do and German
results remain explicitly unknown.
