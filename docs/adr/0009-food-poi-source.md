# ADR 0009: Food POI source

- Status: Accepted
- Date: 2026-08-13

## Context

The app filters one of four named chains within 500 m and may show opening status
only when reliable. No paid POI API should be introduced while MapKit is sufficient.

## Decision

Use on-device `MKLocalSearch` after charging/corridor filtering. Verify returned
chain aliases and geodesic distance <=500 m. Treat service failure separately from
no result. Do not display opening status from MapKit unless a documented public API
provides it.

## Alternatives

- OSM regional extract in PostGIS: open and batch-searchable, but adds ODbL
  attribution/share-alike/data-boundary work. Keep as validated fallback.
- Paid/commercial or scraped sources: rejected for MVP.

## Consequences

No new backend POI dependency or license is needed initially. MapKit calls add
candidate-enrichment latency and coverage must be field-tested. Opening status is
usually omitted, which the requirements permit.
