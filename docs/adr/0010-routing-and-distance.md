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
When CarPlay launches a result that contains the selected restaurant match, use
Apple's unified Maps URL to keep the original destination and insert the restaurant
as an intermediate waypoint. Without a food match, hand the chosen park
`MKMapItem` to Apple Maps.

On iPhone, expose a 48-point Apple Maps button beside each charging operator and
the matched restaurant. Resolve the selected authority/OSM location against nearby
Apple places only after the user taps its button. Require a conservative name plus
coordinate/address match, cache the ride-local result, and open the native Apple
place through its stable Place ID. A matching operator is accepted within 60 m
without address evidence, or within 300 m only when street, house number, and
postal code or city match. The latter supports large charging campuses with one
central Apple place. When multiple visible backend parks contain the same operator
at the same complete address, their lookup coordinates form one ride-local Apple
lookup scope. This lets independently clustered parts of one campus resolve the
same native place without merging or altering either backend result. If no
unambiguous Apple place exists, report that condition
instead of opening a coordinate-only or guessed place. Apple matching is
presentation-only and cannot affect the search result, EVSE count, route, ranking,
restaurant predicate, or CarPlay waypoint.

The iPhone result card does not duplicate navigation; the user may start it from
the native Apple place card. CarPlay retains its template navigation action and
restaurant waypoint behavior. Do not embed a second route map or hand a group of
caller-created pins to Apple Maps: those paths do not consistently expose the
native place details and live charging information available on Apple's own place
record.

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
