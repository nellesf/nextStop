# System architecture

Status: Accepted on 2026-08-13.

## Goals

- Keep every driving interaction short and template-native.
- Keep profiles, favorites, recent destinations, and destination text on-device.
- Make route membership geometrically correct and driving distance truthful.
- Isolate changing national/operator data sources from UI and search policy.
- Degrade partial provider/live/POI failures without fabricating data.
- Scale the spatial search to European datasets without microservices.

## Context

```text
Driver
  | configures profiles                         Apple entitlement service
  v                                                         |
iPhone SwiftUI app <---- local store ----> CarPlay adapter <-+
  |                           |                |
  | destination search       | ride draft     | CPList / CPPOI / CPInformation
  | route and directions     v                |
  +-----------------------> MapKit             +----> Apple Maps navigation
  |
  | POST /v1/charging-parks/search
  | route LineString + non-personal criteria; no saved profile
  v
Backend modular monolith
  | provider ingestion -> validation -> normalization -> dedup -> clustering
  | candidate search -> provider-health-aware response
  v
PostgreSQL + PostGIS <---- official NAP/operator/open-data providers
```

## Components and responsibilities

### NextStopCore (pure Swift package)

- Domain value types and central option catalog.
- Ride-scoped search draft copied from an optional profile.
- Three-valued availability filtering.
- Candidate enrichment orchestration, exact-distance filtering, sorting, and
  five-result cap.
- Error taxonomy independent of UIKit, SwiftUI, CarPlay, MapKit, and URLSession.

### iPhone application

- Minimal SwiftUI create/edit/delete profile UI.
- Destination search and favorites/recent management.
- Local SwiftData repository behind domain protocols.
- Location authorization onboarding on iPhone before a driving flow.
- German localization resources with localization keys in presentation code.

### MapKit infrastructure

- Resolves destination text/completions to `MKMapItem`.
- Calculates the canonical route from current location to destination.
- Exports the detailed route polyline as a validated GeoJSON LineString.
- Resolves actual automobile routes from current location to candidate parks.
- Resolves the selected fast-food chain near a park and verifies the result's
  geodesic distance is no more than 500 m.
- Opens Apple Maps with driving directions. A matched restaurant is inserted as a
  waypoint before the original ride destination; without a food match, the park
  remains the navigation destination.

### CarPlay adapter

- Owns `CPTemplateApplicationSceneDelegate` and template navigation only.
- Maps application presentation models to `CPListTemplate`,
  `CPPointOfInterestTemplate`, alerts, and `CPInformationTemplate`.
- Contains no provider, geometry, filter, ranking, or persistence logic.
- Is absent/disabled in configurations that lack the managed entitlement while the
  iPhone app and core remain buildable and testable.

### App Intents adapter

- Exposes a small “Find charging parks” action with destination and optional saved
  profile/search parameters.
- Lets Siri perform system speech recognition; the app does not record or process
  free audio.
- Delegates destination resolution and search to the same application use case as
  CarPlay.

### Backend modular monolith

Modules are source folders and dependency boundaries, not separately deployed
services:

- `providers`: source-specific clients, payload validation, and mappings.
- `ingestion`: schedules, rate limits, retries, raw-record idempotency.
- `normalization`: provider-independent operators, locations, EVSEs, connectors,
  availability, and provenance.
- `identity`: exact identifiers and conservative cross-source deduplication.
- `parks`: deterministic 200 m clustering and aggregated search projection.
- `search`: PostGIS corridor and preliminary-filter query.
- `api`: authentication/rate limiting, OpenAPI DTO validation, and redaction.
- `operations`: provider health, freshness, quarantine, and metrics.

### PostgreSQL + PostGIS

- Raw source payload metadata and content hash for replay/audit.
- Normalized relational charging model with field-level observations.
- Current authoritative projection and conflict records.
- GiST-indexed `geography(Point, 4326)` park locations.
- Search projection for total EVSEs, known-free state, maximum power, operators,
  quality, freshness, and live coverage.

No Redis, message broker, or separate search cluster is required in the MVP.
Ingestion uses durable database jobs/advisory locks and can be extracted only after
measured need.

## Dependency direction

```text
Presentation (SwiftUI / CarPlay / App Intents / HTTP)
                       |
                       v
Application use cases and ports
                       |
                       v
Domain values and policies
                       ^
                       |
Infrastructure adapters (MapKit / SwiftData / HTTP / PostGIS / providers)
```

Infrastructure implements inward-facing protocols. Domain and application modules
never import provider DTOs or UI frameworks.

## Search ownership

The backend returns a paginated, stable candidate snapshot after static/live
charging filters and exact route-corridor geometry. The iOS application performs
the operations that only MapKit can truthfully provide:

1. exact automobile distance from the current location to each candidate;
2. final distance-range filter;
3. selected-chain lookup and 500 m check;
4. final distance-only sort and five-result cap.

This split avoids a second router that could disagree with Apple Maps. It also
means an API field named `actualDrivingDistance` must never be populated by route
progress or straight-line distance.

## Stable ride snapshot

A search creates a local `RideSearchSnapshot` containing criteria, route identity,
candidate snapshot token, exact-distance results, and food matches. The displayed
five are not re-ranked by background availability changes. Manual refresh creates
a new snapshot after explicit confirmation.

## Failure boundaries

- Provider failure: use non-expired cached data and report degraded source health.
- Partial live data: retain the park with explicit coverage/unknown state.
- POI lookup failure: distinguish “provider unavailable” from “no matching POI.”
  A transient provider failure must not be misrepresented as a confirmed no-match.
- MapKit route failure: no search; offer retry/destination change.
- Backend failure: no stale local European corpus is assumed. Show a clear retry
  path and preserve the ride draft.
- Apple Maps launch failure: keep details visible and report that navigation could
  not be opened.

## Performance budget (initial targets, to validate)

- Backend cached candidate query p95: under 500 ms.
- First useful CarPlay state after search: under 3 s on a healthy connection.
- Exact MapKit candidate routes: bounded concurrency of four, ride-local cache.
- Stable final result: aim under 8 s for typical filters; show template-native
  progress and allow cancellation.

These are engineering targets, not externally promised SLOs. Instrument aggregate
latency without retaining route geometry or persistent user identifiers.
