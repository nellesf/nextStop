# Test strategy

Status: Accepted on 2026-08-13; clustering and Apple-place cases amended through
2026-08-21.

## Pure Swift domain tests

Run without Xcode entitlements through `ios/NextStopCore`.

### Configuration and filters

- Every allowed central option is present once, ordered, stable-ID based, and
  localizable.
- Exact distance-range boundaries for 15–50, 50–100, and 100–150 km.
- EVSE count thresholds and maximum-power thresholds.
- Availability: all-known pass/fail, all-unknown pass-uncertain, partial-known pass,
  partial mathematically impossible fail.
- Selected chain at 0/500 m passes; over 500 m fails; unknown opening status passes.
- No selected chain does not require a POI.
- A selected chain uses the pinned OSM POI projection; exact 500 m is included and
  501 m is excluded even when both are present in the 700 m broad match cache.
- The broad cache compares a POI with the complete-link fine park's base navigation
  coordinate. A POI exactly 700 m away remains discoverable, and an exact <=500 m
  match against a power-filtered member navigation coordinate remains discoverable
  when the two park coordinates are 200 m apart. Duplicate projection work still
  produces one fine-park/POI pair.
- A food-filtered search uses fine parks and ignores no-food campus membership.
- Missing active OSM data is a retryable provider error, not an empty result.
- OSM attribution is present for both non-empty and empty food-filtered responses.

### Ranking

Given exact distances 78, 112, 124, 139, 145, 147 km and range 100–150, final
results are 112, 124, 139, 145, 147 in that order. Operator, surplus EVSE count,
surplus power, availability count, and restaurant distance do not change order.

### Ride state

- Profile copy is value-independent; CarPlay edits never mutate repository profile.
- Fewer than five results are not padded.
- Zero results do not mutate filters.
- Manual refresh creates a new snapshot; background updates do not reorder current
  results.

## Geometry and routing adapter tests

- Synthetic straight/bent/multi-segment routes with a park within 5 km, exactly at
  the boundary, and outside.
- A park inside the route bounding box but over 5 km from the line is excluded.
- Route serialization rejects invalid, empty, one-point, out-of-region, and
  excessive geometries.
- Candidate displayed distance uses the candidate `MKRoute.distance` adapter result,
  not route progress or geodesic distance.
- For no-food mode, exact corridor, straight-line lower bound, MapKit distance, and
  handoff all use the same power-filtered campus navigation coordinate. Food mode
  applies the equivalent rule to each power-filtered fine park.
- Candidate pagination continues until safe lower-bound stopping is proven.
- Candidate enrichment re-evaluates safe stopping after every bounded batch and
  shares a rolling MapKit directions budget across retries and subsequent rides.

MapKit network behavior should be abstracted for deterministic tests; a small set of
manual/integration routes validates assumptions against the real SDK.

## Backend domain/provider tests

- Provider mapping fixtures for station/EVSE/connector semantics.
- Same batch replay is idempotent.
- Same exact EVSE ID across two sources counts once.
- Shared coordinate with distinct EVSE IDs counts separately.
- Conflict priority retains both observations and the selection reason.
- Malformed/out-of-range provider data is quarantined.
- Timeouts, rate limits, partial provider failure, stale cache, and atomic publish.

## Clustering and projection tests

- Different operators at 100 m and 199 m can form one fine park.
- Fine-park complete link: A–B 150 m, B–C 150 m, A–C 300 m cannot form one park;
  the deterministic split and park IDs are invariant under input permutations.
- Campus construction starts from indivisible fine-park seeds, considers only
  exact cross-park member edges <=200 m, accepts a union diameter of exactly 500 m,
  and rejects 501 m.
- Campus edge sorting by distance and canonical endpoint IDs produces identical
  memberships and `charging-campus-v1` IDs under all input permutations and
  equal-distance ties.
- Campus power projection filters individual EVSEs first, deduplicates across all
  constituent fine parks, then derives minimum-count inclusion, exact-name operator
  partitions, availability, maximum power, lookup evidence, name, and navigation.
  It never sums already aggregated child counts.
- The backend selects one campus candidate per campus before count/corridor/origin
  filtering and pagination when food is null; non-null food selects fine parks and
  exact POI matching instead.
- A production-shaped Wertheim regression keeps three fine parks but produces one
  no-food campus. At >=150 kW the 38, 28, and 0 seed counts deduplicate to 66:
  Electra 20, HomE 22, Tesla 20, EnBW 2, and EWE Go 2.
- The full 2026-07-28 Bundesnetzagentur snapshot remains 48,664 fine parks ->
  45,869 no-food campuses; the Stuttgart 12-fine-park area remains six campuses,
  and zero campuses exceed 500 m diameter.

## PostGIS integration tests

Use an isolated real PostGIS instance, not an in-memory substitute:

- `ST_DWithin` exact corridor behavior and geodesic meters.
- Every supported power threshold is materialized with correctly filtered EVSE,
  operator, availability, and coordinate derivations for both fine parks and
  campuses.
- Food-cache publication uses only the fine-park base navigation coordinate at
  700 m; exact food inclusion rechecks the power-filtered fine-park coordinate at
  500 m, and no campus row enters the food join.
