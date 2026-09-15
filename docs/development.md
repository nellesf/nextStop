# Local development

## Prerequisites

- A full current Xcode installation with an iOS SDK and CarPlay simulator support.
- Swift 6 toolchain (provided by Xcode for app builds).
- Node.js active LTS and npm for the accepted TypeScript backend.
- PostgreSQL with PostGIS, preferably through a pinned container setup.
- An Apple Developer team for device signing. The repository already declares
  `com.apple.developer.carplay-charging`. Simulator capture uses Xcode's embedded
  simulator entitlements; device builds require Apple's managed capability and
  matching provisioning.

Observed on 2026-08-17: this machine has Swift 6.3 command-line tools, but the
active developer directory is Command Line Tools rather than full Xcode. The local
Swift compiler and installed macOS SDKs have incompatible build revisions, and the
Command Line Tools do not provide a usable XCTest setup. Node.js 24 LTS and npm are
installed. PostgreSQL 17 and PostGIS 3.6 are installed through Homebrew for
isolated local backend integration tests; Docker/Podman is not installed.

As a local fallback, all Swift sources and tests pass the parser and Swift format
lint passes. Full Swift typechecking and XCTest execution happen on the Xcode Mac
or in CI.

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
the `NextStopApp`, `NextStopAppTests`, `NextStopCarPlayTests`, and
`NextStopAppUITests` targets. Select a personal development
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
the portable package. `.github/workflows/ios-app.yml` builds the Debug app and
runs its unit, CarPlay presenter, and iPhone UI tests on the GA `macos-26` runner
with Xcode 26 and an iPhone 17 Pro Simulator. Both workflows run for every push
and pull request, use read-only repository permissions, and pin GitHub's checkout
action to v7. The iOS job has a 30-minute timeout and can also be started manually
from **Actions → iOS App → Run workflow**, selecting `all`, `ui`, or `screenshots` and the
desired branch. A queued GitHub runner does not block local Simulator testing.

Every iOS run uploads the result bundle as `ios-test-results` and exported test
attachments as `ios-ui-attachments`, when those files exist, even after a test
failure. Both artifacts expire after seven days. Open a workflow run's
**Artifacts** section to download them; the attachments include screenshots from
successful UI checkpoints as well as failure evidence. Their `manifest.json`
maps exported files to test and attachment names. Extract
`TestResults.xcresult.tar.gz` and open the resulting bundle in Xcode for the full
test report. The archive preserves the complete bundle without uploading the
workspace, credentials, or a Simulator device directory. CI uses synthetic data;
never supply real report text, logs, or access tokens to these tests.

Screenshots support manual checks for clipping, spacing, and contrast. They are
not pixel-baseline comparisons, and a passing UI test does not establish that
every layout is visually correct. The iPhone UI suite does not launch or capture
the external CarPlay display. The separate website-branch **CarPlay Screenshots**
workflow exercises that display; the existing CarPlay unit tests verify presenter
behavior. Simulator captures do not replace testing in a vehicle.

The website branch also supports a dedicated `screenshots` scope. It checks out
the requested `app_ref` separately, overlays only the UI test harness, and verifies
that application sources, the Xcode project, and configuration remain unchanged.
Use the full current `main` SHA for `app_ref`. This capture uses an isolated profile
and selects a public city through the app's normal MapKit destination UI. It never
performs a charging search or opens personal data. The three original PNGs and
`capture-source.json` are exported with the usual attachment artifact. Website
capture tests are excluded from the ordinary `all` and `ui` scopes.

```bash
gh workflow run ios-app.yml --ref codex/app-explainer-website \
  -f test_scope=screenshots -f app_ref=<full-main-commit-sha>
gh run download <run-id> -n ios-ui-attachments -D /tmp/nextstop-screenshots
node website/scripts/import-screenshots.mjs /tmp/nextstop-screenshots <full-main-commit-sha>
```

The importer verifies the source commit and records original file hashes and
capture times in `website/public/screenshots/provenance.json`.

