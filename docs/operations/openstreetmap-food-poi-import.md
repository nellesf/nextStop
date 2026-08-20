# OpenStreetMap food-POI import runbook

Status: Implemented on 2026-08-18; fine-park cache semantics clarified on 2026-08-20.

## Source and license boundary

OpenStreetMap contributors are the data source. Geofabrik provides daily regional
extracts as the download transport. OSM data is licensed under ODbL 1.0. Keep the
OSM-derived POI projection separate from charging-source relations and retain the
product notice `© OpenStreetMap contributors` linked to
<https://www.openstreetmap.org/copyright>. Re-review the license before changing
database export or redistribution boundaries.

## Automatic operation

The provider coordinator starts one food refresh immediately and then every 24
hours. It downloads configured `*-latest.osm.pbf` files sequentially, sends
ETag/Last-Modified validators, keeps successful files in the local cache, hashes
the combined source snapshot, and skips an unchanged projection. Publication uses
the same database advisory lock as charging projections so the derived 700 m
fine-park/POI match cache is complete at activation. A pair is retained when the
POI is within 700 m of the complete-link fine park's base navigation coordinate.
No-food campus rows are not part of this cache.

Defaults cover Germany and Switzerland. Override only with reviewed Geofabrik
HTTPS extract URLs:

```bash
OSM_GEOFABRIK_PBF_URLS=https://download.geofabrik.de/europe/germany-latest.osm.pbf,https://download.geofabrik.de/europe/switzerland-latest.osm.pbf
OSM_CACHE_DIRECTORY=/var/lib/nextstop/osm-cache
OSM_INGESTION_ENABLED=true
```

The cache directory must have enough space for the PBF files and be private to the
worker. A first Germany import is several gigabytes and performs multiple streaming
passes. Run exactly one OSM ingestion worker per database.

## Manual recovery

```bash
cd backend
DATABASE_URL=postgresql://127.0.0.1/nextstop npm run refresh:osm
```

The command emits only projection IDs and aggregate counts. It must never log raw
routes (none are involved), provider payload contents, or secrets. A failed build
is marked failed and cannot retire the prior active POI projection.

## Validation

- Confirm one active `food_poi_projection_versions` row and a nonzero POI count.
- Confirm quarantine counts are reviewed when they change materially.
- Run the PostGIS integration suite; it proves inclusive 500 m and exclusive 501 m
  behavior after the broad cache, plus completeness when the fine park's base and
  power-filtered navigation coordinates are up to 200 m apart. The broad 700 m
  cache may admit false positives, but the exact request predicate must remove them.
- Search with every supported chain and verify the iPhone result/no-result view
  shows the linked OSM notice.
- Verify the permanent iPhone data-sources screen and compact CarPlay attribution.

If no valid POI projection exists, selected-chain searches intentionally return a
retryable 503. Searches without a selected chain remain independent of this corpus.
