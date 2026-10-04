# Local development

## Prerequisites

- A full current Xcode installation with an iOS SDK and CarPlay simulator support.
- Swift 6 toolchain (provided by Xcode for app builds).
- Node.js active LTS and npm for the accepted TypeScript backend.
- PostgreSQL with PostGIS, preferably through a pinned container setup.
- An Apple Developer team. The app core and iPhone UI must work without the final
  EV-charging entitlement; running the CarPlay surface requires Apple's managed
  `com.apple.developer.carplay-charging` capability and matching provisioning.

Verified locally on 2026-10-01: Xcode 27.0 (`27A266a`) is active at
`/Applications/Xcode.app/Contents/Developer`, with an iOS 27 iPhone 18 Pro
Simulator. The environment/authentication and report-receipt suites pass in
Debug and Release configurations; the exact commands are recorded below. Node.js
24 LTS and npm are installed. PostgreSQL 17 and PostGIS 3.6 were installed through
Homebrew for isolated backend integration tests; Docker/Podman was not installed
at that earlier check. Check the actual tools before choosing a local workflow.

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
from **Actions → iOS App → Run workflow**, selecting `all` or `ui` tests and the
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

Replace the simulator name with one installed by the selected Xcode version. The
app requires an Xcode 26 SDK to compile its current MapKit compatibility adapter
while retaining the accepted iOS 18 deployment target.

MapKit deprecated `MKMapItem.placemark` in iOS 26 when it introduced the modern
`location` and `address` properties. The adapter uses the modern API on iOS 26+
and keeps the old call isolated behind an availability branch solely for devices
running the still-supported iOS 18–25 versions.

### Backend environments and distribution

All schemes build the same `de.nextstop.app` target and use the existing signing
and CarPlay provisioning. Installing another scheme replaces the same app; local
profiles remain available. Select the backend before launch, without an in-app
switch:

| Scheme | Run configuration | Debug Simulator backend | Archive |
| --- | --- | --- | --- |
| `NextStop-Staging` | Debug | `https://api-staging.nextstop.tech` | Release, production |
| `NextStop-ProductionTest` | Debug | `https://api.nextstop.tech` | Release, production |
| `NextStop-Release` | Release | `https://api.nextstop.tech`; App Attest unavailable in Simulator | Release, production |
| `NextStopApp` | Debug | Production by default; retained for CI and existing workflows | Release, production |

Every physical-device build and every Release build resolves to
`https://api.nextstop.tech`. Launch environment variables and changed API values
in Info.plist cannot redirect these builds. Every checked-in scheme archives
Release, so TestFlight always uses production and excludes Simulator credential
fallbacks. The iPhone and CarPlay clients are created together at startup.

App Attest's `development`/`production` namespace is read from
`NextStopAppAttestEnvironment`, expanded from the same
`NEXTSTOP_APP_ATTEST_ENVIRONMENT` build setting as the entitlement. Debug remains
`development`; Release remains `production`. A physical Debug build may therefore
fail closed against production. Verify real devices with Release/TestFlight; do
not enable development attestations globally on production to make Debug work.

App Attest Keychain state is already scoped by backend origin and signing
environment. Access tokens and candidate snapshots stay in their startup-created
clients. Report withdrawal receipts now use a directory derived from the
canonical backend origin. Existing unscoped receipts belong to the previous
`api.nextstop.tech` service and migrate only to its production namespace. Staging
never adopts them. Migration validates both files and writes the merged scoped
file before removing the old file; conflicts or write failures preserve the
original withdrawal capabilities and fail closed.

### Verified environment regression tests

On 2026-10-01, these targeted commands passed on Xcode 27.0: 28 tests in Staging
Debug and 23 tests in Release. The Release run exercises the compiled production
URL guard and the absence of Debug Simulator fallbacks. The difference in count
is the tests that compile only for Debug Simulator. `ENABLE_TESTABILITY=YES` is a
command-line override for this Release test run only; distribution settings remain
unchanged. These checks do not establish real-device App Attest or CarPlay
provisioning success.