The website branch's **CarPlay Screenshots** workflow also accepts
`capture_mode=results`. Its opt-in hosted test queries real MapKit places and
supplies provider example counts and power through the existing dependency
interfaces. The pinned main application performs routing, driving-distance
calculation, filtering, presentation, and place resolution. Restaurant and charging-place screens
are opened by the unchanged Apple Maps launchers on the iPhone and CarPlay scene.
The app, core, CarPlay sources, project, and configuration are checked for changes
before building; only the hosted test file is overlaid.

```bash
gh workflow run carplay-screenshots.yml --ref codex/app-explainer-website \
  -f capture_mode=results
gh run download <run-id> -n carplay-captures -D /tmp/nextstop-result-screenshots
node website/scripts/import-result-screenshots.mjs \
  /tmp/nextstop-result-screenshots <full-main-commit-sha>
```

The runner captures original internal/external Simulator PNGs after a bounded
file handshake with the hosted test. It validates visible text and requires all
eight screens and a passing test. `result-capture-source.json` records the source
and harness commits, image hashes, real MapKit lookup evidence, example values,
and each screen's owning app. Review the images before adding gallery entries.
Charging-point counts and power are illustrative; availability remains unknown.
The current UI selects a restaurant or charging location/provider, not an
individual EVSE or connector.

### iOS app

```bash
xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStopApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  test
```

Replace the simulator name with one installed by the selected Xcode version. The
app requires an Xcode 26 SDK to compile its current MapKit compatibility adapter
while retaining the accepted iOS 18 deployment target.

MapKit deprecated `MKMapItem.placemark` in iOS 26 when it introduced the modern
`location` and `address` properties. The adapter uses the modern API on iOS 26+
and keeps the old call isolated behind an availability branch solely for devices
running the still-supported iOS 18–25 versions.

### iPhone UI tests and screenshots

Run only the UI bundle from the repository root:

```bash
xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStopApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:NextStopAppUITests \
  -resultBundlePath UITestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test

xcrun xcresulttool export attachments \
  --path UITestResults.xcresult \
  --output-path UITestAttachments
```

Choose a new result bundle path on later runs; Xcode will not overwrite an
existing bundle. The tests launch the app with isolated synthetic fixtures that
are compiled only for Debug Simulator builds. They use injected report services
and local state instead of staging, App Attest, location access, or the Simulator
authentication broker. Normal launches keep using the real application services.
The test controls are absent from physical-device and Release/TestFlight builds.
The exact opt-in is `--ui-testing` plus `NEXTSTOP_UI_TEST_SCENARIO` set to `empty`,
`logs-success`, `logs-retry`, or `profile-editor`; unknown scenarios fail before
opening normal stores or creating production clients. Each launch has its own
temporary report stores and in-memory profiles. The retry fixture checks the selected payload and
requires the unchanged request, including its deletion proof, on the second send.

The UI tests cover the empty-log explanation and recording settings, optional
attachments and their exact preview, privacy information, failed send and retry,
success reset, withdrawal, and clearing a previously selected attachment when
local logs are deleted. A second visual configuration uses dark appearance and
the largest accessibility text size. `NEXTSTOP_UI_TEST_APPEARANCE=light|dark`
sets the test root's preferred color scheme explicitly; an omitted value inherits
the system setting, and an unknown value is rejected. Review the exported screenshots to confirm
the rendered appearance and layout; no real backend upload occurs in these tests.
Full Xcode and an installed iOS Simulator runtime are required to execute this
suite; parsing or typechecking its Swift sources does not execute UI tests.

The `profile-editor` fixture seeds one synthetic in-memory profile. Its UI
regression opens the real editor without pre-focusing the name field, taps once
in the right, top, and bottom padding of the full input area, and verifies that
typing works. Each edit is saved and reopened to check persistence within the
test session. Screenshots preserve the focused states. The test performs no
destination lookup, location request, or navigation.

### Backend

