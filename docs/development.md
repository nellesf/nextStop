# Local development

## Prerequisites

- A full current Xcode installation with an iOS SDK and CarPlay simulator support.
- Swift 6 toolchain (provided by Xcode for app builds).
- Node.js active LTS and npm for the accepted TypeScript backend.
- PostgreSQL with PostGIS, preferably through a pinned container setup.
- An Apple Developer team. The app core and iPhone UI must work without the final
  EV-charging entitlement; running the CarPlay surface requires Apple's managed
  `com.apple.developer.carplay-charging` capability and matching provisioning.

Observed on 2026-08-14: this machine has Swift 6.3 command-line tools, but the
active developer directory is Command Line Tools rather than full Xcode. The local
Swift compiler and default macOS SDK have different build revisions. With the
compatible macOS 15.4 SDK, production core sources compile, but these Command Line
Tools do not include a compatible XCTest module. Node.js 24 LTS and npm are
installed. PostgreSQL 17 and PostGIS 3.6 are installed through Homebrew for
isolated local backend integration tests; Docker/Podman is not installed.

As a local fallback, all core product sources compile successfully against the
compatible macOS 15.4 SDK, all Swift tests pass the parser, and Swift format lint
passes. XCTest typechecking and execution still happen on the Xcode Mac or in CI.

## Intended workflow after scaffolding

### Pure Swift domain

```bash
cd ios/NextStopCore
swift test
```

This is the entitlement-independent fast path for filter, ranking, availability,
configuration, and orchestration tests. `NextStopCore` is a standalone package and
can also be opened directly through `ios/NextStopCore/Package.swift` in Xcode.

### Pulling onto the Xcode Mac

```bash
git clone <repository-url>
cd nextStop
open ios/NextStop.xcodeproj
```

The checked-in project references `NextStopCore` as a local package and contains
the `NextStopApp` and `NextStopAppTests` targets. Select a personal development
team only when installing on a device. Unit tests for the CarPlay presenter and
ride flow do not require the managed entitlement; launching the CarPlay scene does.
The package can still be opened directly at `ios/NextStopCore/Package.swift` for
the fastest domain-only test loop.

### Regenerating the Xcode project

The generated project is committed so XcodeGen is not required after a pull. When
targets, source roots, build settings, or schemes change, edit `ios/project.yml`
and regenerate with XcodeGen 2.46 or newer:

```bash
xcodegen generate --spec ios/project.yml --project ios
```

Do not make structural changes only in the generated project; they would be lost
on the next regeneration.

### GitHub verification

`.github/workflows/swift-core.yml` runs `swift format lint` and `swift test` for
the portable package. `.github/workflows/ios-app.yml` builds and tests the app on
the GA `macos-26` runner with Xcode 26. Both run for every push and pull request,
use read-only repository permissions, and pin GitHub's checkout action to v7.

### iOS app

```bash
xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStopApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

Replace the simulator name with one installed by the selected Xcode version. The
app requires an Xcode 26 SDK to compile its current MapKit compatibility adapter
while retaining the accepted iOS 18 deployment target.

MapKit deprecated `MKMapItem.placemark` in iOS 26 when it introduced the modern
`location` and `address` properties. The adapter uses the modern API on iOS 26+
and keeps the old call isolated behind an availability branch solely for devices
running the still-supported iOS 18–25 versions.

### Backend

```bash
cd backend
npm ci
npm run lint
npm run typecheck
npm run build
npm test
npm run test:integration
npm run dev
```

`npm run test:integration` uses a real database only when `TEST_DATABASE_URL` is
set. Its database name must end in `_test`; otherwise the suite refuses to run.
GitHub Actions supplies an ephemeral PostGIS service automatically. A local run
looks like:

```bash
TEST_DATABASE_URL=postgresql://127.0.0.1/nextstop_test npm run test:integration
```

The suite recreates only the `nextstop` schema in that dedicated test database.
It verifies the inclusive 5 km corridor boundary, a bounding-box false positive,
the availability truth table, GiST index use, automatic authority-feed refresh,
Swiss live-status joins, atomic publication, and stable pagination across
projection changes.

With `DATABASE_URL` configured, the server applies pending migrations and starts
the provider coordinator automatically. It immediately discovers and downloads
the current official Bundesnetzagentur CSV, downloads Swiss static data, publishes
the combined projection, and refreshes Swiss live availability every minute. Set
`INGESTION_ENABLED=false` only for a deliberately API-only process role. The
manual import command remains a recovery tool documented in
[`docs/operations/bundesnetzagentur-import.md`](operations/bundesnetzagentur-import.md).

### Connected Simulator search

The Debug build defaults to `http://127.0.0.1:3000`, so start the populated
backend on the same Mac that runs the Simulator:

