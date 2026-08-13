# ADR 0010: Routing and actual distance strategy

- Status: Accepted
- Date: 2026-08-13

## Context

The app must route with MapKit, test exact distance to that route, and display
actual road distance to a park including the exit. It must not navigate itself.

## Decision

Create the destination route in MapKit, send its LineString to PostGIS for exact
5 km candidate filtering, then request MapKit automobile directions from origin to
each paginated candidate. Filter/rank/cap on-device using those exact distances.
Hand the chosen `MKMapItem` to Apple Maps.

## Alternatives

- Server-side OSM router: scalable matrices but can disagree with MapKit/Apple Maps
  and adds a major operational component.
- Route progress plus off-route straight line: fast but not actual driving distance
  and can ignore ramps/barriers.

## Consequences

MapKit is canonical and truthful, while candidate batching/concurrency/caching are
needed for latency. The backend API returns candidates and lower bounds, not final
driving-distance claims.
