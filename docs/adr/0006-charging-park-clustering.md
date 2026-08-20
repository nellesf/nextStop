# ADR 0006: Charging-park clustering

- Status: Accepted; amended 2026-08-20
- Date: 2026-08-13
- Last amended: 2026-08-20

## Context

Distinct operators within 200 m should appear as one charging site. The original
decision interpreted this as a maximum park diameter and used deterministic
complete-link clustering. That conservative identity is useful for an exact
restaurant-distance predicate, but it can split a large charging campus into
several user-visible results when no restaurant is requested.

The 2026-07-28 Bundesnetzagentur snapshot exposed this at Wertheim. Complete-link
produced three fine-grained parks. At a minimum power of 150 kW, two contained 38
and 28 qualifying EVSEs and the third contained none; the two visible results were
the same charging campus from the driver's perspective. A first amendment to use
an unbounded 200 m connected component everywhere fixed Wertheim but created
urban chains up to about 1.39 km. Neither one identity for every use case nor an
unbounded transitive component is sufficiently precise.

## Decision

Maintain two distinct, static backend entities. The backend selects the entity for
the request before applying charging filters, route predicates, or pagination.

### Fine-grained `ChargingPark`

After EVSE deduplication and location assembly, build deterministic complete-link
parks with a 200 m geodesic threshold:

1. Start with one cluster per canonical charging location.
2. For each cluster pair, define complete-link distance as the maximum geodesic
   distance across its cross-cluster member pairs.
3. Repeatedly merge the pair with the smallest complete-link distance only when
   that distance is <=200 m. Resolve equal distances by sorted canonical member
   IDs.
4. Derive the park ID from the sorted canonical member location IDs in the
   versioned park-ID namespace.

Every fine park therefore has a maximum member-to-member diameter of 200 m. It is
the indivisible seed for campus construction and is the candidate unit only when
`foodChain` is non-null.

### No-food `ChargingCampus`

Derive campuses from the complete set of fine parks; never split a fine park:

1. Enumerate every exact cross-park member-location edge whose geodesic distance
   is <=200 m.
2. Sort edges by distance ascending, then by the ordered pair of canonical endpoint
   location IDs.
3. Start one group per fine park. For each sorted edge whose endpoints are in
   different groups, merge those groups only when the maximum pairwise geodesic
   distance among all underlying member locations in the union is <=500 m.
4. Derive a stable campus ID in the `charging-campus-v1` namespace from the sorted
   constituent fine-park IDs.

The final diameter cap is inclusive. Membership is independent of route, power,
restaurant, or live availability, so the same source snapshot always produces the
same campuses and IDs.

When `foodChain` is null, one campus is the filter, routing, and API candidate
unit. For each supported minimum-power projection, remove ineligible EVSEs first,
deduplicate the remainder across the entire campus, then derive the campus-wide
minimum-EVSE decision, exact-name operator counts, availability summary, maximum
power, lookup evidence, name, and qualifying member/access navigation coordinate.
The 5 km corridor, origin lower bound, and MapKit actual driving distance all use
that same power-filtered campus navigation coordinate. The backend emits at most
one candidate row per campus before pagination.

When `foodChain` is non-null, campuses are not candidates and do not participate
in food matching. The complete-link fine park remains the filtering/routing unit;
the client subsequently groups qualifying fine parks by stable restaurant POI ID
as specified by ADRs 0009 and 0010.

## Alternatives

- Complete-link parks as the only result unit: retained for food searches but
  rejected for no-food searches because it produced duplicate results at real
  campuses such as Wertheim.
- Unbounded connected components with 200 m edges and `minPoints = 1`: rejected as
  the universal replacement because dense urban chains joined distinct sites over
  distances far beyond the intended result footprint.
- Group already-filtered or paginated park candidates on iOS: rejected because a
  campus must be the unit to which power, EVSE-count, corridor, lower-bound, and
  pagination semantics are applied; post-processing could omit valid campuses or
  double-count EVSEs.
- Provider station grouping only: rejected because it cannot combine a physical
  multi-operator campus.

## Consequences

`ChargingParkID` and `ChargingCampusID` are distinct domain identities even though
the v1 transport keeps the existing candidate shape. UI copy for no-food results
must describe campus-wide EVSE/operator totals rather than imply that every EVSE is
at the exact navigation coordinate. Availability stays informational.

On the full 2026-07-28 Bundesnetzagentur snapshot, 48,664 complete-link fine parks
produce 45,869 no-food campuses. Wertheim changes from three fine parks to one
campus with 66 EVSEs at >=150 kW (Electra 20, HomE 22, Tesla 20, EnBW 2, EWE Go
2). The problematic Stuttgart connected area is deterministically partitioned
from 12 fine parks into six campuses. Across the snapshot, no campus exceeds
500 m diameter.

Mandatory tests cover complete-link chain splitting, indivisible fine-park seeds,
edge-order and input-order determinism, the inclusive 500 m campus cap, stable v1
IDs, campus-wide EVSE deduplication and aggregation, selection of the candidate
unit before filtering/pagination, the Wertheim regression, the Stuttgart split,
and the snapshot totals above.
