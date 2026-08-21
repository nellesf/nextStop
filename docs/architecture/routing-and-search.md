# Routing and candidate search

Status: Accepted on 2026-08-13; candidate identity and group-bounded Apple-place
matching amended on 2026-08-20.

## Canonical routing rule

MapKit is the sole source for the user-selected route and actual automobile
distance to a candidate navigation coordinate. The backend does not run a second
router in the MVP because different road graphs/options could rank a different
“next five” than Apple Maps.

## End-to-end algorithm

On iPhone, choosing “Suche starten” starts this entire algorithm as one
user action. Re-entering an already prepared view does not implicitly refresh its
stable snapshot; retry and refresh remain explicit after an error or result.

1. Obtain a current location only after explicit in-use authorization.
2. Resolve the destination to an `MKMapItem`.
3. Request automobile directions with alternate routes disabled; use the selected
   `MKRoute.polyline` and record the routing options.
4. Validate and serialize the detailed polyline as a GeoJSON LineString. Reject
   invalid coordinates, degenerate lines, excessive point counts, and routes
   outside the supported region.
5. Send the route plus ride criteria to the backend. Do not send profile name,
   saved destination text, favorites, account ID, or a persistent device ID.
6. Backend chooses the search entity before any filter or pagination. With
   `foodChain = null`, it selects one bounded `ChargingCampus` per stable campus ID.
   With a selected chain, it selects complete-link `ChargingPark` rows and never
   uses campus membership for restaurant matching.
7. Backend selects the entity's precomputed power projection, then applies the
   entity-wide minimum qualifying EVSE count, the exact 5,000 m route-corridor
   predicate, and the safe origin bound against its power-filtered navigation
   coordinate. A bounding box may prefilter but is never the final corridor
   predicate. For food mode, the 700 m broad cache compares the POI with the fine
   park's base navigation coordinate; the candidate query then applies the exact
   inclusive 500 m check against the power-filtered fine-park navigation
   coordinate and returns the selected restaurant plus attribution.
8. iOS requests MapKit automobile directions from the current location to each
   candidate navigation coordinate in bounded batches behind a shared rolling
   request gate. Without a food filter it applies safe lower-bound stopping after
   every batch. With a food filter it scans candidates within the selected maximum
   distance so every fine park belonging to a selected restaurant can contribute
   to its operator counts. Once
   the top five restaurant IDs are proven by the lower bound, later fine parks for
   other restaurants need no MapKit request.
   `MKRoute.distance` becomes `actualDrivingDistanceMeters` and includes the
   departure from the main route.
9. Discard exact distances outside the selected range.
10. If a food chain is selected, require the backend-provided OSM match. Opening
    information is optional and not a predicate.
11. With a food filter, group matches by stable restaurant POI ID. Sum qualifying
    EVSE counts by exact operator name across all member fine parks and expose one
    Apple place action per operator. The member fine park with the shortest actual
    driving distance represents the group for distance and ordering. Without food,
    every matching campus is already one result with campus-wide deduplicated EVSE
    and exact-name operator counts.
12. Sort matches only by actual driving distance ascending, with the stable campus,
    fine-park, or restaurant identity as a non-user-visible deterministic tie-breaker.
13. Return the first five campuses or restaurant groups. If fewer exist, return
    fewer. If pagination is not exhausted and correctness cannot yet be proven,
    request the next batch.

## Correct pagination and stopping

The backend returns candidates ordered by a conservative lower bound, not a final
rank. The client may stop only when:

- the candidate snapshot is exhausted; or
- at least five matches exist and every unprocessed candidate's provable lower
  bound is greater than the fifth match's actual driving distance; or
- the lower bound exceeds the selected range maximum and ordering guarantees all
  later lower bounds are no smaller.

The five-result lower-bound shortcut is not used for a food-filtered search:
later fine-park candidates can share a restaurant already in the first five and
must be included in its displayed operator totals. The maximum-distance lower
bound still terminates that search safely. Without food, one backend row already
represents the whole campus, so the ordinary shortcut remains correct.

Straight-line origin-to-candidate-navigation distance is a safe lower bound for
road distance. Preliminary route progress is useful for batching but is not, by
itself, a proof
of actual driving distance. The iPhone process keeps all ride-preparation and
candidate `MKDirections` requests below Apple's observed short-window throttle;
retries consume the same shared request budget.

## PostGIS strategy

- Store fine-park and campus search navigation coordinates as
  `geography(Point, 4326)` with GiST indexes.
- Materialize power-filtered fine-park and campus rows for every supported minimum
  power option during atomic projection publication. Campus rows deduplicate EVSEs
  across all constituent fine parks before deriving total/operator counts and the
  minimum-count decision. A multicolumn GiST index starts with the projection ID
  and power threshold before applying the spatial predicate, so retained snapshot
  versions do not expand the current search.
- Treat the 700 m base-navigation fine-park/POI relation only as a completeness
  prefilter. Both base and power-filtered navigation coordinates are member/access
  locations in a <=200 m-diameter fine park, so every exact <=500 m match is
  retained. Campus rows never enter the restaurant join.
- Parse request route as valid `geography(LineString, 4326)`.
- Use `ST_DWithin(powerCandidate.navigationGeog, route.geog, 5000)` for the final
  corridor predicate.
- Use `ST_DWithin(powerCandidate.navigationGeog, origin.geog, maximumDistance)` as
  a safe early lower-bound rejection; final actual driving-distance filtering
  remains on-device.
- Use `ST_Distance` only after `ST_DWithin` narrows the indexed candidate set.
- Use geography `ST_LineLocatePoint`/`ST_LineSubstring` and length only for
  preliminary progress. Never expose it as driving distance.

