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
open ios/NextStopCore/Package.swift
```

Opening the package requires no signing or CarPlay entitlement. Run Product → Test
to validate the core. Once the app project exists, open its checked-in
`NextStop.xcodeproj` instead; it will reference `NextStopCore` as a local package.
Signing, the iOS simulator, MapKit, SwiftData, App Intents, and CarPlay remain
Xcode-only verification steps.

### GitHub verification

`.github/workflows/swift-core.yml` runs `swift format lint` and `swift test` on a
hosted macOS runner for every push and pull request. GitHub's official checkout
action is pinned to the current v7 major and the workflow grants read-only
repository permission.

### iOS app

```bash
xcodebuild \
  -scheme NextStopApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

The exact simulator name must be discovered from the installed Xcode and kept in
CI configuration; it is not yet verified.

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
