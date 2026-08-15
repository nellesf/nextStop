# Known limitations at the architecture gate

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
  Swift compiler and SDK revisions also mismatch,
  so the executed core test suite must run on the Xcode Mac or in CI. Product and
  core sources pass a direct compiler typecheck against the compatible local macOS
  15.4 SDK. The iPhone target is built and tested with the current Xcode iOS SDK in
  GitHub Actions and can be run interactively on the separate development Mac.
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
- MapKit local search can identify nearby named fast-food POIs, but the public
  `MKMapItem` API does not expose a stable programmatic opening-status value. The
  MVP therefore omits opening status unless a later reliable provider supplies it.
- Exact driving distance requires MapKit directions per candidate. Candidate
  pagination, bounded concurrency, caching within a ride, and safe lower-bound
  stopping are required to keep latency acceptable without replacing MapKit with
  a server-side router.
- Cross-source deduplication without a common EVSE identifier is inherently
  probabilistic. The accepted policy favors under-merging over silently reducing
  the reported number of distinct EVSEs.
- OSM is only a documented fallback for POIs. Production use would require ODbL
  attribution, data-boundary, and share-alike review.
- Provider licenses and terms can change; each provider needs a release-time legal
  and attribution check.
