# Requirements analysis and scope guardrails

Status: Phase 1 complete; architecture decisions accepted on 2026-08-13, with the
clustering decision amended on 2026-08-20.

## Primary use case

From a current location and chosen destination, create a MapKit route and return no
more than five results that satisfy every explicit charging/food criterion, lie no
farther than 5 km from the route, and fall in the chosen actual driving distance
range. Without food a result is one bounded charging campus. With food it is one
restaurant that combines all qualifying nearby fine parks by operator. Selecting
one opens Apple Maps navigation.

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
| EVSE deduplication, fine parks, and no-food campuses | Backend |
| Exact <=5 km route corridor | PostGIS backend |
| Charging count/power filter | Backend/domain |
| Actual driving distance to candidate navigation coordinate | MapKit on iPhone |
| Exact distance-range filter and ranking | iPhone domain use case |
| Fast-food <=500 m | Versioned OSM POI projection and exact PostGIS geography |
| Stable max-five campus/restaurant presentation | CarPlay POI/list templates |
| Navigation | Apple Maps |

## Explicit non-goals

No own turn-by-turn navigation, vehicle/SOC profile, automatic battery planning,
payments, charging cards, accounts, cloud sync, ads/analytics profiles, connector
filter, ratings, reservations, live re-ranking, or paid data source.

## Invariants

- Thresholds/options are centrally modeled and versioned.
- `ChargingPoint` means EVSE; connectors do not inflate counts.
- A fine park may contain several operators and has a deterministic complete-link
  diameter of at most 200 m.
- Without food, fine parks are indivisible seeds; deterministically ordered
  cross-park edges of at most 200 m merge groups only while the complete campus
  diameter stays at most 500 m.
- The backend selects campus versus fine-park candidate identity before power/count,
  corridor, origin-bound, and pagination filtering.
- A food-filtered result contains exactly one restaurant; all qualifying fine parks
  matched to its stable POI ID are combined by exact operator name.
- Availability is informational and never affects inclusion.
- POI opening status cannot affect inclusion.
- No score exists after filtering; actual distance is the only visible order.
- No result is invented/padded and no filter changes without user action.
- Profiles never cross the backend boundary and CarPlay cannot persist an edit.

## Ambiguities resolved by the architecture

- Partial availability is displayed honestly but is not a search criterion.
- Actual distance is a per-candidate MapKit route distance.
- Candidate navigation uses one power-filtered access/member coordinate, not a
  cluster centroid. Corridor, lower bound, MapKit distance, and handoff use it
  consistently.
- POI service failure is different from a confirmed no-match.
- CEAP is a future provider, not a current platform dependency.

## Owner-approved resolutions

- Minimum deployment target: iOS 18.
- Backend: strict TypeScript/Fastify on Node.js active LTS.
- Database: PostgreSQL + PostGIS.
- Clustering: deterministic complete-link fine parks with <=200 m diameter; for
  no-food searches, a deterministic greedy campus projection with <=200 m
  cross-edges, indivisible fine-park seeds, and <=500 m diameter; approved as an
  amendment on 2026-08-20.
- Provider order: Germany, then Switzerland.
- A destination without a profile uses the visible central defaults from ADR 0012.
- Recent-destination limit: 20.

## Definition-of-done mapping

The vertical slice is complete only when a real-source route can be run through:

```text
location -> destination -> MapKit route -> backend campus-or-fine-park candidates
-> exact corridor -> charging + OSM food filters -> MapKit driving-distance enrichment
-> stable max five -> CarPlay templates -> Apple Maps handoff
```

Unit fixtures alone do not satisfy this; entitlement-independent automation plus a
documented manual CarPlay verification is required. Where entitlement blocks the
manual step, the slice is “functionally complete, CarPlay runtime blocked,” not
fully done.
