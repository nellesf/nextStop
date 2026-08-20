# EVSE deduplication, fine parks, and charging campuses

Status: Accepted on 2026-08-13; amended on 2026-08-20.

Deduplication answers “is this the same EVSE reported twice?” Fine-park
clustering answers “which locations form one conservative physical park?” Campus
construction answers “which nearby fine parks should be one no-food search
result?” They are separate stages and must never be conflated.

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

## Stage 5: fine-park clustering

Build the canonical `ChargingPark` with deterministic complete-link agglomeration:

1. Start with one cluster per charging location, ordered by canonical location ID.
2. Define a cluster pair's complete-link distance as the maximum exact geodesic
   distance across all of its cross-cluster member pairs.
3. Repeatedly merge the pair with the smallest complete-link distance only when it
   is <=200 m. Resolve equal-distance choices with sorted canonical member IDs and
   continue until no valid merge remains.
4. Derive the stable, versioned park ID from sorted canonical member location IDs.

This guarantees a maximum 200 m member-to-member diameter and prevents transitive
chaining. For A–B 150 m, B–C 150 m, and A–C 300 m, complete link cannot put all
three locations in one fine park. A fine park is independent of search criteria
and is never split by a later stage.

The fine park is the backend candidate unit only when `foodChain` is non-null. Its
bounded diameter also makes the 700 m base-navigation food cache complete for the
exact 500 m power-filtered navigation predicate.

## Stage 6: no-food campus construction

Build `ChargingCampus` records from all fine parks as indivisible seeds:

1. Enumerate exact cross-park edges between underlying member locations when the
   geodesic distance is <=200 m.
2. Sort edges by distance ascending, followed by the ordered canonical endpoint
   location IDs as the tie-breaker.
3. Start one group per fine park. Process the sorted edges once. If an edge joins
   two current groups, merge them only when every pair of underlying member
   locations in the union is <=500 m.
4. Emit the remaining groups as campuses. Sort constituent fine-park IDs and hash
   them in the `charging-campus-v1` namespace for a stable campus ID.

The <=200 m edge is a merge opportunity, while <=500 m is the inclusive maximum
campus diameter. Because adding members cannot reduce a group's diameter, a
rejected union cannot become valid later. Exact distance plus canonical endpoint
ordering makes the greedy partition deterministic and independent of input order.

Campuses exist only as the no-food candidate identity. They do not replace fine
parks in storage/provenance, do not participate in the OSM food cache, and are not
constructed from an already filtered or paginated subset.

## Power-specific aggregates

Materialize fine-park and campus summaries for every supported minimum-power
option. For either selected entity:

- discard EVSEs below the power threshold first;
- deduplicate canonical EVSE identity across the complete entity, never by summing
  pre-aggregated child counts;
- derive the qualifying total, exact-name operator counts, maximum power,
  informational availability, source provenance, and Apple-place lookup evidence;
- choose one deterministic qualifying member/access coordinate for display,
  corridor, origin lower bound, MapKit distance, and navigation;
- omit the entity if it does not meet the request's campus- or park-wide minimum
  EVSE count.

When `foodChain` is null, the backend selects the campus projection before filters
and pagination and emits at most one candidate per `ChargingCampusID`. When it is
non-null, it selects the fine-park projection and exact restaurant predicate;
restaurant-centric grouping happens on iOS only after candidate enrichment.

## Aggregate identity and presentation

- Fine-park ID: versioned deterministic hash of sorted canonical member location
  IDs.
- Campus ID: versioned deterministic hash of sorted fine-park IDs under
  `charging-campus-v1`.
- Coordinate: qualifying medoid or validated best-access/member coordinate, never
  an unvalidated centroid.
- Name: authoritative shared site name when available; otherwise a stable concise
  operator/location composition.
- Counts: distinct qualifying canonical EVSEs, with exact-name operator partitions.
- Availability: informational aggregation only; never an inclusion or rank signal.
- Sources/timestamps/quality: union with field-level selected observations.

Maintain aliases when membership changes if a stored reference must resolve across
projection versions. Do not treat a fine-park ID and campus ID as interchangeable.

## Snapshot validation

On the full 2026-07-28 Bundesnetzagentur snapshot:

- 48,664 complete-link fine parks produce 45,869 no-food campuses;
- no resulting campus exceeds 500 m diameter;
- Wertheim's three fine parks become one campus; at >=150 kW their 38, 28, and 0
  qualifying EVSEs aggregate and deduplicate to 66;
- the problematic Stuttgart 200 m-edge component contains 12 fine parks and is
  deterministically partitioned into six campuses, all within the diameter cap.

This corpus result is regression evidence, not a replacement for fixture and
property tests.

## Required tests

- Same source record replayed: one EVSE.
- Same standard EVSE ID from two sources: one EVSE unless a retained identity
  conflict explicitly requires distinct records.
- Same coordinate but two distinct EVSE IDs: two EVSEs.
- Fine parks merge different operators at 100 m and at 199 m.
- Fine-park chain case A–B 150 m, B–C 150 m, A–C 300 m produces a deterministic
  complete-link split rather than one park.
- Campus construction never splits a fine-park seed, considers only <=200 m exact
  cross-edges, rejects a 501 m union, accepts a 500 m union, and is invariant under
  input permutations and equal-distance edge ties.
- Campus power projection deduplicates across fine parks before computing total,
  operator partitions, availability, name, coordinate, and minimum-count result.
- No-food mode chooses one campus candidate before corridor filtering/pagination;
  food mode chooses fine parks and never uses campus membership for POI matching.
- The Wertheim fixture produces one no-food campus with the expected 66 EVSEs at
  >=150 kW while preserving its separate fine parks for food mode.
- The production snapshot regression remains 48,664 fine parks -> 45,869 campuses,
  Stuttgart remains six bounded campuses, and zero campus diameters exceed 500 m.
- Updating or moving one source observation does not double count during an atomic
  projection rebuild.