```bash
cd backend
npm ci
npm run lint
npm run typecheck
npm run build
npm test
npm run test:integration
npm run refresh:osm
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
informational availability behavior, GiST index use, automatic authority-feed refresh,
Swiss live-status joins, atomic publication, and stable pagination across
projection changes.

With `DATABASE_URL` configured, run pending migrations explicitly and start the
search API and provider worker as separate processes. Physical-device App Attest
also uses the separately started authentication service described below. The
worker immediately discovers and downloads the current official
Bundesnetzagentur CSV, downloads Swiss static data, publishes the combined
projection, and refreshes Swiss live availability every minute. Neither HTTP
service runs migrations or ingestion. The manual import command remains a
recovery tool documented in
[`docs/operations/bundesnetzagentur-import.md`](operations/bundesnetzagentur-import.md).

```bash
npm run db:migrate
npm run dev
npm run dev:worker
```

With `OSM_INGESTION_ENABLED=true` (the default), a separate daily job downloads
the configured Geofabrik OSM PBF extracts, keeps them in `OSM_CACHE_DIRECTORY`,
and publishes supported restaurant POIs atomically. Default coverage is Germany
and Switzerland. The first Germany download is several gigabytes and the streaming
import reads the PBF more than once; allow substantial disk space and time. Later
runs send ETag/Last-Modified validators and reuse unchanged cached files.
Production should run this resource-heavy job in one designated process.
`npm run refresh:osm` is the manual recovery/validation command.

### Search authentication on a physical device

Supported physical devices use Apple App Attest; there is no manually configured
or static search token in the app. Debug device builds request a development
attestation and Release/TestFlight builds request a production attestation. The
app retains the App Attest key identifier, lifecycle, and a transient pending
attestation challenge in a non-synchronizing, device-only Keychain item. An Apple
`serverUnavailable` retry reuses that exact key and client-data hash; other
attestation failures discard the key with at most one immediate replacement
attempt. The iPhone and CarPlay scenes share one injected authentication
coordinator. Server-issued search access tokens remain only in memory. A challenge
is single use and valid for three minutes; an access token is valid for 15 minutes
and is refreshed with a 60-second margin. The backend stores only a hash of the key
identifier plus the verification material and replay counter; inactive or revoked
key records are purged after 90 days.

Before a physical-device exchange can succeed, enable App Attest for the App ID
`de.nextstop.app`, refresh the matching provisioning profile, and set the staging
backend's `APP_ATTEST_APP_ID` to the exact full App ID:

```text
<exact App ID prefix>.de.nextstop.app
```

The App ID prefix is an external Apple Developer value and must not be inferred
from the Team ID. Until it is known and configured, the App Attest endpoints
intentionally return `503`; this remains an external activation blocker. Set
`APP_ATTEST_ALLOW_DEVELOPMENT=true` only for the bounded development-signed device
check. The verifier accepts Apple's current sandbox AAGUID and the legacy
development AAGUID only while that flag is enabled. Setting it back to `false`
rejects both new development attestations and assertions from development keys
registered earlier; production keys remain valid. TestFlight/App Store
attestations use the production environment. Neither path is testable in the iOS
Simulator.

Set `APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS` to the comma-separated, whitespace-free
allowlist of shipped `CFBundleVersion` values (currently `1`). Add a new build
number before distributing that build; keep still-supported older build numbers
during the rollout. For iOS 27 proofs, Apple's validation category and bundle
version extensions must either both be present or both be absent. When present,
every attestation and assertion is checked independently: category `3` is allowed
only for a development key, categories `2` (TestFlight) and `4` (App Store) only
for a production key, and the build must be in the server allowlist. Absence is
the accepted legacy pre-iOS-27 proof shape. The assertion values need not equal
the initial attestation values, so a legitimate allowlisted app update can keep
using its existing key.

### Connected Debug Simulator search through staging

The checked-in Debug configuration targets `https://api.nextstop.tech`. Nginx on
that origin routes only `/v1/auth/app-attest/*` to the isolated authentication
service on VM loopback port `3001`; health and candidate search go to the
read-only search API on VM loopback port `3000`. Because
Apple reports App Attest as unsupported in the Simulator, only a
`DEBUG && targetEnvironment(simulator)` build may fall back to the loopback Mac
broker. Release builds do not compile this fallback and fail closed when App
Attest is unavailable.

