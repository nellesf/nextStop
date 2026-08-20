# ADR 0005: Use PostGIS

- Status: Accepted
- Date: 2026-08-13

## Context

The 5 km route rule, 200 m fine-park/campus-edge rules, 500 m campus-diameter rule,
and separate 500 m food-distance rule require correct point/line geodesic
predicates at European scale. Bounding-box-only filtering is forbidden.

## Decision

Enable PostGIS. Store WGS84 geography columns with GiST indexes and use index-aware
`ST_DWithin` for exact corridor/radius filtering; calculate `ST_Distance` only on
the reduced set. Use linear-reference functions only for preliminary route progress.

## Alternatives

- Application-only Haversine/segment loops: harder to index and scale, duplicates
  tested spatial database behavior.
- Non-spatial PostgreSQL bounding boxes: can admit invalid results and violates the
  requirement as a final predicate.

## Consequences

Development/CI/production require the PostGIS extension and real integration tests.
Spatial SQL and query plans are first-class code. MapKit remains the actual driving
distance source; PostGIS does not become a router.