```bash
xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStop-Staging \
  -destination 'platform=iOS Simulator,id=54BA0ED5-91B0-4A52-8ABA-920362698E8A' \
  -derivedDataPath /private/tmp/nextstop-environment-ios-derived \
  -resultBundlePath /private/tmp/nextstop-environment-staging-tests.xcresult \
  -only-testing:NextStopAppTests/AuthenticationTransportTests \
  -only-testing:NextStopAppTests/UserErrorReportReceiptStoreTests \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStop-Release -configuration Release \
  -destination 'platform=iOS Simulator,id=54BA0ED5-91B0-4A52-8ABA-920362698E8A' \
  -derivedDataPath /private/tmp/nextstop-environment-ios-derived \
  -resultBundlePath /private/tmp/nextstop-environment-release-verified-tests.xcresult \
  -only-testing:NextStopAppTests/AuthenticationTransportTests \
  -only-testing:NextStopAppTests/UserErrorReportReceiptStoreTests \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES test

node --test ios/SimulatorAuthBroker/*.test.mjs
```

Use `xcrun simctl list devices available` to choose an installed device ID on
another Mac. Use a new result bundle path when rerunning; Xcode does not overwrite
one. The broker suite passed all eight tests, covering paired presets, rejected
cross-environment overrides, explicit compatibility modes, archive configuration,
and bounded token-cache lifetime.

### Apple charger eligibility regression checks

On 2026-10-02, the portable Core suite passed all 37 tests. The Staging Debug
scheme on the existing iOS 27 iPhone 18 Pro Simulator passed 225 app tests and
53 CarPlay tests; one pre-existing app test was skipped. These suites include
operator pruning and minimum-EVSE rechecks, replacement candidates after the
original top five, complete restaurant groups, retryable Apple lookup failures,
cancellation, and reuse of the checked native place after result pruning.

The app/CarPlay check used:

```bash
xcodebuild \
  -project ios/NextStop.xcodeproj \
  -scheme NextStop-Staging \
  -destination 'platform=iOS Simulator,id=54BA0ED5-91B0-4A52-8ABA-920362698E8A' \
  -derivedDataPath /private/tmp/nextstop-apple-filter-derived \
  -resultBundlePath /private/tmp/nextstop-apple-filter-tests-2.xcresult \
  -only-testing:NextStopAppTests \
  -only-testing:NextStopCarPlayTests \
  CODE_SIGNING_ALLOWED=NO test
```

Apple search responses in these regression tests are synthetic. Passing tests do
not establish current Apple catalog coverage, search latency, real-device handoff
or TestFlight distribution. Use a fresh result bundle path for a repeat run.

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

The opt-in staging policy is described in [ADR 0019](adr/0019-demand-driven-staging-ingestion.md).
Set `INGESTION_SCHEDULE=monthly` and `DEMAND_LIVE_AVAILABILITY_ENABLED=true` only
with the matching release and private worker configuration. Existing defaults
remain daily/minute polling for production compatibility. Monthly due dates are
persisted; an existing corpus is first due on the next month's first day at
02:00 UTC. The private refresh endpoint requires `LIVE_REFRESH_TOKEN` on API and
worker, and `LIVE_REFRESH_URL=http://worker:8091/refresh` on the API. Do not publish
the worker port. Simulator builds receive the optional availability capability
from staging; no app-wide environment switch or production rollout is implied.

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
`de.nextstop.app`, refresh the matching provisioning profile, and configure the
production backend's `APP_ATTEST_APP_ID` with the exact full App ID:

```text
<exact App ID prefix>.de.nextstop.app
```

The App ID prefix is an external Apple Developer value and must not be inferred
from the Team ID. Until it is known and configured, the App Attest endpoints
intentionally return `503`. Production keeps
`APP_ATTEST_ALLOW_DEVELOPMENT=false`: it rejects both new development attestations
and assertions from development keys registered earlier. Release/TestFlight
verification requires matching production signing and provisioning. The backend
still supports a bounded development verifier for isolated testing, but the app's
physical-device guard does not route that app to staging or a local origin.
Apple App Attest itself is unavailable in the iOS Simulator.

