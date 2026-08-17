# Routing and candidate search

Status: Accepted on 2026-08-13.

## Canonical routing rule

MapKit is the sole source for the user-selected route and actual automobile
distance to a park. The backend does not run a second router in the MVP because
different road graphs/options could rank a different “next five” than Apple Maps.

## End-to-end algorithm

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
   measure, applies filters that it can prove from normalized charging data, and
   returns a stable paginated candidate snapshot.
8. iOS requests MapKit automobile directions from the current location to each
   candidate in bounded batches. `MKRoute.distance` becomes
   `actualDrivingDistanceMeters` and includes the departure from the main route.
9. Discard exact distances outside the selected range.
10. If a food chain is selected, query MapKit near each remaining candidate and
    accept only matching chain results whose geodesic point-to-park distance is at
    most 500 m. Opening information is optional and not a predicate.
11. Sort matches only by actual driving distance ascending, with stable park ID as
    a non-user-visible deterministic tie-breaker.
12. Return the first five. If fewer exist, return fewer. If pagination is not
    exhausted and correctness cannot yet be proven, request the next batch.

## Correct pagination and stopping

The backend returns candidates ordered by a conservative lower bound, not a final
rank. The client may stop only when:

- the candidate snapshot is exhausted; or
- at least five matches exist and every unprocessed candidate's provable lower
  bound is greater than the fifth match's actual driving distance; or
- the lower bound exceeds the selected range maximum and ordering guarantees all
  later lower bounds are no smaller.

Straight-line origin-to-park distance is a safe lower bound for road distance.
Preliminary route progress is useful for batching but is not, by itself, a proof
of actual driving distance.

## PostGIS strategy

- Store park search coordinates as `geography(Point, 4326)` with a GiST index.
- Parse request route as valid `geography(LineString, 4326)`.
- Use `ST_DWithin(park.geog, route.geog, 5000)` for the final corridor predicate.
- Use `ST_Distance` only after `ST_DWithin` narrows the indexed candidate set.
- Use geography `ST_LineLocatePoint`/`ST_LineSubstring` and length only for
  preliminary progress. Never expose it as driving distance.

PostGIS documents that `ST_DWithin` supports geography and uses spatial indexes,
whereas distance/buffer-only patterns are less suitable:
<https://postgis.net/documentation/tips/st-dwithin/>.

## Search filter order

An initial SQL plan should reduce work in this order, subject to query planning:

1. supported/active park projection and data-expiry policy;
2. exact 5 km spatial predicate via GiST;
3. discard individual EVSEs below the requested minimum power;
4. deduplicate the remaining EVSEs and apply the minimum EVSE count;
5. apply the availability truth table to that same filtered EVSE set;
6. broad progress/lower-bound window for batching.

Actual driving-distance and MapKit food predicates remain on-device.

## Route changes and refresh

The search uses a route fingerprint and a stable candidate snapshot. It does not
continuously track/re-route or change result order. A user-initiated refresh or a
new destination creates a new route, new candidate snapshot, and new results.

## Apple Maps handoff

When a result has a matched restaurant, open Apple's documented unified Maps
`/directions` URL with that restaurant as a waypoint and the ride's original
destination as the final destination. This multistop handoff is available on iOS
18.4 and later. On iOS 18.0–18.3, open automobile directions to the restaurant as
the safe documented fallback. Without a food match, create an `MKMapItem` from the
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
