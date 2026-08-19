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
PostgreSQL + PostGIS <---- authority charging feeds + OSM extracts via Geofabrik
```

## Components and responsibilities

### NextStopCore (pure Swift package)

- Domain value types and central option catalog.
- Ride-scoped search draft copied from an optional profile.
- Availability validation and informational presentation without filtering.
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
- Consumes the backend's validated restaurant match; it does not perform local POI
  discovery for filtering. On the iPhone only, a selected result may perform a
  bounded Apple POI lookup to attach Place Cards to the already-selected charging
  locations and restaurant; this lookup never changes inclusion, counts, ranking,
  or the navigation waypoint.
- Renders a selective iPhone route preview with unrelated base-map POIs hidden.
  Unmatched backend/OSM locations remain explicit fallback pins rather than being
  silently omitted.
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
- Separately versioned OSM restaurant POIs plus cached broad park/POI pairs.
- Search projections for each supported minimum-power option a park satisfies.
  Each row contains the qualifying deduplicated EVSE count, derived operators,
  static availability, and power-filtered display/navigation coordinates. A
  normalized park/location membership table replaces array membership scans on
  the search path.
- Live availability remains a separate snapshot and is joined only for the
  selected result page; it cannot affect candidate inclusion or ordering.

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

The backend selects the precomputed row for the request's supported power value,
then returns a paginated, stable candidate snapshot after EVSE count, restaurant,
and exact route-corridor filtering. A straight-line origin bound safely removes
parks that cannot satisfy the requested maximum driving distance. Live
availability is added only to the selected page and remains informational. The
iOS application performs the operations that only MapKit can truthfully provide:

1. exact automobile distance from the current location to each candidate;
2. final distance-range filter;
3. final distance-only sort and five-result cap.

After selection, Apple-place matching is presentation enrichment only. It combines
the power-filtered authority location coordinate, normalized address, and operator
name with a bounded `MKLocalPointsOfInterestRequest`. Apple Place IDs identify only
Apple records and are never treated as cross-source identities.

The backend's restaurant predicate uses an OSM snapshot pinned into the same
signed pagination token. A 700 m materialized pair cache reduces work, but the
candidate query still applies exact geography `ST_DWithin(..., 500)` against the
navigation coordinate derived after the request's power filter.

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
- POI projection failure: retain the previous active projection. If none exists,
  return a retryable error instead of misrepresenting it as a confirmed no-match.
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
