# Requirements analysis and scope guardrails

Status: Phase 1 complete; architecture decisions accepted on 2026-08-13.

## Primary use case

From a current location and chosen destination, create a MapKit route and return no
more than five charging parks that satisfy every explicit charging/food criterion,
lie no farther than 5 km from the route, and fall in the chosen actual driving
distance range. Selecting one opens Apple Maps navigation.

## Actors and surfaces

- Driver on CarPlay: selects profile/destination, edits ride-only fixed criteria,
  starts search, reviews up to five results, starts Apple Maps.
- User on iPhone: creates/edits/deletes local profiles, favorites, and recents;
  completes permissions/setup.
- Operator: deploys backend and monitors source freshness/quality without seeing
  personal profiles or retained routes.
- Data provider: supplies official/open static and optionally live EVSE data.

## Functional decomposition

| Capability | Owner |
|---|---|
| Profile/favorite/recent persistence | iPhone local store |
| Destination resolution | MapKit/App Intents on iPhone |
| Destination route geometry | MapKit on iPhone |
| Provider ingestion/normalization | Backend |
| EVSE deduplication and park clustering | Backend |
| Exact <=5 km route corridor | PostGIS backend |
| Charging count/power/availability filter | Backend/domain |
| Actual driving distance to park | MapKit on iPhone |
| Exact distance-range filter and ranking | iPhone domain use case |
| Fast-food <=500 m | MapKit POI adapter on iPhone (MVP) |
| Stable max-five presentation | CarPlay POI/list templates |
| Navigation | Apple Maps |

## Explicit non-goals

No own turn-by-turn navigation, vehicle/SOC profile, automatic battery planning,
payments, charging cards, accounts, cloud sync, ads/analytics profiles, connector
filter, ratings, reservations, live re-ranking, or paid data source.

## Invariants

- Thresholds/options are centrally modeled and versioned.
- `ChargingPoint` means EVSE; connectors do not inflate counts.
- A park may contain several operators.
- Absence of live availability is not negative evidence.
- POI opening status cannot affect inclusion.
- No score exists after filtering; actual distance is the only visible order.
- No result is invented/padded and no filter changes without user action.
- Profiles never cross the backend boundary and CarPlay cannot persist an edit.

## Ambiguities resolved by the architecture

- Partial availability uses explicit possible/impossible three-valued semantics.
- Actual distance is a per-candidate MapKit route distance.
- Park navigation uses a validated access/member coordinate, not cluster centroid.
- POI service failure is different from a confirmed no-match.
- CEAP is a future provider, not a current platform dependency.

## Owner-approved resolutions

- Minimum deployment target: iOS 18.
- Backend: strict TypeScript/Fastify on Node.js active LTS.
- Database: PostgreSQL + PostGIS.
- Clustering: deterministic complete-link with maximum 200 m diameter.
- Provider order: Germany, then Switzerland.
- A destination without a profile uses the visible central defaults from ADR 0012.
- Recent-destination limit: 20.

## Definition-of-done mapping

The vertical slice is complete only when a real-source route can be run through:

```text
location -> destination -> MapKit route -> backend candidates
-> exact corridor -> charging filters -> MapKit distance/food enrichment
-> stable max five -> CarPlay templates -> Apple Maps handoff
```

Unit fixtures alone do not satisfy this; entitlement-independent automation plus a
documented manual CarPlay verification is required. Where entitlement blocks the
manual step, the slice is “functionally complete, CarPlay runtime blocked,” not
fully done.
