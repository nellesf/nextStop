# System architecture

Status: Accepted on 2026-08-13; clustering/search identity and Apple-place
matching amended through 2026-08-21.

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
  | App Attest key/assertion
  +-----------------------> authentication exchange
  |
  | POST /v1/charging-parks/search + short-lived access token
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
- App Attest key lifecycle on supported physical devices, with the key identifier
  and transient retry challenge in a device-only non-synchronizing Keychain item,
  one injected coordinator shared by iPhone and CarPlay, and access tokens in memory.
- A compile-time Debug-only loopback token provider when App Attest is unsupported.
  A Mac helper authenticates through Google Cloud IAP and keeps the short-lived
  token out of project files; distributed builds fail closed instead.

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
  exact-address rule remain primary. In one no-food campus, a unique stable Apple
  place may additionally use any qualifying campus location as spatial evidence.
  In one concrete restaurant result, it may use any power-qualified location in a
  member fine park assigned to that exact restaurant POI. The place must have the
  same postal code or normalized city, lie within 60 m of that evidence, and, in
  food mode, lie within 500 m geodesic distance of the exact grouping restaurant
  POI. Another operator's location is evidence only and never changes the
  requested operator identity.
- Recognizes one directed normalized Apple-catalog mapping: the exact Apple place
  name `AMAG Energy Charging` may identify the exact requested backend operator
  `Autosense`. Only this direction may use at most 100 m to the requested
  operator's own qualifying authority lookup. The reverse direction, equal names,
  plain `AMAG`, and other AMAG businesses receive no exception. The candidate
  still requires `.evCharger`, matching locality, a stable Place ID, and the same
  single ID from fully successful category-only and filtered natural-language
  passes. Food mode still requires <=500 m to the exact grouping restaurant. This
  does not widen the ordinary 60 m/300 m rules or the Wertheim group fallback.
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
- `api`: App Attest challenge/verification, short-lived token authentication,
  rate limiting, OpenAPI DTO validation, and redaction.
- `operations`: provider health, freshness, quarantine, and metrics.

The one backend artifact has separate execution roles. Candidate search reads the
search projection through a read-only database login. The API uses a separate
authentication pool whose login may modify only installation-key and single-use
challenge records. A listenerless worker performs provider ingestion and
transactional projection publication with a DML-only login. A release-scoped
migrator applies DDL with the database owner before either long-running process
starts. These are privilege and failure boundaries inside the modular monolith,
not microservices.

Candidate search is authenticated and has explicit resource budgets before it
reaches PostGIS: 512 KiB, 8,000 route coordinates, a supported-Europe envelope,
250 km per segment, 2,500 km total, and four concurrent searches per API process.
The read-only API database role adds a 15-second statement deadline. Geometry over
a boundary is rejected rather than simplified, preserving the exact corridor
contract.

### PostgreSQL + PostGIS

- Raw source payload metadata and content hash for replay/audit.
- Normalized relational charging model with field-level observations.
- Current authoritative projection and conflict records.
- Hashed App Attest key identifiers, verified public keys/receipts, assertion
  counters, and short-lived single-use challenges under separate grants; no
  profile, destination, or route association.
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
all of that operator's authority locations in the group for the primary rules.
Fallback evidence may come from any power-qualified location in a member fine park
assigned to the exact grouping restaurant POI, although another operator's
location provides only <=60 m spatial evidence. The Apple charger itself must also
be within 500 m geodesic distance of that restaurant POI. In a no-food campus, any
qualifying campus location may provide evidence and no restaurant-distance
condition applies. The Apple place must share the requested operator's postal code
or normalized city, have a stable Place ID, and be the one ID resolved by the
complete bounded-pass policy below. This does not alter operator identity, campus
or restaurant-result membership, search results, or grouping.

Charging-place lookup uses bounded centers with a 75 m minimum separation, not one
request per raw evidence location. Both modes use the result's representative
navigation coordinate and the requested operator's authority lookup coordinates.
A restaurant group additionally uses each member fine park's deterministic
navigation coordinate; no-food uses only the campus navigation coordinate plus
the operator lookups. Power-qualified raw locations remain match evidence.

The category-only `.evCharger` searches across those centers form one pass. A
primary operator-specific match may return immediately; one unambiguous fallback
match is accepted after the complete category pass. A center failure makes that
pass incomplete and disables its uniqueness-dependent fallback while leaving a
primary operator-specific match eligible. If that pass has no secure
match, a second bounded natural-language search for the requested operator uses
the same centers, `.evCharger` filter, and evidence scope. Ambiguous category
candidates remain separate as corroborating evidence in that second-pass decision.
Both passes use the same
identity, locality, distance, and ambiguity rules, including the food-only
restaurant-distance condition; no broad, unfiltered, or out-of-scope search is
allowed. If the category set is empty, the natural-language set must identify one
stable place. If the category set is ambiguous, exactly one stable Place ID must
occur in both fully validated sets. The second-pass fallback requires every center
in both passes to succeed.

The directed `AMAG Energy Charging` Apple name -> requested `Autosense` backend
operator mapping has a stricter cross-pass outcome despite its separate 100 m
authority-only distance: every center in both passes must succeed and both passes
must contain the same one stable Place ID. It cannot use another operator's
coordinate as 100 m evidence, and the exception does not apply in reverse or to
equal names. The ordinary 60 m direct, 300 m exact-address, and 60 m result-group
rules remain unchanged.

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
- App Attest unavailable or rejected: a distributed build fails closed with a
  distinct authentication error. A Debug Simulator may use only its loopback Mac
  broker after the developer authenticates through Google Cloud IAP. Its remote
  one-shot minter receives only the signing key and has no container network. One
  `401` triggers one bounded token refresh and search retry.
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
latency without retaining route geometry or logging the installation-scoped App
Attest credential, key hash, or access token.