PostGIS documents that `ST_DWithin` supports geography and uses spatial indexes,
whereas distance/buffer-only patterns are less suitable:
<https://postgis.net/documentation/tips/st-dwithin/>.

## Search filter order

The static projection build first discards EVSEs below each supported minimum
power. It then deduplicates and derives count, operators, static availability,
lookup evidence, and coordinates across each fine park and, independently, across
each whole campus. A request reduces work in this order, subject to query planning:

1. select campus rows for `foodChain = null`, otherwise fine-park rows plus the
   pinned OSM projection;
2. supported/active projection and exact precomputed power threshold;
3. candidate-wide minimum qualifying EVSE count;
4. exact 5 km spatial predicate via GiST and safe origin/maximum-distance bound
   against the same power-filtered candidate coordinate;
5. only in food mode, broad cached fine-park/POI pair and exact 500 m OSM
   restaurant predicate against the power-filtered fine-park coordinate;
6. stable cursor ordering and result-page selection, with one row per campus in
   no-food mode;
7. informational live-availability enrichment for only that selected page.

Actual driving-distance predicates remain on-device. Food proximity is exact
PostGIS geography and remains pinned across pagination with the POI projection ID.

## Route changes and refresh

The search uses a route fingerprint and a stable candidate snapshot. It does not
continuously track/re-route or change result order. A user-initiated refresh or a
new destination creates a new route, new candidate snapshot, and new results. The
fingerprint is built from a canonical field order so semantically identical JSON
requests remain compatible across pages regardless of serializer key order.

## Native Apple-place enrichment

Native Apple-place resolution starts only after the user taps an operator or
restaurant Maps button and never participates in candidate inclusion or ranking.
Every charging-place candidate must match the requested operator name and have
Apple's `.evCharger` category. Accept it within 60 m of that operator's qualifying
authority location without address evidence, or within 300 m when street, house
number, and postal code or city match. These primary rules apply in both search
modes.

Within either an already selected no-food `ChargingCampus` or one concrete
restaurant-centered result group, a local fallback may accept a charger that fails
both primary rules. Its address must share the postal code or normalized city of
the requested operator's qualifying authority evidence. Without food, its
coordinate must be within 60 m of any qualifying campus location and no restaurant
distance applies. With food, it must be within 60 m of any power-qualified location
in a member fine park assigned to the exact current restaurant POI and within
500 m geodesic distance of that POI. A different operator's location is spatial
evidence only; the Apple place itself must still match the requested operator.

Search centers are deliberately narrower than the raw evidence set. Both modes
include the result's representative navigation coordinate and the requested
operator's authority lookup coordinates. A restaurant group also includes the
deterministic navigation coordinate of every member fine park assigned to the
exact restaurant POI. No-food uses the selected campus navigation coordinate plus
the operator lookups and does not add member-fine-park centers. Deduplicate the
ordered center list with a 75 m minimum separation. Power-qualified raw locations
remain evidence for the <=60 m rule but do not each trigger a MapKit request.

First perform the bounded category-only `.evCharger` searches across those
centers. A primary operator-specific match retains its existing best-match
behavior and may return immediately. Otherwise accept one unambiguous fallback
match after the complete category pass. A failed center makes the pass incomplete
and disables that uniqueness-dependent fallback while a primary match remains
eligible. If that pass has no secure match,
including an ambiguous set of qualifying candidates, perform a second bounded
natural-language search for the requested operator with the same centers,
`.evCharger` filter, and evidence scope. Keep the fully validated pass sets
separate. When the category set is empty, require exactly one stable Place ID in
the natural-language set. When the category set is ambiguous, require exactly one
stable Place ID in the intersection of both sets. Never issue a broad, unfiltered,
or out-of-scope fallback search. Apply the same identity, locality, and distance
rules, including the food-only 500 m restaurant-distance condition. The
second-pass fallback additionally requires every center in both passes to have
completed successfully.

In a restaurant result, any power-qualified location in a member fine park assigned
to the exact grouping restaurant POI may provide spatial evidence. A different
operator's location never provides operator identity. If the applicable rules do
not yield one unambiguous stable Apple place, keep the
authority/OSM-backed result visible and report that Apple details are unavailable.
The 2026-08-20 Wertheim regression fixes the intended boundary: Apple's Tesla
place was 211.5 m from the Tesla authority point, 257.2 m from the exact grouping
McDonald's, and 57.2 m from a power-qualified location of another member fine park
in that restaurant group.

## Apple Maps handoff

When a result has a matched restaurant, open Apple's documented unified Maps
`/directions` URL with that restaurant as a waypoint and the ride's original
destination as the final destination. This multistop handoff is available on iOS
18.4 and later. On iOS 18.0–18.3, open automobile directions to the restaurant as
the safe documented fallback. Without a food match, create an `MKMapItem` from the
chosen campus navigation coordinate and open automobile directions to the campus.
Do not claim navigation has begun until the handoff succeeds. The app does not
render maneuvers or request the navigation entitlement.

## Error mapping

- no/denied location: explain on iPhone how to grant permission; CarPlay shows a
  concise unavailable state;
- reduced accuracy: request temporary full accuracy only when route/corridor
  correctness requires it and provide clear purpose text;
- destination not found: offer Siri/recent/favorite/profile paths again;
- directions unavailable: retry or change destination;
- backend/partial provider error: use only valid non-expired cached projection and
  label degraded freshness, otherwise retry;
- food provider unavailable: do not claim zero matches; show a retryable POI error;
- no matches: show explicit filter-relaxation actions; change only the selected
  filter after user interaction.