Build numbers are not an authentication allowlist. A new TestFlight or App Store
build requires no backend build registration, configuration update, or App Store
Connect webhook. For iOS 27 proofs, Apple's signed validation category and bundle
version extensions must either both be present or both be absent. When present,
every attestation and assertion is checked independently: category `3` is allowed
only for a development key, and categories `2` (TestFlight) and `4` (App Store)
only for a production key. The bundle version remains validated metadata: a
string of 1–64 ASCII letters, digits, dots, underscores or hyphens, without
exact-value membership checks.
Absence is the accepted legacy pre-iOS-27 proof shape. The assertion values need
not equal the initial attestation values, so an app update can keep using its
existing key. Full App ID, signing environment, signature, challenge binding and
replay-counter checks still apply.

For each TestFlight release:

1. Read the actual `CFBundleVersion` from the archive or TestFlight build details.
   The project's `CURRENT_PROJECT_VERSION` default is not evidence of the
   distributed build number.
2. Run synthetic verifier coverage for malformed validation metadata, signing
   environments and categories, and valid assertions from an existing key after
   a build-number change.
3. Before broader distribution, verify the actual production-signed TestFlight
   build on a physical device: successful challenge/attestation, a later
   challenge/assertion exchange, and authenticated candidate search. Readiness
   checks and Simulator token-broker searches do not prove device App Attest.

### Connected Debug Simulator search

Only `DEBUG && targetEnvironment(simulator)` builds can obtain a credential from
the loopback Mac broker. The named scheme preset pairs the API and broker; a
conflicting API or broker override fails configuration instead of silently mixing
environments. Release builds omit this fallback and fail closed when App Attest
is unavailable.

Install the Google Cloud CLI, authenticate the developer account with
`gcloud auth login`. Staging requires Cloud Run service metadata access and
`run.invoker` on its private Simulator token service; production requires its
existing IAP/SSH access.
From the repository root, start the corresponding broker and keep it running:

```bash
# Use with the NextStop-Staging scheme.
NEXTSTOP_BACKEND_ENVIRONMENT=staging ios/start-simulator-auth-broker.sh

# Use with NextStop-ProductionTest or the default NextStopApp scheme.
NEXTSTOP_BACKEND_ENVIRONMENT=production ios/start-simulator-auth-broker.sh
```

| Preset | Loopback port | Google Cloud project | Token service | Region / zone |
| --- | --- | --- | --- | --- |
| `staging` | 8765 | `nextstop-tech-testing` | Cloud Run `nextstop-broker` | `europe-west1` |
| `production` (default) | 8766 | `nextstop-tech-staging` | `nextstop-backend` | `europe-west3-a` |

The production project retains its historical `nextstop-tech-staging` ID and the
existing VM/database; its name does not describe its current role. The new
`nextstop-tech-testing` project hosts isolated staging. This initial split adds
no production database migration or production redundancy. The central image
registry remains in `nextstop-tech-staging`, independently of staging compute.

Both brokers may run simultaneously. Named presets reject cloud-target and port
overrides that disagree with this table. A preset describes the intended target;
its service and access permissions must have been provisioned before a connected
search can succeed.

The broker binds only to `127.0.0.1`. Staging describes the fixed Cloud Run broker,
gets the developer's Google identity token, and invokes its IAM-protected
`POST /token`. Credentials remain in memory; the backend signing key is never
copied to the Mac. During the VM-to-Cloud-Run migration only, explicitly set
`NEXTSTOP_STAGING_HOSTING=vm` with the named staging preset to use its old IAP
minter while the new runtime is being verified. Remove this override after
cutover. This option cannot redirect the production preset.

The production broker uses `gcloud compute ssh` with
`--tunnel-through-iap` to invoke
`sudo /usr/local/sbin/nextstop-mint-simulator-token` without arguments. Release
installation supplies this stable host command; it starts the selected immutable
backend image as a one-shot container with no network, a read-only filesystem,
dropped Linux capabilities, and no persisted container stdout. It receives only
the search-token signing key. Neither the signing key nor a manually copied bearer
is configured in Xcode or bundled with the app.

The broker caches the 15-minute token only in memory, deducts mint latency, and
refreshes one minute before expiry. The Simulator sends an empty `POST /token`
with `X-NextStop-Simulator-Auth: 1`; the response is the usual access-token JSON.
The Simulator permits 95 seconds for refresh because IAP/SSH minting has a
90-second timeout.

