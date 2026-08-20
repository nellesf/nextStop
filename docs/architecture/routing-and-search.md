# Routing and candidate search

Status: Accepted on 2026-08-13.

## Canonical routing rule

MapKit is the sole source for the user-selected route and actual automobile
distance to a park. The backend does not run a second router in the MVP because
different road graphs/options could rank a different “next five” than Apple Maps.

## End-to-end algorithm

On iPhone, choosing “Ladestationen finden” starts this entire algorithm as one
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
6. Backend queries clustered parks whose geography is within 5,000 m of the actual
   LineString using index-aware `ST_DWithin` on WGS84 geography. A bounding box may
   prefilter but is never the final corridor predicate.
7. Backend computes geodesic distance to the line and a preliminary route-progress
   measure, applies normalized charging filters, and, when selected, joins the
   pinned OSM restaurant projection. It uses a cached 700 m broad pair followed by
   an exact inclusive 500 m geography check against the power-filtered park access
   coordinate. It returns the selected restaurant and attribution in the stable
   paginated snapshot.
8. iOS requests MapKit automobile directions from the current location to each
   candidate in bounded batches behind a shared rolling request gate. Without a
   food filter it applies safe lower-bound stopping after every batch. With a food
   filter it scans candidates within the selected maximum distance so every park
   belonging to a selected restaurant can contribute to its operator counts. Once
   the top five restaurant IDs are proven by the lower bound, later parks for
   other restaurants need no MapKit request.
   `MKRoute.distance` becomes `actualDrivingDistanceMeters` and includes the
   departure from the main route.
9. Discard exact distances outside the selected range.
10. If a food chain is selected, require the backend-provided OSM match. Opening
    information is optional and not a predicate.
11. With a food filter, group matches by stable restaurant POI ID. Sum qualifying
    EVSE counts by exact operator name across all member parks and expose one Apple
    place action per operator. The member park with the shortest actual driving
    distance represents the group for distance and ordering. Without food, every
    matching park remains its own result.
12. Sort matches only by actual driving distance ascending, with stable park ID as
    a non-user-visible deterministic tie-breaker.
13. Return the first five parks or restaurant groups. If fewer exist, return
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
later candidates can share a restaurant already in the first five and must be
included in its displayed operator totals. The maximum-distance lower bound still
terminates that search safely.

Straight-line origin-to-park distance is a safe lower bound for road distance.
Preliminary route progress is useful for batching but is not, by itself, a proof
of actual driving distance. The iPhone process keeps all ride-preparation and
candidate `MKDirections` requests below Apple's observed short-window throttle;
retries consume the same shared request budget.

## PostGIS strategy

- Store park search coordinates as `geography(Point, 4326)` with a GiST index.
- Materialize a power-filtered park row for every supported minimum power option
  during atomic projection publication. A multicolumn GiST index starts with the
  projection ID and power threshold before applying the spatial predicate, so
  retained snapshot versions do not expand the current search.
- Parse request route as valid `geography(LineString, 4326)`.
- Use `ST_DWithin(park.geog, route.geog, 5000)` for the final corridor predicate.
- Use `ST_DWithin(park.geog, origin.geog, maximumDistance)` as a safe early lower-
  bound rejection; final actual driving-distance filtering remains on-device.
- Use `ST_Distance` only after `ST_DWithin` narrows the indexed candidate set.
- Use geography `ST_LineLocatePoint`/`ST_LineSubstring` and length only for
  preliminary progress. Never expose it as driving distance.

PostGIS documents that `ST_DWithin` supports geography and uses spatial indexes,
whereas distance/buffer-only patterns are less suitable:
<https://postgis.net/documentation/tips/st-dwithin/>.

## Search filter order

The static projection build first discards EVSEs below each supported minimum
power, deduplicates the remainder, and derives its count, operators, static
availability, and coordinates. A request then reduces work in this order, subject
to query planning:

1. supported/active projection and exact precomputed power threshold;
2. minimum qualifying EVSE count;
3. exact 5 km spatial predicate via GiST and safe origin/maximum-distance bound;
4. broad cached park/POI pair and exact 500 m OSM restaurant predicate;
5. stable cursor ordering and result-page selection;
6. informational live-availability enrichment for only that selected page.

Actual driving-distance predicates remain on-device. Food proximity is exact
PostGIS geography and remains pinned across pagination with the POI projection ID.

## Route changes and refresh

The search uses a route fingerprint and a stable candidate snapshot. It does not
continuously track/re-route or change result order. A user-initiated refresh or a
new destination creates a new route, new candidate snapshot, and new results. The
fingerprint is built from a canonical field order so semantically identical JSON
requests remain compatible across pages regardless of serializer key order.

## Apple Maps handoff

When a result has a matched restaurant, open Apple's documented unified Maps
`/directions` URL with that restaurant as a waypoint and the ride's original
destination as the final destination. The iOS 26 deployment target supports this
multistop handoff directly. Without a food match, create an `MKMapItem` from the
chosen park access coordinate and open automobile directions to the park. Do not
claim navigation has begun until the handoff succeeds. The app does not render
maneuvers or request the navigation entitlement.

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
