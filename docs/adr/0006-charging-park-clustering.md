# ADR 0006: Charging-park clustering

- Status: Accepted
- Date: 2026-08-13

## Context

Distinct operators within 200 m should appear as one park. “Maximum cluster
distance 200 m” is ambiguous under transitive chains.

## Decision

After EVSE deduplication and location assembly, use deterministic complete-linkage
agglomeration with geodesic threshold 200 m. Merge clusters only when every
cross-member pair is <=200 m. Use stable IDs/order and a medoid/best access point.

## Alternatives

- DBSCAN/connected components with epsilon 200 m: simpler and can represent long
  sites, but permits A–C spans over 200 m through B.
- Provider station grouping only: cannot merge multiple operators.

## Consequences

No park exceeds the specified diameter, but the algorithm is more expensive and
may split an elongated service area. Spatial neighborhood pre-grouping keeps it
tractable. The chain-case test is mandatory.
