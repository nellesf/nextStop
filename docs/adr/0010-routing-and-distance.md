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

On iPhone, expose a 48-point Apple Maps button beside each charging operator in a
result. Resolve that operator's power-filtered charging locations against nearby
Apple EV-charging places only after the user taps the button. Require a
conservative operator plus coordinate/address match, cache the ride-local result,
and open the native Apple place through its stable Place ID. If no unambiguous
Apple place exists, report that condition instead of opening a coordinate-only or
guessed place. Apple matching is presentation-only and cannot affect the search
result, EVSE count, route, ranking, or waypoint.

Keep navigation as a distinct result-card action so inspected charging places do
not become unintended route waypoints. Do not embed a second route map or hand a
group of caller-created pins to Apple Maps: those paths do not consistently expose
the native place details and live charging information available on Apple's own
place record.

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
