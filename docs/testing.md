# Test strategy

Status: Accepted on 2026-08-13.

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

## Clustering tests

- Different operators at 100 m and 199 m form one park.
- Locations over 200 m remain separate.
- A–B 150, B–C 150, A–C 300 exercises the approved chaining semantics.
- All input permutations yield the same clusters and stable IDs.
- Aggregate operators, EVSE count, free coverage, and maximum power are correct.

## PostGIS integration tests

Use an isolated real PostGIS instance, not an in-memory substitute:

- `ST_DWithin` exact corridor behavior and geodesic meters.
- GiST index is present and a representative query plan uses spatial prefiltering.
- Candidate cursor/snapshot is stable across pages.
- Concurrent projection rebuild is atomic for readers.
- Europe boundary/antimeridian-invalid inputs are handled (the supported region
  itself does not cross the antimeridian, but request validation must be robust).

## API contract/security tests

- OpenAPI request/response validation and unknown-field policy.
- Oversized route, too many coordinates, NaN/invalid ranges, unsupported region,
  unrecognized enum, cursor mismatch, and injection payloads.
- 429 retry metadata, provider-degraded response, error IDs, and no sensitive body
  in logs.
- TLS/headers and database least privilege in staging checks.

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

Manual CarPlay tests remain blocked until full Xcode and managed entitlement/
provisioning are available.

## Performance tests

- Import and projection build against a production-shaped anonymized/open corpus.
- Candidate query p50/p95/p99 with long cross-border routes and broad filters.
- Exact-route batch latency and request count in typical/urban-dense scenarios.
- Provider payload memory/CPU bounds and decompression-bomb protection.
