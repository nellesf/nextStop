# Fast-food POI source evaluation

Research date: 2026-08-13.

## MVP recommendation: MapKit on-device

Use `MKLocalSearch` for the selected chain around candidate parks, then enforce the
500 m geodesic distance in app code. Search by normalized chain aliases and verify
the returned name/brand defensively. Cache results only within the ride/search
session.

Why it is sufficient for the specified MVP:

- only four globally recognizable named chains are supported;
- at most one chain is active at a time;
- POI proximity is checked after charging/corridor filters reduce candidates;
- MapKit is already required for destination/routing and adds no paid POI vendor;
- missing opening status is explicitly allowed by the product brief.

Apple sources:

- [`MKLocalSearch.Request`](https://developer.apple.com/documentation/mapkit/mklocalsearch/request)
- [Interacting with nearby points of interest](https://developer.apple.com/documentation/mapkit/interacting-with-nearby-points-of-interest)
- [`MKMapItem`](https://developer.apple.com/documentation/mapkit/mkmapitem)

## Important MapKit limitation

Apple's system place card may display business hours, but the documented public
`MKMapItem` attributes do not provide a stable opening-status field to application
logic. Do not scrape UI, infer status, or filter by it. Display only chain and
distance in the MVP unless a reliable later source explicitly supplies status.

## Failure semantics

`MKLocalSearch` returning no matching item is a confirmed no-match only when the
request succeeded. Network/service failure is “POI data unavailable,” not an empty
result. The search orchestrator may retry or fetch the next batch, but must not
silently claim that a park fails the food criterion because the provider failed.

## Fallback: OpenStreetMap-derived POIs

If field validation shows unacceptable MapKit gaps or latency, ingest regional OSM
extracts into a separate PostGIS source schema. Match `amenity=fast_food` plus
normalized `brand`, `brand:wikidata`, and names. Do not use the public Overpass
service as an unbounded production dependency.

OSM data is under ODbL 1.0 with attribution and share-alike obligations:

- [OSMF license and legal FAQ](https://osmfoundation.org/wiki/Licence/Licence_and_Legal_FAQ)
- [OSMF license page](https://osmfoundation.org/wiki/Licence)

Before enabling the fallback, obtain a concrete data-boundary/attribution review,
publish required attribution in iPhone/CarPlay-appropriate surfaces, and document
the extract/update process. Do not casually merge OSM-derived records into a
redistributed charging database without reviewing derivative-database obligations.

## Rejected for MVP

- Paid POI APIs: prohibited unless a future requirement proves free sources
  inadequate and the owner explicitly changes scope.
- Restaurant websites/scraping: brittle, chain-specific, and legally/operationally
  costly.
- Opening hours as a hard filter: contradicts the product rules.
