# Fast-food POI source evaluation

Research date: 2026-08-13. Decision updated 2026-08-18 after field testing.

## Superseded MVP recommendation: MapKit on-device

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

## Adopted source: OpenStreetMap-derived POIs

Field validation showed unacceptable latency and MapKit throttling. The backend
therefore ingests Germany and Switzerland regional OSM extracts into a separate
PostGIS projection. It matches restaurant-like amenities using `brand:wikidata`
first and conservative normalized `brand`/`name` aliases. The public Overpass and
Nominatim services are not production dependencies.

OSM data is under ODbL 1.0 with attribution and share-alike obligations:

- [OSMF license and legal FAQ](https://osmfoundation.org/wiki/Licence/Licence_and_Legal_FAQ)
- [OSMF license page](https://osmfoundation.org/wiki/Licence)

The product keeps OSM-derived POIs in a separately versioned relation and displays
`© OpenStreetMap contributors` linked to the OSM copyright page beside results and
in a permanent iPhone licenses screen. CarPlay shows the compact notice in result
details. Geofabrik is identified as the extract transport, not as the source.
Release owners must still re-review current ODbL obligations and any public
database distribution plan; this document is an engineering record, not legal
advice.

## Rejected for MVP

- Paid POI APIs: prohibited unless a future requirement proves free sources
  inadequate and the owner explicitly changes scope.
- Restaurant websites/scraping: brittle, chain-specific, and legally/operationally
  costly.
- Opening hours as a hard filter: contradicts the product rules.
