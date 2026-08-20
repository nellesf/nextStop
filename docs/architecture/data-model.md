# Normalized domain data model

Status: Accepted on 2026-08-13.
Amended on 2026-08-18 for request-scoped power filtering and OSM food POIs.
Amended on 2026-08-20 for dual fine-park/no-food-campus identity.

All IDs below are internal opaque UUIDs unless an explicit source/native identifier
is named. Quantities use integer meters and kilowatts. Instants are UTC.

## Charging entities

### `ChargingPark`

A fine-grained, source-independent physical aggregate, not an operator. Its member
locations are produced by deterministic complete-link clustering and have a
maximum pairwise geodesic distance of 200 m. It is an indivisible campus seed and
the backend search candidate only when `foodChain` is non-null.

- `id`
- `name`
- `centroid`
- `memberLocationIDs`
- `operators: [Operator]`
- `operatorChargingPointCounts` (deduplicated EVSE count for each operator; sums
  to `chargingPointCount`)
- `chargingPointCount` (deduplicated EVSE count)
- `availability: ParkAvailability`
- `maximumPowerKW`
- `dataQuality`
- `sourceReferences`
- `lastStaticObservationAt`
- `lastLiveObservationAt?`
- `foodPOIs: [FoodPOI]` (selected from the pinned backend POI projection)

The display centroid never replaces member coordinates in deduplication or source
records. A navigation coordinate is a qualifying best access/member location, not
a mathematical centroid that could fall across a road barrier.

### `ChargingCampus`

A derived, no-food search aggregate over one or more complete fine parks.

- `id` (stable `charging-campus-v1` hash of sorted `memberParkIDs`)
- `memberParkIDs`
- all underlying `memberLocationIDs`
- `name`, display coordinate, navigation coordinate
- campus-wide `operators`, `operatorChargingPointCounts`, `chargingPointCount`
- `availability`, `maximumPowerKW`, `dataQuality`, source/observation metadata

Fine parks are indivisible seeds. Deterministically ordered <=200 m
member-location cross-edges may join seed groups only when the union's maximum
member-to-member diameter remains <=500 m. Campus membership is static for a
charging projection and independent of route, power, availability, and food.
Campus IDs and fine-park IDs are distinct identities.

### `ChargingLocation`

A source-independent physical access location/station grouping.

- `id`, `name?`, `coordinate`, `address?`
- `operatorIDs`, `chargingPointIDs`
- `accessCoordinate?`
- `sourceReferences`, observation/quality metadata

### `ChargingPoint`

One EVSE: a position able to charge at most one vehicle at a time, regardless of
how many connectors it exposes.

- `id`
- `canonicalEVSEIdentity?`
- `locationID`, `operatorID?`
- `connectors: [ChargingConnector]`
- `availability: Availability`
- `maximumPowerKW`
- `sourceReferences`
- `identityDecision` (`exact`, `highConfidence`, `unresolved`)

### `ChargingConnector`

- `id`, `chargingPointID`
- `sourceConnectorID?`
- `standard?`, `currentType?`
- `maximumPowerKW?`

Connector type is normalized for data integrity/future use but is deliberately not
an MVP filter.

### `Operator`

- `id`, `canonicalName`
- `externalIDs`, `aliases`
- `sourceReferences`

### `Availability`

- `state`: `available | occupied | outOfService | reserved | unknown`
- `observedAt?`, `receivedAt`
- `isLive`
- `sourceReference`
- `freshness`: `fresh | stale | expired | unknown`

An expired value is treated as unknown for presentation, while the last observation
may remain visible only with an explicit stale label.

### `ParkAvailability`

- `knownAvailableCount`
- `knownUnavailableCount`
- `unknownCount`
- `totalCount`
- `complete`: all deduplicated EVSEs have fresh usable live state
- `lastLiveObservationAt?`

Availability is informational only. Neither complete nor partial live state can
include or exclude a candidate. UI copy must distinguish complete counts from
partial/unknown availability.

### `PowerCapability`

- `maximumPowerKW`
- request-scoped `chargingPointCountAtOrAbovePower`
- provenance and observation time

For each supported projection, discard EVSEs below `minimumPowerKW` before building
the candidate summary. Per-operator counts, `chargingPointCount`, availability,
the minimum-point filter, display/navigation coordinates, and the candidate name
are all derived from the remaining deduplicated EVSEs. An operator with no
qualifying EVSE is not part of that candidate. If only two of an operator's four
EVSEs qualify, its request-scoped count is two.

For no-food campus rows, deduplication and aggregation run across every underlying
location in the campus; summing pre-aggregated fine-park totals is invalid. For
food rows, the same derivation runs within each fine park. The backend selects
which projection is the candidate unit from `foodChain` before count, corridor,
lower-bound, and pagination filtering.

