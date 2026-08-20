# Charging data provider concept

Status: Accepted on 2026-08-13; projection pipeline amended on 2026-08-20.

## Port

Conceptual backend interface (transport details may vary by source):

```ts
interface ChargingDataProvider {
  readonly descriptor: ProviderDescriptor;
  fetch(request: ProviderFetchRequest): AsyncIterable<ProviderBatch>;
  health(): Promise<ProviderHealth>;
}
```

`ProviderBatch` contains source-private records plus cursor/watermark metadata. A
separate mapper validates and emits normalized observations. The provider never
returns `ChargingPark` or `ChargingCampus`; both exist only after cross-source
identity and backend projection construction.

Provider families:

```text
ChargingDataProvider
  +-- NationalAccessPointProvider (country-specific protocol/config adapters)
  +-- AuthorityOpenDataProvider
  +-- OperatorAPIProvider
  +-- OpenChargeMapProvider (supplemental, open-data-only filter)
  +-- FutureCEAPProvider
```

## Ingestion pipeline

```text
fetch -> byte/content limits -> schema validation -> raw record + hash
      -> source mapping -> normalized observations -> exact identity
      -> conservative cross-source dedup -> conflict resolution
      -> complete-link <=200 m fine parks
      -> deterministic <=200 m-edge / <=500 m-diameter no-food campuses
      -> power-specific fine-park + campus projections -> transactional publish
```

Publishing is atomic: a failed refresh cannot replace the last valid projection
with a half-loaded dataset.

## Provider descriptor

- stable ID, display name, source family and countries;
- authority tier (`operator`, `government`, `open`, `community`);
- static/live capabilities and expected refresh intervals;
- license, attribution, terms URL, and last legal review date;
- authentication mode, rate limit, timeout, and retry policy;
- data retention and redistribution constraints;
- field coverage and known quality limitations.

## OpenStreetMap food POIs

Restaurant POIs use a dedicated adapter and projection rather than the charging
provider interface. OpenStreetMap is the source; Geofabrik transports daily
regional PBF extracts. Downloads are conditional (ETag/Last-Modified), bounded,
hashed, cached on disk, parsed without user requests, and atomically published.
Supported chains are identified by `brand:wikidata`, then conservative brand/name
aliases. Malformed target records are quarantined. Charging and food projections
share an advisory publication lock so their derived match cache is never partial.

## Conflict resolution

Resolve per field, not whole object:

1. discard invalid/expired observations;
2. prefer an exact native/standard EVSE identity over a fuzzy association;
3. among similarly fresh observations, prefer operator then authority data over
   general open/community data for live operational facts;
4. for statutory/static registry facts, prefer the responsible authority when at
   least as recent as lower-tier data;
5. if higher-authority data is materially older, retain both observations and use
   the fresher value only under a field-specific staleness policy;
6. persist conflicts and the selected-value reason; never overwrite history
   blindly.

Freshness thresholds are field/source configuration, not universal constants.
Availability should expire in minutes; static location/power may remain usable for
days while a provider is temporarily unavailable. Exact values require provider
validation during implementation.

## Operational behavior

- Per-provider circuit breaker, bounded exponential retry with jitter, and hard
  connect/read/total timeouts.
- Conditional requests/watermarks when supported.
- Quarantine malformed or implausible records; do not abort unrelated providers.
- Metrics contain provider IDs and aggregate counts, never user routes.
- Provider health is included in internal response metadata so the client can
  distinguish complete, degraded, and stale coverage.

## Adding a provider

1. Verify that access, redistribution, caching, and attribution are free and
   legally compatible; record evidence and date.
2. Define validated source DTOs and fixtures from redacted/public samples.
3. Map source station/EVSE/connector semantics explicitly.
4. Define stable source keys, live/static freshness, and quality tier.
5. Add idempotent import, pagination/watermark, retry, rate-limit, malformed data,
   deduplication, and outage tests.
6. Run a shadow import and compare counts/conflicts before enabling it in the
   production projection.
7. Update source research, attributions, monitoring, and deployment secrets.

## CEAP boundary

CEAP is another provider/access layer. It maps to the same normalized observations
and may supersede NAP access country by country after coverage, freshness, license,
and operational quality validation. National adapters remain available as a
fallback; no UI/API/domain migration is required.
