# ADR 0010: Routing and actual distance strategy

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-16
- Amended: 2026-08-19
- Amended: 2026-08-20 (candidate identity, group-bounded Apple-place matching,
  and pass corroboration)
- Amended: 2026-08-21 (bounded known-catalog operator alias)
- Amended: 2026-09-07 (owner-approved CarPlay native-place handoff parity with iPhone)
- Amended: 2026-10-02 (owner-approved Apple-findable operators as a search predicate,
  with minimum EVSE count rechecked before final results)

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

A 2026-08-21 Zuchwil regression exposed a different Apple-catalog mismatch. The
authority operator `Autosense` appears in Apple Maps as `AMAG Energy Charging`.
Apple's charger was about 78 m from the requested operator's authority lookup and
about 51 m from the exact grouping McDonald's. It therefore missed the ordinary
60 m operator rule even though both bounded Apple searches returned the same
`.evCharger` record (observed Place ID `IE82B5E47B23E56E7`). A general distance
increase or a broad `AMAG` synonym would admit unrelated records, so this case
requires a narrower catalog-specific rule.

On 2026-09-07, the owner approved the CarPlay flow with separate operator and
restaurant actions. A restaurant-centered result must let the driver select a
specific charging operator, as on iPhone; its title alone must not determine the
Apple Maps destination. The owner also explicitly required the restaurant action
to behave like iPhone: open the selected native Apple place rather than
automatically start directions with the restaurant as an intermediate waypoint.

On 2026-10-02, the owner explicitly requested hiding results whose charging
operator cannot be matched unambiguously in Apple Maps, selected “only findable
operators count”, and confirmed that the selected minimum EVSE count must still
hold afterward. A valid authority record alone must no longer produce an operator
action that is already known to have no secure Apple-place match. This amendment
changes charger eligibility on-device; restaurant filtering remains OSM-based.

## Decision

Create the destination route in MapKit, send its LineString to PostGIS for exact
5 km candidate filtering, then request MapKit automobile directions from origin to
each paginated candidate's power-filtered navigation coordinate. Filter/rank/cap
on-device using those exact distances. ADR 0006 defines the candidate identity
before filtering and pagination: a `ChargingCampus` when `foodChain` is null and a
complete-link `ChargingPark` when it is non-null.

The primary CarPlay POI action opens a native operator list. Each exact operator
name appears once with its aggregated qualifying EVSE count for the selected
restaurant group or no-food campus. Selecting an operator uses the same bounded
Apple-place matching and ride-local cache as iPhone, then opens the native Apple
charger by stable Place ID through the existing place-opening interface. This
also replaces the former direct campus-coordinate handoff for no-food results.
Only operators confirmed during search appear in the list. Reuse their successful
match with the original lookup scope for handoff. If opening or re-resolving an
already displayed match fails, show a localized error and retain the current
snapshot; never substitute a campus coordinate or the restaurant for the selected
operator.
The restaurant action is present only for a matched restaurant. It resolves that
restaurant through the same bounded iPhone matcher and opens its native Apple
place by stable Place ID. An unavailable or ambiguous match is reported without
a coordinate-only fallback. Both CarPlay actions leave navigation initiation to
Apple Maps, as on iPhone. This replaces the former restaurant directions handoff
that kept the original ride destination and inserted the restaurant as a waypoint.

On iPhone, expose a 48-point Apple Maps button beside each charging operator and
the matched restaurant. When food is selected, use the stable backend restaurant
POI ID as the final result identity: all qualifying fine parks for that restaurant
form one result, exact operator names are combined, and qualifying EVSE counts are
summed. After Apple confirmation and the per-fine-park minimum-count recheck, the
closest surviving member fine park by actual MapKit driving distance represents
the group for ranking and displayed distance. Candidate pagination within the
selected maximum distance is scanned instead of using the five-result shortcut,
because a later fine park can still contribute to an already selected restaurant.
Collect every eligible fine park within the selected maximum distance before
matching a restaurant group's operators. The former early freezing of five
restaurant IDs and skipping other restaurants is removed: Apple confirmation can
remove operators or whole fine parks, so later restaurants must remain eligible
to move into the final five.

