# ADR 0010: Routing and actual distance strategy

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-16
- Amended: 2026-08-19
- Amended: 2026-08-20

## Context

The app must route with MapKit, test exact distance to that route, and display
actual road distance to the selected charging result including the exit. It must
not navigate itself.

## Decision

Create the destination route in MapKit, send its LineString to PostGIS for exact
5 km candidate filtering, then request MapKit automobile directions from origin to
each paginated candidate's power-filtered navigation coordinate. Filter/rank/cap
on-device using those exact distances. ADR 0006 defines the candidate identity
before filtering and pagination: a `ChargingCampus` when `foodChain` is null and a
complete-link `ChargingPark` when it is non-null.

When CarPlay launches a result that contains the selected restaurant match, use
Apple's unified Maps URL to keep the original destination and insert the restaurant
as an intermediate waypoint. Without a food match, hand the chosen campus
navigation `MKMapItem` to Apple Maps.

On iPhone, expose a 48-point Apple Maps button beside each charging operator and
the matched restaurant. When food is selected, use the stable backend restaurant
POI ID as the final result identity: all qualifying fine parks for that restaurant
form one result, exact operator names are combined, and qualifying EVSE counts are
summed. The closest member fine park by actual MapKit driving distance represents
the group for ranking and displayed distance. Candidate pagination within the
selected maximum distance is scanned instead of using the five-result shortcut,
because a later fine park can still contribute to an already selected restaurant.
Once the lower bound proves the top five restaurant IDs, MapKit enrichment is
skipped for later fine parks belonging only to other restaurants.

Without food, the stable `ChargingCampusID` is the result identity and the backend
returns one already aggregated candidate per campus. Its qualifying EVSE and exact
operator totals are campus-wide. The ordinary lower-bound stopping rule is valid
because no later candidate can contribute to an already emitted campus.

Resolve the selected authority/OSM location against nearby Apple places only after
the user taps its button. Require a conservative name plus
coordinate/address match, cache the ride-local result, and open the native Apple
place through its stable Place ID. A matching operator is accepted within 60 m
without address evidence, or within 300 m only when street, house number, and
postal code or city match. The latter supports large charging campuses with one
central Apple place. One restaurant result exposes one button per exact operator
name. In food mode its lookup scope contains all authority locations for that
operator across the restaurant group's member fine parks; without food it contains
the operator's qualifying locations across the selected campus. The resolver opens
only the best unambiguous native Apple POI. Search each distinct coordinate group
in that bounded scope because a MapKit POI response is not treated as an exhaustive
radius result, then cache a
successful native place by normalized operator and address for the remainder of
the ride. If no unambiguous Apple place exists, report that condition instead of
opening a coordinate-only or guessed place. Apple matching is
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
needed for latency. The backend API returns candidate identities, their single
power-filtered navigation coordinate, and lower bounds, not final driving-distance
claims. Corridor membership, the origin lower bound, and MapKit enrichment must
all address that same coordinate. The multistop handoff requires iOS 18.4 or later;
iOS 18.0–18.3 falls back to automobile directions to the matched restaurant.