```bash
cd backend
DATABASE_URL=postgresql://127.0.0.1/nextstop \
SNAPSHOT_SIGNING_KEY=replace-with-at-least-32-random-bytes \
npm run dev
```

No charging rows need to be entered manually. `GET /health` reports process
liveness immediately; candidate search honestly returns `503` until the first
background projection has published. The first real import downloads roughly
80 MB of source data before decompression and can take around a minute depending
on the machine and connection.

If Xcode and the backend run on different Macs, set the scheme environment
variable `NEXTSTOP_API_BASE_URL` to the backend's reachable base URL and start the
server with an explicitly appropriate `HOST`. Use this only on a trusted local
network; production configuration must use TLS. The checked-in Release placeholder
is `https://api.example.invalid` so an archive cannot accidentally send routes to
an unapproved host.

After preparing a route, tap “Ladeparks suchen”. The app fetches a stable PostGIS
candidate snapshot, asks MapKit for actual automobile distance to candidates in
bounded groups of four, applies the exact configured range and optional 500 m food
rule, sorts only by actual driving distance, and displays at most five. A result
button hands the selected park to Apple Maps.

### CarPlay acceptance gate

Do not add or sign an unapproved CarPlay capability. The app-binary scene,
system-template flow, saved destination entry points, and search use case compile
and pass entitlement-independent Xcode tests, but the CarPlay app cannot appear in
the Simulator or a vehicle until Apple grants the managed EV-charging entitlement
for `de.nextstop.app` and the development provisioning profile contains it.

After approval, enable the granted capability for the App ID and `NextStopApp`
target, refresh signing assets, and run one integrated acceptance pass:

1. Start PostgreSQL and the backend with ingestion enabled; wait for the initial
   authority projection instead of entering charging rows manually.
2. Launch the iPhone app once, grant precise location, create a profile, and use a
   searched destination so Profile, Favorites, and Recents are populated.
3. Invoke “Plane eine Fahrt mit nextStop” through Siri and confirm that the spoken
   destination opens the same ride preparation with visible default criteria.
4. Connect the CarPlay Simulator and confirm that “Fahrt wählen” lists profiles,
   favorites, and recent destinations.
5. Search a route, verify at most five distance-sorted system-template results,
   refresh once, and hand one result to Apple Maps.
6. Use a Swiss route to verify current `ich-tanke-strom` availability. On German
   Bundesnetzagentur-only records, verify the honest “unbekannt” state; the static
   German authority feed does not contain nationwide live availability.

This is the single user acceptance build requested for the integrated milestone;
CI builds before entitlement approval are verification runs, not user acceptance
builds.

## Configuration and secrets

- Commit `.env.example` with names and safe placeholder values only.
- Load provider credentials and signing material from environment/secret stores.
- Never put API keys, Apple signing assets, real route samples, or production
  database URLs in Git.
- Use separate development, test, staging, and production databases.

## Verification expectations

Every change to search behavior needs domain tests. Every provider change needs
fixture mapping and idempotency tests. Spatial SQL needs PostGIS integration tests.
CarPlay presenter changes need entitlement-independent presenter tests plus manual
CarPlay Simulator verification when provisioning is available.