- The version/power/coordinate GiST index is present and a representative query
  plan uses it for spatial prefiltering without scanning retained versions.
- Candidate cursor/snapshot is stable across pages.
- Concurrent projection rebuild is atomic for readers.
- Europe boundary/antimeridian-invalid inputs are handled (the supported region
  itself does not cross the antimeridian, but request validation must be robust).

## API contract/security tests

- OpenAPI request/response validation and unknown-field policy.
- `foodChain: null` returns at most one stable-ID candidate per bounded campus with
  campus-wide qualifying EVSE/operator counts; non-null food returns fine-park
  candidates with an exact restaurant match, without changing the v1 wire shape.
- Oversized body, over-8,000-point route, over-250-km segment, over-2,500-km route,
  NaN/invalid ranges, unsupported region, unrecognized enum, cursor mismatch, and
  injection payloads.
- Public health, missing/malformed/wrong bearer credentials, authorized search,
  four-search admission, 429 retry metadata, provider-degraded response, error
  IDs, and no sensitive body or Authorization value in logs.
- TLS/headers and database least privilege in staging checks. Apply the idempotent
  role initializer to real Postgres and assert that API DML/provider-raw access,
  worker DDL/migration-registry access, unsafe attributes, and inherited role
  memberships remain denied after a second run.

## iPhone and CarPlay tests

- Profile form defaults come from the central domain configuration.
- Profile name/destination validation and edit identity preservation.
- SwiftData create/update/delete round trips without a cloud container.
- SwiftUI CRUD and German localization with long text/Dynamic Type.
- Permission denied/restricted/reduced accuracy/no GPS/no internet.
- App Intent resolution, cancellation, and destination-not-found.
- Presenter tests for loading, results, unknown/partial availability, no results,
  relaxation actions, and errors.
- Runtime `CPListTemplate` limits and exactly zero-to-five POIs.
- Locked phone, touch and knob input, light/dark, common aspect ratios, reconnect,
  Apple Maps unavailable/handoff failure.
- On iPhone, verify that every operator and restaurant Maps button has at least a
  48-point touch target, resolves only after it is tapped, opens the native Apple
  place by Place ID, caches the result for a second tap, and reports an unmatched
  item without changing the backend result. Verify that the result card does not
  duplicate the native place card's navigation action.
- Verify charger matching accepts an operator within 60 m without address evidence,
  permits up to 300 m only with matching street, house number, and postal code or
  city, and rejects 301 m even when the address matches.
- Verify the directed normalized catalog mapping from the exact Apple place name
  `AMAG Energy Charging` to the exact requested backend operator `Autosense`,
  including the Zuchwil regression at about 78 m from the requested operator's own
  authority lookup and 51 m from the exact grouping McDonald's. It must require
  `.evCharger`, matching locality, a stable Place ID, fully successful category and
  natural-language passes, and the same single ID in both passes. Cover the 100/101
  m authority-only boundary; reject the reverse direction, equal-name pairs, plain
  `AMAG`, and another operator or group coordinate as 100 m evidence; reject
  incomplete or differing pass results; and retain the food-only 500/501 m
  restaurant boundary.
- Verify the result-group fallback still requires the canonical operator,
  Apple's charger category, matching operator locality, a stable Apple Place ID,
  and one safely resolved Apple place within 60 m of power-qualified group evidence.
  The no-food scope is the selected campus. The food scope is the exact
  restaurant group and additionally requires the Apple charger itself to be no
  more than 500 m from that restaurant; cover the 60/61 m and 500/501 m boundaries.
- Verify charging-location lookup scope never crosses the current result group.
  Within a restaurant group it may include the exact operator across its member
  fine parks; within a no-food result it remains inside the selected campus.
- Verify a ride-local charger cache entry is reused only for the same result-group
  identity, kind, operator, lookup IDs and coordinates, evidence IDs and
  coordinates, search coordinates, restaurant coordinate, and normalized
  operator-address scope.
- Verify bounded charger searches use the representative navigation coordinate and
  requested-operator locations; restaurant groups also use their member fine-park
  navigation coordinates. Deduplicate centers less than 75 m apart, do not search
  once per raw evidence location, and never widen the accepted match distances.
- Verify a primary operator-scoped match may still succeed immediately, but a
  uniqueness-dependent group fallback is rejected when any category-pass center
  fails, or when any category or natural-language center fails before the final
  second-pass fallback decision.
- Verify a complete natural-language pass can recover one identity when the
  complete category pass found none, or can disambiguate an ambiguous category
  pass only when exactly one fully validated stable Place ID occurs in both sets.
  Reject disjoint sets and intersections containing multiple IDs.

Manual CarPlay tests remain blocked until full Xcode and managed entitlement/
provisioning are available.

## Performance tests

- Import and projection build against a production-shaped anonymized/open corpus.
- Candidate query p50/p95/p99 with long cross-border routes and broad filters.
- Exact-route batch latency and request count in typical/urban-dense scenarios.
- Provider payload memory/CPU bounds and decompression-bomb protection.
