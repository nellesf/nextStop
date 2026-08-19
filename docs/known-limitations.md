# Known limitations

- The Apple EV-charging CarPlay entitlement has not been shown to be available for
  this project. CarPlay runtime behavior cannot be claimed as verified.
- The portable Swift domain core, SwiftUI/SwiftData/MapKit iPhone app, connected
  PostGIS search, automatic German/Swiss authority ingestion, and Swiss live
  availability are implemented. The entitlement-independent CarPlay presenter,
  ride search, and system-template scene adapter are implemented, but cannot be
  claimed as runtime-verified until the managed capability is provisioned. Local
  recent destinations and favorites are implemented for iPhone and CarPlay. A
  foreground App Intent resolves a spoken destination with MapKit and opens the
  same ride preparation; selecting a saved profile as an optional Siri parameter
  is not implemented.
- The current machine lacks an active full Xcode installation. Its standalone
  Swift compiler and SDK revisions also mismatch, so Swift typechecking and the
  executed test suites must run on the Xcode Mac or in CI. All Swift files pass
  local syntax and format checks. The iPhone target is built and tested with the
  current Xcode iOS SDK in GitHub Actions and can be run interactively on the
  separate development Mac.
- CEAP is due by 2026-12-31 and was not discoverable as a production data gateway
  during research on 2026-08-13. National and operator feeds remain necessary.
- European national-access-point coverage and data quality are heterogeneous. AFIR
  establishes access obligations but does not guarantee every field is present or
  operationally reliable in every country.
- Bundesnetzagentur data is authoritative static data but does not provide the live
  availability needed for a complete German live-status experience. Current live
  status is available for Swiss `ich-tanke-strom` EVSEs; German results therefore
  honestly retain unknown availability unless a later validated live source covers
  them.
- Restaurant coverage and chain tagging depend on OpenStreetMap community data.
  Opening status remains unknown unless a later validated parser and freshness
  policy make `opening_hours` safe to interpret; it is never a filter.
- The initial Germany plus Switzerland OSM PBF download is several gigabytes and
  the three-pass streaming import is operationally expensive. Conditional HTTP
  cache validation makes unchanged daily runs cheap, but production should move
  import work to a dedicated worker process before horizontal API scaling.
- Exact driving distance requires MapKit directions per candidate. Candidate
  pagination, bounded concurrency, per-ride caching, batch-level safe lower-bound
  stopping, and a rolling directions budget reduce load, but unusually dense
  corridors may still take longer without replacing MapKit with a server-side
  router.
- Embedded MapKit place cards do not consistently expose every detail shown by the
  Apple Maps app, especially EV charging availability. The iPhone preview can hand
  all matched places to Apple Maps as pins, but Apple Maps does not expose a launch
  option that hides its unrelated base-map POIs.
- Cross-source deduplication without a common EVSE identifier is inherently
  probabilistic. The accepted policy favors under-merging over silently reducing
  the reported number of distinct EVSEs.
- OSM-derived POIs are kept separate from charging records and attribution UI is
  implemented. ODbL/database-distribution obligations still require a release-time
  legal review whenever storage or export boundaries change.
- Provider licenses and terms can change; each provider needs a release-time legal
  and attribution check.
