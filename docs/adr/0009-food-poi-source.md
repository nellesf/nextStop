# ADR 0009: Food POI source

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-18

## Context

The app filters one of four named chains within 500 m. Field testing showed that
per-candidate `MKLocalSearch` is slow, throttle-prone, and unsuitable for a
reusable cross-route result cache. The owner approved replacing it on 2026-08-18.

## Decision

Use OpenStreetMap as the restaurant data source. The backend downloads daily
Geofabrik regional `.osm.pbf` extracts as a transport, validates supported chain
tags, and publishes POIs into a versioned PostGIS projection separate from the
charging corpus. Geofabrik is not the data author.

Precompute park/POI pairs within 700 m for query speed, then enforce the exact
inclusive 500 m predicate against the request-scoped eligible charging navigation
coordinate. `brand:wikidata` is preferred over normalized brand and name aliases.
If no active POI projection exists, return a retryable error rather than a false
no-match. Opening hours remain informational and unknown never fails the filter.

Display `© OpenStreetMap contributors` with a link to
<https://www.openstreetmap.org/copyright> beside results (including empty results)
and in a permanent iPhone data-sources screen. CarPlay result details show the
compact notice; the iPhone screen contains the license and transport links.

## Alternatives

- On-device MapKit local search: originally accepted, now rejected because it adds
  repeated network work and observed throttling without an along-route query.
- Paid/commercial or scraped sources: rejected for MVP.

## Consequences

The backend owns a separately versioned OSM-derived database and attribution
boundary. A first import is intentionally large; later downloads use HTTP
validators and a local PBF cache. Search requests never reach OSM or Geofabrik.
MapKit remains canonical only for the route, actual driving distance, destination
search, and Apple Maps handoff.