Without food, the stable `ChargingCampusID` is the result identity and the backend
returns one already aggregated candidate per campus. Its qualifying EVSE and exact
operator totals are campus-wide. The ordinary lower-bound stopping rule is valid
only after at least five campuses have passed Apple confirmation and the
minimum-count recheck, because no later candidate can contribute to an already
emitted campus.

Before final sorting and the five-result cap, resolve each exact charging
operator using the existing bounded Apple-place matcher, sequentially. Keep only
operators with one confirmed native charger and count only their power-qualified
EVSEs. Recheck the selected minimum EVSE count across each no-food campus or,
with food, independently within each fine park. Discard a campus or fine park
that falls below that minimum; several undersized fine parks cannot rescue one
another through restaurant aggregation. Rebuild restaurant results from the
remaining fine parks, aggregate only their confirmed operators, and choose the
nearest surviving fine park by actual driving distance. Later eligible candidates
fill places left by discarded results before the final five are selected.

Keep the complete original power-qualified campus or restaurant group as immutable
lookup evidence, including locations and fine parks later removed from displayed
counts. The original group contains candidates that passed the existing power,
minimum-count, corridor, actual-distance and OSM criteria before Apple confirmation.
Food mode must collect that entire group before any operator matching.
Use the same original representative, member navigation centers, operator lookups,
restaurant identity, and evidence scope for matching, search/ride-local caching,
and handoff. Do not reconstruct a narrower matching request from the pruned result.
The displayed restaurant representative may change after pruning; that changes its
displayed distance and rank, not the frozen lookup evidence. No cross-ride Apple
catalog cache or persistence is introduced.

A complete lookup that establishes no unambiguous charger removes that operator.
Network/search failure, throttling, or an incomplete required pass does not prove
absence: propagate a retryable search error rather than silently removing the
operator or publishing a partial result. Propagate cancellation and stop the
search without publishing an empty or partially filtered result. Existing safe
primary matches may still succeed under the bounded-pass rules below. Sequential
lookups and reuse of successful matches bound additional Apple request concurrency;
they do not promise a fixed search latency.

Restaurant Apple-place resolution still runs only when the user selects its Maps
action. Its success is not a search predicate. Every charging-place candidate must
have Apple's `.evCharger` category and a normalized name that matches the requested
operator.
The existing operator-specific rules remain unchanged: accept a matching Apple
place within 60 m of one of that operator's qualifying authority locations without
address evidence, or within 300 m only when street, house number, and postal code
or city match that operator location.

Maintain one explicit directed normalized Apple-catalog mapping: an Apple place
whose normalized name is exactly `AMAG Energy Charging` may identify the requested
backend operator whose normalized name is exactly `Autosense`. Only this direction
may use a separate inclusive 100 m limit, measured only to a qualifying authority
lookup of the requested operator. The reverse direction, equal operator/place
names, plain `AMAG`, and every other AMAG business receive no 100 m exception. The
candidate cannot borrow another operator's location or general result-group
evidence for that decision. It must still have Apple's `.evCharger` category,
share the requested operator's postal code or normalized city, and expose a stable
Apple Place ID. In addition, every bounded center request in both the category-only
and filtered natural-language passes must succeed, and both complete passes must
resolve the same single stable Place ID. In food mode, the charger must
independently remain within 500 m geodesic distance of the exact restaurant POI
that defines the displayed result.

This catalog-alias path does not change the ordinary 60 m direct rule, the 300 m
exact-address rule, or the 60 m result-group fallback. In particular, the Wertheim
group-corroboration rule and all of its boundaries remain unchanged.

Within either one original power-qualified no-food `ChargingCampus` or one complete
original restaurant-centered group, a third conservative rule may recover a local
address/coordinate discrepancy. When neither operator-specific rule accepts a
place, accept an Apple charger only when all of the following hold:

1. its operator name and `.evCharger` category satisfy the requirements above;
2. its address shares the postal code or normalized city with the requested
   operator's qualifying authority evidence;
