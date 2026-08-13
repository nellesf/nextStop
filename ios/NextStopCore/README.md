# NextStopCore

Portable Swift 6 domain and application policy for nextStop. This package imports
no SwiftUI, UIKit, CarPlay, MapKit, URLSession, or persistence framework. It can be
opened directly in Xcode through `Package.swift` and later linked into the iOS app
as a local package.

## Implemented

- Central, type-safe option catalog and fixed thresholds.
- Approved defaults for rides without a profile.
- Integer meter/kilowatt value types with decoding validation.
- Charging-park, availability, source, POI, profile, and ride-draft models.
- Three-valued partial/unknown availability policy.
- Exact domain filters for corridor, driving range, EVSE count, power, and food.
- Actual-driving-distance-only ordering and maximum-five result cap.
- Ride-scoped profile copy semantics.

## Test

With a matching Swift compiler and SDK:

```bash
cd ios/NextStopCore
swift test
```

Or open `ios/NextStopCore/Package.swift` in Xcode and choose Product → Test.

On the initial implementation machine, `swift test` is blocked before manifest
compilation because the installed Swift command-line compiler and default macOS SDK
have different build revisions. Formatting and syntax checks pass, and all product
sources typecheck successfully against the installed compatible macOS 15.4 SDK.
The 23 XCTest methods parse successfully, but their first full typecheck and
executed run must happen in Xcode or CI because these Command Line Tools do not
contain a compatible XCTest module.