**Production verified 2026-10-02:** the production release installed the stable
helper. The named `production` recipe above minted a token and completed one
synthetic public search with HTTP 200, valid candidates and a snapshot. Tokens
stayed in memory; the temporary broker stopped and released port 8766. Use this
named recipe with `NextStop-ProductionTest` or the default `NextStopApp` scheme,
without API or broker URL overrides. This verifies broker/API connectivity, not a
full Simulator UI session or real-device App Attest continuity. See the
[production verification record](operations/production-release-verification-2026-10-02.md).

**Historical compatibility option for hosts not yet adopted by the release
runner:** before the stable helper is installed, the old production compose
minter can use the explicit compatibility mode below on port 8766. This is no
longer the normal setup for the current production host:

```bash
env -u NEXTSTOP_BACKEND_ENVIRONMENT \
  -u NEXTSTOP_GCP_PROJECT -u NEXTSTOP_GCP_INSTANCE -u NEXTSTOP_GCP_ZONE \
  NEXTSTOP_SIMULATOR_AUTH_MODE=staging \
  NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND=true \
  NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT=8766 \
  ios/start-simulator-auth-broker.sh
```

Run the `NextStop-ProductionTest` scheme with its checked-in
`NEXTSTOP_BACKEND_ENVIRONMENT=production` launch setting and no API or broker URL
override. The compatibility variables above belong only to the Mac broker
process. Its historical `staging` mode name selects the existing production VM
in `nextstop-tech-staging`; the app remains paired with `api.nextstop.tech` and
loopback port 8766. This uses the existing minter and does not install or update
production services.

On 2026-10-01, both this production recipe and the named staging recipe passed a
real token mint followed by exactly one synthetic search against their public
API. Each search returned HTTP 200 with a snapshot; tokens stayed in memory and
both temporary brokers were stopped with their ports released. These checks
verified the broker/API connection, not the full Simulator app interaction.

For an unadopted host without the stable helper, the historical compose minter
also retains its original port 9482 recipe:

```bash
NEXTSTOP_SIMULATOR_AUTH_MODE=staging \
NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND=true \
ios/start-simulator-auth-broker.sh
```

This compatibility mode retains the historical `nextstop-tech-staging` project,
`nextstop-backend` VM, and port 9482. That existing service is now production;
the legacy mode name does not select the new staging project. Use the
`NextStopApp` scheme without `NEXTSTOP_BACKEND_ENVIRONMENT`, and explicitly set
`NEXTSTOP_API_BASE_URL` to the origin still served by that old deployment plus
`NEXTSTOP_DEBUG_SIMULATOR_TOKEN_BROKER_URL=http://127.0.0.1:9482/token`.
The API override accepts only the known staging/production origins or HTTP
loopback; use the actual pre-cutover origin. Remove these compatibility settings
when adopting a named preset. An explicit broker override must be HTTP loopback
(`127.0.0.1` or `::1`) with exactly `/token`, and without user info, query, or
fragment. Do not combine legacy mode and a named backend preset in the same
broker process.

### Debug Simulator search against a local backend

For deliberate local backend development, use the `NextStopApp` Debug scheme,
remove any `NEXTSTOP_BACKEND_ENVIRONMENT` variable, and set
`NEXTSTOP_API_BASE_URL=http://127.0.0.1:3000`. The app pairs this with the local
broker on port 9482. Build the backend,
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

Physical-device builds cannot target a local deployment. Exercise auth transport
and verifier behavior through the automated tests; use production-signed
Release/TestFlight builds for actual-device App Attest verification.

No charging or restaurant rows need to be entered manually. `GET /health` reports process
liveness immediately; candidate search honestly returns `503` until the first
background projection has published. The first real import downloads roughly
80 MB of charging source data before decompression; the independent first OSM
import is much larger and can take considerably longer.

If the development backend runs on another Mac, forward its port to the
Simulator Mac's loopback and keep the API override on `127.0.0.1` or `::1`.
Arbitrary remote hosts are rejected. The token broker must also remain local to
the Simulator Mac. Never use local example signing keys for a hosted environment.

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
