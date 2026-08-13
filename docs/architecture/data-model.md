# Normalized domain data model

Status: Accepted on 2026-08-13.

All IDs below are internal opaque UUIDs unless an explicit source/native identifier
is named. Quantities use integer meters and kilowatts. Instants are UTC.

## Charging entities

### `ChargingPark`

An aggregate search/display entity, not an operator.

- `id`
- `name`
- `centroid`
- `memberLocationIDs`
- `operators: [Operator]`
- `chargingPointCount` (deduplicated EVSE count)
- `availability: ParkAvailability`
- `maximumPowerKW`
- `dataQuality`
- `sourceReferences`
- `lastStaticObservationAt`
- `lastLiveObservationAt?`
- `foodPOIs: [FoodPOI]` (normally added on-device in MVP)

The display centroid never replaces member coordinates in deduplication or source
records. A navigation coordinate should be the best access/member location, not a
mathematical centroid that could fall across a road barrier.

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

An expired value is treated as unknown for search, while the last observation may
remain visible only with an explicit stale label.

### `ParkAvailability`

- `knownAvailableCount`
- `knownUnavailableCount`
- `unknownCount`
- `totalCount`
- `complete`: all deduplicated EVSEs have fresh usable live state
- `lastLiveObservationAt?`

#### Minimum-availability truth table

For requested minimum `m`:

- `m == nil` (German UI “egal”): pass.
- `knownAvailableCount >= m`: pass.
- `knownAvailableCount + unknownCount < m`: fail (even every unknown EVSE could not
  satisfy the request).
- Otherwise: pass with `uncertain` evidence, because unknown EVSEs may satisfy the
  request.

Thus missing or partial live data never excludes a park merely because it is
unknown, but known facts can still prove a requirement impossible. UI copy must
distinguish complete counts from partial/unknown availability.

### `PowerCapability`

- `maximumPowerKW`
- optional future `chargingPointCountAtOrAbovePower`
- provenance and observation time

MVP passes when at least one deduplicated EVSE supports the requested minimum
power. It does not require all EVSEs, or a minimum number of them, to support it.

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
- `minimumAvailablePoints?`
- `minimumPowerKW`
- `foodChain?`
- fixed `maximumDistanceFromRouteMeters = 5_000`
- fixed `maximumFoodDistanceMeters = 500`
- fixed `resultLimit = 5`

### `RouteSearchCandidate`

- park summary
- `distanceFromRouteMeters`
- `routeProgressMeters` explicitly approximate/preliminary
- `straightLineLowerBoundMeters`
- `snapshotToken`, `candidateCursor?`
- no backend-claimed actual driving distance

### `RouteSearchResult`

- candidate/park
- `actualDrivingDistanceMeters` from MapKit
- `distanceFromRouteMeters`
- matching `FoodPOI?`
- `availabilityEvidence`
- snapshot metadata

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
- minimum free: any, 1, 2, 4, 6, 8, 10;
- power: 11, 22, 50, 100, 150, 200, 250, 300, 350, 400 kW;
- food: any, McDonald's, Burger King, KFC, Subway;
- corridor 5,000 m, park grouping 200 m, food 500 m, results 5;
- recent-destination limit: 20.

Approved non-profile defaults are 50–100 km, at least 4 EVSEs, availability “any”,
at least 100 kW, and food “any”. They are visible on the ride summary and are never
hidden or automatically adjusted.

Each option has a stable machine ID and localization key. API DTOs transmit stable
values, never localized labels.