The static projection build materializes these summaries once per centrally
supported `minimumPowerKW` option. The search selects one row instead of joining,
deduplicating, and aggregating every EVSE for every request. Fine-park and campus
membership are stored as normalized relational rows for efficient joins. Fresh
live observations remain separate and are merged only for the selected result
page, preserving the rule that availability is informational.

### `DataSource` / `SourceReference`

- source ID/name/type (`authority`, `operator`, `openData`, `community`)
- provider record ID and canonical URL
- license/attribution identifier
- observed/fetched timestamps
- payload content hash
- quality tier and confidence

## POI entities

### `FoodPOI`

- `id` (provider-scoped)
- `chain: FoodChain`
- `name`, `coordinate`
- `distanceFromParkMeters`
- `openingStatus: open | closed | unknown`
- `openingStatusObservedAt?`
- `sourceReference`

Distance is computed independently from the charging source and must be <=500 m.
Unknown opening status does not affect matching.

OSM POIs live in a separate versioned projection with OSM object type/ID, match
method, source URL, observation/fetch timestamps, and quarantine records. A
derived fine-park/POI relation caches one pair when the POI lies within 700 m of
the fine park's base navigation coordinate. This is only a completeness prefilter.
Exact request inclusion always rechecks 500 m against the power-filtered fine-park
navigation coordinate. The fine park's <=200 m diameter makes that broad cache
complete by the triangle inequality. No-food campuses never enter this relation.

## Search entities

### `RouteSearchRequest`

- `origin` (sent only as the first route coordinate, not stored)
- `route: GeoJSON LineString`
- `routeFingerprint` (local/cache only where possible)
- `criteria: RideCriteria`
- `candidateCursor?`

### `RideCriteria`

- `distanceRange: DistanceRange`
- `minimumChargingPoints`
- `minimumPowerKW`
- `foodChain?`
- fixed `maximumDistanceFromRouteMeters = 5_000`
- fixed `maximumFoodDistanceMeters = 500`
- fixed `resultLimit = 5`

### `RouteSearchCandidate`

- candidate summary: one `ChargingCampus` when `foodChain` is null, otherwise one
  complete-link `ChargingPark`
- `id`: the selected entity's stable ID (campus v1 ID or fine-park ID)
- `distanceFromRouteMeters`
- `routeProgressMeters` explicitly approximate/preliminary
- `straightLineLowerBoundMeters`
- `snapshotToken`, `candidateCursor?`
- no backend-claimed actual driving distance
- matching `FoodPOI?` only when a chain was requested
- data attributions used by the client

### `RouteSearchResult`

- primary candidate (shortest actual driving distance in the result)
- related fine-park candidates sharing the same stable restaurant POI ID when food
  is selected; empty for an ungrouped campus result
- `actualDrivingDistanceMeters` from MapKit
- `distanceFromRouteMeters`
- matching `FoodPOI?`
- summed qualifying EVSE count and exact-name operator counts across all member
  candidates
- deduplicated charging-location lookup evidence across all member candidates
- `availabilityEvidence`
- snapshot metadata

With a food criterion, `RouteSearchResult` is restaurant-centric: one stable
restaurant POI produces at most one result and one Apple POI action per exact
charging operator name. Its rank and displayed driving distance remain the actual
MapKit distance to the closest qualifying member fine park, not a straight-line or
restaurant distance. Without a food criterion, the result identity is the stable
`ChargingCampusID`; all counts and operator lookup evidence already cover that
whole campus.

## User-local entities

### `UserProfile`

- `id`, `name`
- `destination: SavedDestination`
- all `RideCriteria` selections
- `createdAt`, `updatedAt`

### `SavedDestination`

- `displayName`
- coordinate
- Apple Maps place identifier when available
- optional display address

### `FavoriteDestination` and `RecentDestination`

Remain local. Recent destinations are de-duplicated by stable Apple place ID when
available, otherwise by normalized name plus nearby coordinate.

### `RideSearchDraft`

A mutable, in-memory/session-local copy created from a profile or explicit input.
It has no persistence path back to a profile. Saving a permanent change is a
separate iPhone-only use case.

## Central option catalog

The domain exposes ordered configuration rather than scattering literals:

- distance: 15–50, 50–100, 100–150 km;
- minimum EVSEs: 2, 4, 6, 8, 10, 12, 16, 20;
- power: 11, 22, 50, 100, 150, 200, 250, 300, 350, 400 kW;
- restaurant: not required (`foodChain = nil`), or required with McDonald's,
  Burger King, KFC, or Subway;
- corridor 5,000 m; fine-park complete-link 200 m; campus cross-edge 200 m and
  diameter cap 500 m; food distance 500 m; results 5;
- recent-destination limit: 20.

Approved non-profile defaults are 50–100 km, at least 4 EVSEs, at least 100 kW, and
no required nearby restaurant (`foodChain = nil`). They are visible on the ride
summary and are never hidden or automatically adjusted. Availability is displayed
only as information and is not a criterion.

Each option has a stable machine ID and localization key. API DTOs transmit stable
values, never localized labels.
