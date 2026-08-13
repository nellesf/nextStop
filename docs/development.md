# Local development

## Prerequisites

- A full current Xcode installation with an iOS SDK and CarPlay simulator support.
- Swift 6 toolchain (provided by Xcode for app builds).
- Node.js active LTS and npm for the accepted TypeScript backend.
- PostgreSQL with PostGIS, preferably through a pinned container setup.
- An Apple Developer team. The app core and iPhone UI must work without the final
  EV-charging entitlement; running the CarPlay surface requires Apple's managed
  `com.apple.developer.carplay-charging` capability and matching provisioning.

Observed on 2026-08-13: this machine has Swift 6.3 command-line tools, but the
active developer directory is Command Line Tools rather than full Xcode. The local
Swift compiler and macOS SDK also have different build revisions, so `swift test`
cannot compile the package manifest here. Node.js, npm, PostgreSQL client tools,
and Docker/Podman are not installed.

As a local fallback, all core product sources typecheck successfully against the
compatible macOS 15.4 SDK, all 23 XCTest methods pass the Swift parser, and Swift
format lint passes. These Command Line Tools do not contain a compatible XCTest
module, so test typechecking and execution must happen on the Xcode Mac or in CI.

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
team only when installing on a device; simulator tests need no CarPlay entitlement.
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
npm test
npm run test:integration
npm run dev
```

Integration tests should start an isolated PostGIS database, apply migrations,
load small deterministic fixtures, and tear it down without touching developer
data.

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