Install the Google Cloud CLI, authenticate the developer account, and ensure it
has IAP/SSH access to the `nextstop-tech-staging` VM. Then run from the repository
root and keep the process open while using the Simulator:

```bash
gcloud auth login
ios/start-simulator-auth-broker.sh
```

The broker binds only to `127.0.0.1:9482`. It uses `gcloud compute ssh` with
`--tunnel-through-iap` to invoke the VM's non-HTTP development-token mint command,
implemented as the isolated `simulator-token-mint` service. That one-shot container
receives only the token signing key, has no network, uses a read-only filesystem,
drops Linux capabilities, and does not persist stdout through a container logging
driver. The broker caches the resulting 15-minute token in memory and refreshes it
one minute before expiry. The Simulator sends an empty `POST /token` with
`X-NextStop-Simulator-Auth: 1`; the broker returns the normal access-token JSON
shape. The developer never copies a bearer or signing key into Xcode, a file, or
the app.

The defaults may be overridden before starting the broker with
`NEXTSTOP_GCP_PROJECT`, `NEXTSTOP_GCP_ZONE`, `NEXTSTOP_GCP_INSTANCE`, and
`NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT`. A Debug Simulator may override
`NEXTSTOP_DEBUG_SIMULATOR_TOKEN_BROKER_URL`, but the app accepts only an `http`
URL on `127.0.0.1` or `::1` whose path is exactly `/token`; user info, query, and
fragment are rejected. Staging is the default broker mode.
The Debug Simulator client allows the broker up to 95 seconds to complete a
credential refresh because the staging SSH mint itself can take up to 90 seconds.

### Debug Simulator search against a local backend

For deliberate local backend development, set the Xcode scheme environment
variable `NEXTSTOP_API_BASE_URL` to `http://127.0.0.1:3000`. Build the backend,
apply migrations, and then start the populated search API with a local signing
key of at least 32 non-whitespace bytes:

```bash
cd backend
DATABASE_URL=postgresql://127.0.0.1/nextstop \
SNAPSHOT_SIGNING_KEY=replace-with-at-least-32-random-bytes \
npm run db:migrate
npm run build
```

Start these long-running processes in separate terminals:

```bash
cd backend

DATABASE_URL=postgresql://127.0.0.1/nextstop \
SNAPSHOT_SIGNING_KEY=replace-with-at-least-32-random-bytes \
SEARCH_ACCESS_TOKEN_SIGNING_KEY=local-development-signing-key-00000000000 \
npm run dev
```

```bash
cd backend
DATABASE_URL=postgresql://127.0.0.1/nextstop npm run dev:worker
```

In a separate terminal, start the same loopback broker in local mode with the
identical signing key:

```bash
NEXTSTOP_SIMULATOR_AUTH_MODE=local \
SEARCH_ACCESS_TOKEN_SIGNING_KEY=local-development-signing-key-00000000000 \
ios/start-simulator-auth-broker.sh
```

Local mode executes the built token-minting job directly and still gives the app
only a 15-minute memory credential. It does not require `gcloud`, App Attest, a
legacy bearer, or a manually synchronized Xcode secret. Only staging/production
require distinct restricted database credentials; staging uses the separate
`nextstop_api`, `nextstop_auth`, and `nextstop_worker` roles.

To exercise App Attest from a physical device against a local deployment, expose
a trusted TLS reverse proxy and route only `/v1/auth/app-attest/*` to a separately
started auth process on port `3001`; keep candidate search on port `3000`. In
another terminal, supply the exact external App ID prefix rather than the literal
placeholder:

```bash
cd backend
AUTH_DATABASE_URL=postgresql://127.0.0.1/nextstop \
SEARCH_ACCESS_TOKEN_SIGNING_KEY=local-development-signing-key-00000000000 \
APP_ATTEST_APP_ID='<exact App ID prefix>.de.nextstop.app' \
APP_ATTEST_ALLOW_DEVELOPMENT=true \
APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS=1 \
HOST=127.0.0.1 \
PORT=3001 \
npm run start:auth
```

