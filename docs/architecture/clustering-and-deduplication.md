# EVSE deduplication and charging-park clustering

Status: Accepted on 2026-08-13.

Deduplication answers “is this the same EVSE reported twice?” Clustering answers
“are these distinct EVSEs part of one user-visible park?” They are separate stages
and must never be conflated.

## Stage 1: source idempotency

The tuple `(providerID, providerRecordID, payloadVersion/contentHash)` prevents a
provider replay from creating a second normalized observation. Updates create new
observations for the same source entity.

## Stage 2: exact cross-source EVSE identity

Normalize standard/native IDs (case, separators, country/party components) and
merge when an authoritative identifier matches. Preserve all source references.
Never count two connectors on the same EVSE as two charging points.

## Stage 3: conservative high-confidence identity

Only when exact IDs are absent, calculate evidence from:

- very close coordinate within a much smaller dedup threshold than 200 m;
- normalized operator/location identity;
- compatible connector/power fingerprint;
- address/name evidence;
- observation overlap and explicit provider cross-reference.

Automatic merge requires a versioned high-confidence rule. Ambiguous pairs remain
distinct with a `possibleDuplicate` conflict for review. The system favors
under-merging over silently collapsing real adjacent EVSEs.

Coordinates alone must never deduplicate two EVSEs: multiple legitimate EVSEs at
one site commonly share a coordinate.

## Stage 4: location assembly

Group deduplicated EVSEs into physical `ChargingLocation` records using provider
location IDs and conservative physical-site evidence. Retain actual EVSE records
and operators.

## Stage 5: park clustering

### Recommended rule

Use deterministic complete-linkage agglomeration with threshold 200 m:

1. Start with one cluster per charging location.
2. Compute geodesic pair distances.
3. Repeatedly merge the lexicographically deterministic closest pair of clusters
   only when **every** cross-cluster member pair is <=200 m.
4. Recompute aggregates until no valid merge remains.

This guarantees cluster diameter <=200 m and prevents transitive chaining. Stable
sorting by canonical location ID resolves equal-distance order.

### Alternative requiring explicit approval

DBSCAN/connected components with epsilon 200 m and `minPoints = 1` is simple and
handles long service areas, but A within 200 m of B and B within 200 m of C can
merge A and C even when they are farther than 200 m apart. Choose it only if the
product interprets 200 m as an edge/link distance rather than maximum park span.

## Park aggregate

- ID: deterministic hash/version of sorted canonical member location IDs. Maintain
  aliases when membership changes so favorites/navigation references can resolve.
- Coordinate: medoid or best access coordinate, not unvalidated centroid.
- Name: authoritative shared site name when available; otherwise stable concise
  operator composition/location label.
- Operators: sorted distinct canonical operators.
- EVSE count: distinct canonical charging-point IDs.
- Availability counts: informational aggregation over current deduplicated EVSEs.
- Maximum power: maximum valid EVSE capability.
- Sources/timestamps/quality: union with field-level selected observations.

## Required tests

- Same source record replayed: one EVSE.
- Same standard EVSE ID from two sources: one EVSE.
- Same coordinate but two distinct EVSE IDs: two EVSEs.
- Two operators 100 m apart: one park.
- Two locations 199 m apart: one park.
- Two locations over 200 m apart: separate parks.
- A–B 150 m, B–C 150 m, A–C 300 m: deterministic result that demonstrates the
  approved complete-link vs transitive rule.
- Input order permutations yield identical membership and IDs.
- Updating/moving one source observation does not double count during projection
  rebuild.
