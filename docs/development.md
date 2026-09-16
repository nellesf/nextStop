# Local development

## Prerequisites

- A full current Xcode installation with an iOS SDK and CarPlay simulator support
  on the build/test Mac or CI runner. It is not required in the editing VM.
- Swift 6 toolchain (Command Line Tools suffice for local core builds; Xcode is
  used for app builds and XCTest).
- Node.js active LTS and npm for the accepted TypeScript backend.
- PostgreSQL with PostGIS, preferably through a pinned container setup.
- An Apple Developer team. The app core and iPhone UI must work without the final
  EV-charging entitlement; running the CarPlay surface requires Apple's managed
  `com.apple.developer.carplay-charging` capability and matching provisioning.

Observed on 2026-09-16: the editing VM has macOS 27 and Swift 6.4 Command Line
Tools. The unchanged core builds successfully. XCTest, the iOS SDK, and Simulator
are not available here, so app compilation and tests run on the Xcode Mac or CI.
Installing full Xcode in this VM is optional, not an iOS 27 migration requirement.
The existing backend environment remains separate from this platform migration.

For a sandboxed local core build, put compiler caches and output in a writable
temporary directory:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/nextstop-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/nextstop-swift-cache \
swift build --package-path ios/NextStopCore \
  --scratch-path /private/tmp/nextstop-core-build \
  --cache-path /private/tmp/nextstop-spm-cache --disable-sandbox
```

This compiles the portable package; it does not verify SwiftUI, MapKit, CarPlay,
or the iOS tests. `swift format lint` and Swift parser checks are also available
locally.

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
the portable package with explicitly selected Xcode 26.6 and 27.0 toolchains.
`.github/workflows/ios-app.yml` builds the Debug app and runs its unit, CarPlay
presenter, and iPhone UI tests in this matrix:

| Runner | Xcode / SDK | Simulator | Purpose |
| --- | --- | --- | --- |
| `macos-15` | 26.3 / iOS 26.2 | iPhone 16 Pro, iOS 18.6 | Supported iOS 18 runtime regression |
| `macos-26` | 26.6 / iOS 26.5 | iPhone 17 Pro, iOS 26.5 | Existing stable baseline |
| `xcode-27` | 27.0 / iOS 27.0 | iPhone 17 Pro, iOS 27.0 | New SDK/runtime compatibility |

The iOS jobs verify the selected Xcode version and simulator SDK and preserve the
actual build, resolved installation path, Swift version, and runtime inventory in
`toolchain.txt`. As of 2026-09-16, GitHub's published `xcode-27` image still contains
Xcode 27 beta 6 (`27A5252f`). Its tests are preliminary compatibility evidence,
not a final-SDK release qualification. Keep release archives on a verified stable
toolchain per ADR 0001 and repeat the iOS 27 checks with Apple's final Xcode 27
(`27A266a`) before release. The iOS 18 job uses Xcode 26.3; it does not establish
that an Xcode 27 binary runs on iOS 18.0.

Both workflows run for every push and pull request, use read-only repository
permissions, and pin GitHub's checkout action to v7. Each iOS job has a 30-minute
timeout and can also be started manually
from **Actions → iOS App → Run workflow**, selecting `all` or `ui` tests and the
desired branch. A queued GitHub runner does not block local Simulator testing.

Every iOS job uploads its result bundle and toolchain record as
`ios-test-results-ios-18`, `ios-test-results-ios-26`, or `ios-test-results-ios-27`.
Exported test attachments use the corresponding `ios-ui-attachments-ios-*` name,
when present, even after a test failure. Artifacts expire after seven days. Open a workflow run's
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
the external CarPlay display. Actual CarPlay layout still needs the CarPlay
Simulator or a vehicle; the existing CarPlay unit tests verify presenter behavior.

### iOS app

```bash
xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStopApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  test
```

Replace the simulator name with one installed by the selected Xcode version; for
repeatable checks specify its exact OS version as in the CI matrix. The app needs
an iOS 26 or newer SDK for its MapKit adapter and retains the accepted iOS 18.0
deployment target. XcodeGen's `xcodeVersion` metadata is not an SDK pin.

The iOS 27 compatibility change uses SwiftUI's builder-based `overlay` overload
to avoid the modified-`ShapeStyle` overload ambiguity documented in
[Apple TN3211](https://developer.apple.com/documentation/technotes/tn3211-resolving-swiftui-source-incompatibilities-for-state-and-contentbuilder).
The tint and hit-testing behavior are unchanged. The existing launch-screen and
scene declarations already meet the new SDK requirements. Deprecated APIs such as
`FileDocument` remain in place while they support the accepted deployment range.

MapKit deprecated `MKMapItem.placemark` in iOS 26 when it introduced the modern
`location` and `address` properties. The adapter uses the modern API on iOS 26+
and keeps the old call isolated behind an availability branch solely for devices
running the still-supported iOS 18–25 versions.

### iPhone UI tests and screenshots

For native CarPlay captures, display-resolution audits, or website screenshots,
start with the [simulator operations guide](operations/simulator-screenshots.md).
It identifies the existing runner harnesses, safe build reuse, verified display
input methods, known startup failures, and original-artifact import checks.

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