Do not expose port `3001` directly. The TLS proxy is the single client-facing
origin for both services.

No charging or restaurant rows need to be entered manually. `GET /health` reports process
liveness immediately; candidate search honestly returns `503` until the first
background projection has published. The first real import downloads roughly
80 MB of charging source data before decompression; the independent first OSM
import is much larger and can take considerably longer.

If Xcode and a development backend run on different Macs, set
`NEXTSTOP_API_BASE_URL` to that backend's reachable base URL and start the server
with an explicitly appropriate `HOST`. Use this only on a trusted local network;
the token broker must still be loopback-local to the Simulator Mac. The checked-in
Debug and Release configurations always use the TLS-protected staging service.

Tap “Suche starten” for a profile. The app calculates
the MapKit route and then starts the charging-park search automatically as one
flow. It fetches a stable PostGIS candidate snapshot, asks MapKit for actual
automobile distance to candidates in bounded groups of four, applies the exact
configured range after the backend's exact optional 500 m OSM food rule, sorts only
by actual driving distance, and displays at most five. Each result shows the
deduplicated EVSE count for every operator. Its compact row shows the charger icon
and count without repeating the already-visible power criterion. The 48-point Maps
button beside an operator or restaurant lazily performs a bounded Apple lookup and
opens the native place by stable Place ID. Navigation may be started from that
native place card; the iPhone result card has no duplicate navigation button.

### CarPlay acceptance gate

The app already declares the EV-charging capability and CarPlay scene. The
website-branch capture job builds unchanged `main` with simulator ad-hoc signing
and verifies `com.apple.developer.carplay-charging` in the executable's
`__TEXT,__entitlements` section. An empty `codesign` entitlement dictionary alone
does not show that simulator entitlements are missing. An opt-in hosted app test
seeds a persistent example profile through the unchanged SwiftData repository,
because CarPlay does not read the iPhone UI tests' in-memory store. This fixture
does not start a charging search or navigation and rejects a nonempty store.

Before testing on a device or distributing a build, verify Apple's approval and
matching provisioning for `de.nextstop.app`; simulator success does not establish
either. Do not add or sign an unapproved device capability. Enable the granted
capability for the App ID, refresh signing assets, and run one integrated
acceptance pass:

1. Start PostgreSQL and the backend with ingestion enabled; wait for the initial
   authority projection instead of entering charging rows manually.
2. Launch the iPhone app once, grant precise location, create a profile, and use a
   searched destination so Profile, Favorites, and Recents are populated.
3. Invoke “Plane eine Fahrt mit nextStop” through Siri and confirm that the spoken
   destination opens the same ride preparation with visible default criteria.
4. Connect the CarPlay Simulator and confirm that “Fahrt wählen” lists profiles,
   favorites, and recent destinations. Selecting either a profile or saved
   destination shows “Suche starten”, “Filter ändern”, and all four current
   criteria. Verify direct search, then edit a fixed-choice filter, return through
   the editor/summary, and search from the editor's navigation bar. The changed
   value applies to the ride and leaves the saved profile intact.
5. Search a route, verify at most five distance-sorted system-template results,
   compact driving-distance/EVSE/operator summaries, and each operator's EVSE
   count in the detail/list. Refresh once. Select “Ladeanbieter wählen” and an
   operator, then verify Apple Maps opens that operator's native place, as on
   iPhone. In a food result, “Zum Restaurant” opens the matched restaurant's native
   place. Neither action automatically starts directions or adds a waypoint;
   no-food results have only the operator action. A missing native match must show
   an error without opening a guessed place.
6. While a place lookup is pending, select another POI in the same result template,
   navigate back from the operator list/result screen, start a new ride/search,
   and disconnect/reconnect CarPlay. Each abandoned lookup must be cancelled or
   invalidated; a late result must neither open Maps nor show an error over the
   current screen. Repeat one successful target to verify ride-local cache reuse.
7. Use a Swiss route to verify current `ich-tanke-strom` availability. On German
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
