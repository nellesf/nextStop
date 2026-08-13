# ADR 0001: Minimum iOS version

- Status: Accepted
- Date: 2026-08-13

## Context

The app needs modern SwiftUI, MapKit, App Intents, SwiftData, strict Swift
concurrency, and current CarPlay templates. The deployment target also sets the
support/test matrix and must be sensible in 2026.

## Decision

Set the deployment target to **iOS 18.0**, then compile with the current non-beta
Xcode SDK. Keep the pure Swift core platform-light.

## Alternatives

- iOS 17.0: technically sufficient and broader compatibility, but a longer support
  and regression horizon.
- iOS 26.0: smallest matrix and newest APIs, but unnecessarily excludes many users
  for functionality available earlier.

## Consequences

Modern persistence/intents are available without compatibility branches. Devices
that cannot run iOS 18 cannot use the app. Validate the accepted target against the
installed Xcode SDK and CarPlay provisioning before release.
