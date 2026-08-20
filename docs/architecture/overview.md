# System architecture

Status: Accepted on 2026-08-13; clustering/search identity and no-food
Apple-place matching amended on 2026-08-20.

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
- Candidate enrichment orchestration, exact-distance filtering, restaurant
  grouping, operator aggregation, sorting, and five-result cap.
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
- Resolves actual automobile routes from current location to each candidate's
  power-filtered navigation coordinate.
- Consumes the backend's validated restaurant match; it does not perform local POI
  discovery for filtering. On iPhone, tapping an operator or restaurant Maps button
  performs a bounded Apple lookup for only that already-selected item; this lookup
  never changes inclusion, counts, ranking, or the CarPlay navigation waypoint.
- When a food chain is selected, groups qualifying fine-park candidates by the
  stable backend restaurant POI ID. One restaurant becomes one result, operator
  EVSE counts are summed across its member fine parks, and each exact operator name
  receives one Apple Maps button. Without food, the backend has already emitted
  one campus-wide candidate per stable `ChargingCampusID`.
- Opens a conservatively matched native Apple charger or restaurant by stable Place
  ID. If no unambiguous match exists, it leaves the backend result unchanged and
  reports that Apple details are unavailable.
- Requires a matching operator name and Apple's `.evCharger` category for every
  native charger match. The operator-specific 60 m direct rule and 300 m
  exact-address rule remain primary. Only without food, one unique stable Apple
  place may additionally use the selected bounded campus as spatial evidence when
  it has the same postal code or normalized city and lies within 60 m of any
  qualifying campus location. Food-mode operator scopes remain unchanged.
- For CarPlay, opens Apple Maps with driving directions. A matched restaurant is
  inserted as a waypoint before the original ride destination; without a food
  match, the campus navigation coordinate remains the navigation destination.

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
- `parks`: deterministic complete-link fine parks with <=200 m diameter.
- `campuses`: deterministic no-food aggregates over indivisible fine parks using
  <=200 m cross-edges and an inclusive <=500 m union diameter.
- `projections`: power-specific fine-park and campus search summaries with
  candidate-wide EVSE deduplication and aggregation.
- `search`: PostGIS corridor and preliminary-filter query.
- `api`: authentication/rate limiting, OpenAPI DTO validation, and redaction.
- `operations`: provider health, freshness, quarantine, and metrics.

### PostgreSQL + PostGIS

- Raw source payload metadata and content hash for replay/audit.
- Normalized relational charging model with field-level observations.
- Current authoritative projection and conflict records.
- GiST-indexed `geography(Point, 4326)` fine-park and campus navigation locations.
- Separately versioned OSM restaurant POIs plus cached broad fine-park/POI pairs
  built from each fine park's base navigation coordinate.
- Fine-park and campus search projections for each supported minimum-power option
  the entity satisfies. Each row contains the entity-wide qualifying deduplicated
  EVSE count, exact-name operators, static availability, lookup evidence, and
  power-filtered display/navigation coordinates. Normalized fine-park/location and
  campus/fine-park memberships replace array scans on the search path.
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

The backend first selects the candidate entity from `foodChain`: one
`ChargingCampus` row per stable campus ID when it is null, or one complete-link
`ChargingPark` row when it is non-null. It then selects the request's power
projection and applies entity-wide minimum EVSE count, exact route corridor,
origin lower bound, and, for fine parks, the exact restaurant predicate before
stable pagination. Live availability is added only to the selected page and
remains informational. The iOS application performs the operations that only
MapKit can truthfully provide:

1. exact automobile distance from the current location to each candidate's same
   power-filtered navigation coordinate;
2. final distance-range filter;
3. when food is selected, grouping by stable restaurant POI ID and aggregation of
   qualifying EVSE counts by exact operator name;
4. final distance-only sort and five-result cap, using the nearest member fine
   park's actual driving distance for a restaurant group and the single campus
   candidate distance without food.

After the user taps an operator or restaurant Maps button, Apple-place matching is
presentation enrichment only. It combines the selected item's authority/OSM
coordinate, normalized address when available, and name with a bounded MapKit
search. The ride-local match is cached and the native place is opened through its
Apple Place ID. Apple Place IDs identify only Apple records and are never treated
as cross-source identities. For a restaurant result, one operator lookup considers
all of that operator's authority locations in the group but opens only one
conservatively matched native Apple POI. For a no-food campus, an operator-matched
Apple `.evCharger` that fails the primary operator-coordinate/address rules may use
another qualifying location in that same campus only as <=60 m spatial evidence.
The Apple place must share the requested operator's postal code or normalized city
and be the single qualifying stable Place ID across the bounded lookup. This does
not alter operator identity, campus membership, search results, or food behavior.

Charging-place lookup first performs the bounded category-only `.evCharger`
search. Food mode has no second charging search pass. Only for a no-food campus,
collect campus-fallback evidence across the category-only pass. A primary
operator-specific match may return immediately; one unambiguous campus match is
accepted after that pass. Otherwise a second bounded natural-language search for
the requested operator uses the same `.evCharger` filter and campus scope.
Ambiguous category campus candidates remain evidence in that second-pass
decision. Both passes use the same identity, locality, distance, and ambiguity
rules; no broad or unfiltered search is allowed.

The backend's restaurant predicate uses an OSM snapshot pinned into the same
signed pagination token. A 700 m materialized pair cache reduces work and retains
a fine-park/POI pair when the POI is within that radius of the fine park's base
navigation coordinate. The candidate query still applies exact geography
`ST_DWithin(..., 500)` against the fine-park navigation coordinate derived after
the request's power filter; the cached distance is never a matching decision. The
complete-link 200 m park diameter guarantees prefilter completeness by the
triangle inequality. No-food campuses do not participate in this cache.

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
- Partial live data: retain the candidate with explicit coverage/unknown state.
- POI projection failure: retain the previous active projection. If none exists,
  return a retryable error instead of misrepresenting it as a confirmed no-match.
- MapKit route failure: no search; offer retry/destination change.
- Backend failure: no stale local European corpus is assumed. Show a clear retry
  path and preserve the ride draft.
- Apple-place match failure: keep the authority/OSM-backed result visible and
  explain that no unambiguous native Apple place was found for that item.
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
