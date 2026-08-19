# ADR 0010: Routing and actual distance strategy

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-16
- Amended: 2026-08-19

## Context

The app must route with MapKit, test exact distance to that route, and display
actual road distance to a park including the exit. It must not navigate itself.

## Decision

Create the destination route in MapKit, send its LineString to PostGIS for exact
5 km candidate filtering, then request MapKit automobile directions from origin to
each paginated candidate. Filter/rank/cap on-device using those exact distances.
When the result contains the selected restaurant match, use Apple's unified Maps
URL to keep the original destination and insert the restaurant as an intermediate
waypoint. Without a food match, hand the chosen park `MKMapItem` to Apple Maps.

Before handoff on iPhone, a selected result opens a non-navigating MapKit route
preview. Hide unrelated base-map POIs and resolve only the selected result's
power-filtered charging locations and restaurant against nearby Apple places.
Require a conservative operator plus coordinate/address match before attaching an
Apple Place Card. Preserve every unmatched authority/OSM location as a visibly
different fallback pin. Apple matching is presentation-only and cannot affect the
search result, EVSE count, route, ranking, or waypoint.

As a separate non-navigating action, hand every matched Apple charging place and
the matched restaurant for the selected result to Apple Maps together. Apple Maps
frames those supplied pins and provides its own place cards. Its unrelated
base-map POIs cannot be filtered by the calling app. Keep navigation as a distinct
action so candidate POIs never become unintended route waypoints.

## Alternatives

- Server-side OSM router: scalable matrices but can disagree with MapKit/Apple Maps
  and adds a major operational component.
- Route progress plus off-route straight line: fast but not actual driving distance
  and can ignore ramps/barriers.

## Consequences

MapKit is canonical and truthful, while candidate batching/concurrency/caching are
needed for latency. The backend API returns candidates and lower bounds, not final
driving-distance claims. The multistop handoff requires iOS 18.4 or later; iOS
18.0–18.3 falls back to automobile directions to the matched restaurant.
