# ADR 0010: Routing and actual distance strategy

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-16
- Amended: 2026-08-19
- Amended: 2026-08-20 (candidate identity and group-bounded Apple-place matching)

## Context

The app must route with MapKit, test exact distance to that route, and display
actual road distance to the selected charging result including the exit. It must
not navigate itself.

A 2026-08-20 Wertheim regression showed why operator-only coordinates and exact
addresses are insufficient evidence for native Apple-place enrichment inside a
bounded multi-operator campus. Apple's Tesla Supercharger place was 211.5 m from
the Tesla authority point and used a different street address. At the active
100/150 kW power filter, however, it was 57.2 m from another power-qualified group
location. In the live restaurant result, it was 257.2 m from the exact grouping
McDonald's. The systems still agreed on the operator and locality. Rejecting that
intended Apple place was a false negative; widening the rule outside the currently
displayed result group would be ambiguous. Food-mode evidence must remain inside
the exact restaurant-POI group, and the Apple charger itself must pass an
independent <=500 m geodesic check to that exact restaurant POI.

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
the user taps its button. Every charging-place candidate must have Apple's
`.evCharger` category and a normalized name that matches the requested operator.
The existing operator-specific rules remain unchanged: accept a matching Apple
place within 60 m of one of that operator's qualifying authority locations without
address evidence, or within 300 m only when street, house number, and postal code
or city match that operator location.

Within either one currently displayed no-food `ChargingCampus` or one concrete
restaurant-centered group, a third conservative rule may recover a local
address/coordinate discrepancy. When neither operator-specific rule accepts a
place, accept an Apple charger only when all of the following hold:

1. its operator name and `.evCharger` category satisfy the requirements above;
2. its address shares the postal code or normalized city with the requested
   operator's qualifying authority evidence;
3. its coordinate is within 60 m of any qualifying location in the selected
   no-food campus, or any power-qualified location in a member fine park assigned
   to the exact restaurant POI of the current group, regardless of that
   corroborating location's operator;
4. in food mode only, its coordinate is within 500 m geodesic distance of the
   exact restaurant POI that defines the displayed group; and
5. after collecting the bounded searches and deduplicating by stable Apple Place
   ID, exactly one Apple place satisfies these conditions.

The other location is spatial corroboration only; it never supplies or changes the
requested operator identity. In a restaurant result, another operator's location
may corroborate when it is power-qualified and belongs to any member fine park of
the exact restaurant-POI group. Neither mode may use a location from another
displayed result. No-food matching has no restaurant-distance requirement.

Do not turn every raw evidence location into a MapKit request center. Build the
bounded search centers from the result's representative navigation coordinate and
the requested operator's authority lookup coordinates. For a restaurant group,
also include the deterministic navigation coordinate of every member fine park
assigned to the exact restaurant POI. Without food, the representative coordinate
is the selected campus navigation coordinate and no member-fine-park centers are
added. Deduplicate all centers with a 75 m minimum separation. Power-qualified raw
locations remain match evidence but do not create additional requests.

In both modes, treat the category-only `.evCharger` searches across those centers
as one pass for fallback evidence. A primary operator-specific match retains the
existing best-match behavior and may return immediately. Otherwise, collect
fallback candidates across the full pass and return when they identify one
unambiguous stable Apple place. If any center request fails, the pass is incomplete
and cannot establish a uniqueness-dependent fallback; a primary operator-specific
match may still return safely. If the complete pass yields no secure match,
including when its qualifying candidates are ambiguous, perform a second bounded
natural-language search for the requested operator with the same `.evCharger`
filter and the same centers and evidence scope. Retain the category-pass
candidates as evidence when evaluating the second pass. Do not issue a broad or
unfiltered fallback search. Apply the same operator, category, locality, distance,
and ambiguity rules to both passes, and deduplicate their combined evidence by
stable Apple Place ID. The combined fallback requires both passes to have completed
without a center failure.

Cache the successful native match ride-locally under the resolved operator and
lookup scope; a group-fallback cache key also includes the stable campus or
restaurant-result identity. If no single unambiguous stable Apple place exists,
report that condition instead of opening a coordinate-only or guessed place.
Apple matching is presentation-only and cannot affect the search result, EVSE
count, route, ranking, restaurant predicate, or CarPlay waypoint.

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

The group-bounded fallback can correct a presentation-only Apple catalog mismatch
without relaxing campus or restaurant-result identity or treating a nearby
operator as the requested operator. Regression coverage must include the Wertheim
campus and food distances above, rejection outside the currently displayed group,
rejection when the Apple charger exceeds 500 m geodesic distance to the exact
grouping restaurant POI, rejection on missing category/locality, ambiguous Apple
Place IDs, and an omitted category-only result recovered by the filtered operator
search in each group type.