3. its coordinate is within 60 m of any qualifying location in the selected
   no-food campus, or any power-qualified location in a member fine park assigned
   to the exact restaurant POI of the original group, regardless of that
   corroborating location's operator;
4. in food mode only, its coordinate is within 500 m geodesic distance of the
   exact restaurant POI that defines the displayed group; and
5. it has a stable Apple Place ID and the complete bounded-pass policy below
   resolves exactly one ID, either directly or through unique cross-pass
   corroboration.

The other location is spatial corroboration only; it never supplies or changes the
requested operator identity. In a restaurant result, another operator's location
may corroborate when it is power-qualified and belongs to any member fine park of
the exact restaurant-POI group. Neither mode may use a location from another
original result group. No-food matching has no restaurant-distance requirement.

Do not turn every raw evidence location into a MapKit request center. Build the
bounded search centers from the original group's representative navigation coordinate and
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
filter and the same centers and evidence scope. Keep the two fully validated match
sets separate. If the category set is empty, the natural-language set must contain
exactly one stable Apple Place ID. If the category set is ambiguous, accept only
when exactly one stable Place ID occurs in both sets; this lets the second pass
corroborate one duplicate Apple record without hiding a disjoint or still-ambiguous
result. Do not issue a broad or unfiltered fallback search. Apply the same
operator, category, locality, distance, and ambiguity rules to both passes. The
second-pass fallback requires both passes to have completed without a center
failure.

Cache the successful native match only within the search/ride under the resolved
operator and original lookup scope; a group-fallback cache key also includes the
stable campus or restaurant-result identity. Charger matching now affects visible
operators, EVSE counts and final inclusion as specified above. It does not change
the canonical route, backend clustering or navigation coordinates, actual-distance
calculation, or the OSM restaurant predicate. Every native handoff still requires
one unambiguous stable Apple place and has no coordinate-only or guessed fallback.
The amendment adds no operator alias or distance-threshold exception.

The iPhone result card does not duplicate navigation; the user may start it from
the native Apple place card. Both CarPlay actions open the same native places.
Cancel pending CarPlay place resolution when a new ride/search or another place
action starts, or the scene disconnects. Before opening Maps or displaying an
error, verify that its source screen and selected POI are still current; stale
completions must not affect an unrelated screen.
Do not embed a second route map or hand a group of caller-created pins to Apple
Maps: those paths do not consistently expose the
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
all address that same coordinate. The native-place handoff does not alter that
search coordinate or claim that the displayed distance was recalculated to an
Apple place. The former multistop handoff's iOS 18.4 availability and iOS 18.0–18.3
restaurant-directions fallback no longer determine CarPlay result actions.

The existing template family, matching thresholds, candidate geometry, power
filter, distance-only ranking and five-result limit remain unchanged. The
2026-10-02 amendment adds Apple-confirmed operator eligibility and rechecks the
existing EVSE minimum before final results. Backend projections, infrastructure
and routing remain unchanged. Additional sequential Apple lookups and complete
food-group collection add latency; no search SLA is established by this decision.
Regression coverage must verify pruning and count rechecks per campus/fine park,
replacement candidates beyond the original five, complete food-group collection,
nearest surviving representative, unchanged original evidence/cache/handoff scope,
retryable lookup failures, cancellation, and no guessed fallback.

The group-bounded fallback and the narrower known-catalog-alias path can correct
Apple catalog mismatches without relaxing campus or restaurant-result identity or
treating a nearby operator as the requested
operator. Regression coverage must include the Wertheim campus and food distances
above, rejection outside the original lookup group, rejection when the Apple
charger exceeds 500 m geodesic distance to the exact grouping restaurant POI,
rejection on missing category/locality, ambiguous Apple Place IDs, and an omitted
category-only result recovered by the filtered operator search in each group type.
It must also include the Zuchwil Autosense/AMAG Energy Charging case at about 78 m
from the requested operator's authority lookup and 51 m from the exact restaurant,
plus rejection at 101 m, for a plain `AMAG` name, for incomplete passes, and when
the two complete passes resolve different IDs.
