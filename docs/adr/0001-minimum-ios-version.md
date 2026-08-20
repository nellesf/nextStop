# ADR 0001: Minimum iOS version

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-20

## Context

The app needs modern SwiftUI, MapKit, App Intents, SwiftData, strict Swift
concurrency, and current CarPlay templates. The deployment target also sets the
support/test matrix and must be sensible in 2026. During private TestFlight design
validation, the owner approved an iOS 26-only interface so the app can adopt the
native Liquid Glass design system without maintaining a second visual language.

## Decision

Set the deployment target to **iOS 26.0** and compile with the current non-beta
Xcode 26 SDK. Use native iOS 26 controls and navigation materials without
presentation fallbacks. Keep the pure Swift core platform-light.

## Alternatives

- iOS 18.0: broader device coverage, but requires compatibility branches and a
  separate pre-Liquid-Glass presentation during the current design phase.
- iOS 17.0: technically sufficient for the original MVP, but creates an even
  longer support and regression horizon.

## Consequences

The app has one native visual and API baseline. Devices that cannot run iOS 26
cannot use the app. Validate the accepted target against the installed Xcode SDK,
TestFlight audience, and CarPlay provisioning before release.
