# Apple platform research

Research date: 2026-08-13. Use primary Apple documentation and re-check before
submission because entitlements, SDK availability, and review rules can change.

## Findings

### Category and entitlement

Apple lists EV charging as a supported CarPlay category. EV-charging apps require
the managed `com.apple.developer.carplay-charging` entitlement; Apple reviews the
request, the developer accepts an addendum, and the App ID/provisioning profile
must contain the capability.

Sources:

- [Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [CarPlay developer overview](https://developer.apple.com/carplay/)
- [`com.apple.developer.carplay-charging`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-charging)

Consequence: build domain, iPhone, backend, and presentation logic without waiting,
but treat actual CarPlay execution/distribution as entitlement-gated.

### Template family

Apple exposes `CPPointOfInterestTemplate` and `CPInformationTemplate` specifically
in the location/information family available to parking, EV-charging, and food
apps. The POI template displays a map, picker, and detail card, manages selection
and map behavior, and supports a maximum of twelve POIs. `CPListTemplate` is the
system list surface and has vehicle-dependent runtime item limits.

Sources:

- [CarPlay framework](https://developer.apple.com/documentation/carplay)
- [`CPPointOfInterestTemplate`](https://developer.apple.com/documentation/carplay/cppointofinteresttemplate)
- [`CPPointOfInterest`](https://developer.apple.com/documentation/carplay/cppointofinterest)
- [`CPListTemplate.maximumItemCount`](https://developer.apple.com/documentation/carplay/cplisttemplate/maximumitemcount)
- [`CPInformationTemplate.items`](https://developer.apple.com/documentation/carplay/cpinformationtemplate/items)

Consequence: use list templates for fixed choices and the POI template for the
five results. Do not use the navigation-only `CPMapTemplate` or draw a custom map.

### Human interface guidance

Apple requires system-defined templates and emphasizes quick, minimal interaction,
working while the iPhone is locked, and moving setup to iPhone before driving.

Source: [CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay/).

Consequence: permission/onboarding is iPhone-first; the CarPlay UI is a ride summary
plus only the fixed lists the driver chooses to modify.

### Routing and Maps handoff

`MKRoute` supplies the complete detailed route polyline and distance. `MKMapItem`
can be opened in Apple Maps. The app can therefore calculate the destination route,
send exact route geometry for corridor search, calculate a separate automobile
route to each candidate, and hand the selected map item to Maps.

Sources:

- [`MKRoute`](https://developer.apple.com/documentation/mapkit/mkroute)
- [`MKRoute.polyline`](https://developer.apple.com/documentation/mapkit/mkroute/polyline)
- [`MKMapItem`](https://developer.apple.com/documentation/mapkit/mkmapitem)

Consequence: actual candidate driving distance comes from the candidate's MapKit
route distance, never from straight-line distance or PostGIS route progress.

### Destination and POI search

`MKLocalSearch.Request` accepts natural-language search and can be constrained to a
region and POI categories. Search returns `MKMapItem` values. Apple's public
`MKMapItem` attribute list exposes name, location/address, phone, URL, and category,
but not a stable programmatic opening-state property. Apple's system place detail
UI can display business hours, which does not make those hours available as a
search/filter value to this app.

Sources:

- [`MKLocalSearch.Request`](https://developer.apple.com/documentation/mapkit/mklocalsearch/request)
- [Interacting with nearby points of interest](https://developer.apple.com/documentation/mapkit/interacting-with-nearby-points-of-interest)
- [`MKMapItem`](https://developer.apple.com/documentation/mapkit/mkmapitem)

Consequence: MapKit is sufficient for an MVP named-chain proximity check after the
app verifies <=500 m itself. Omit opening status unless a later provider supplies a
reliable explicit value.

### Siri / App Intents

The App Intents framework exposes app actions and parameters to Siri and Shortcuts.

Sources:

- [`AppIntent`](https://developer.apple.com/documentation/appintents/appintent)
- [App intents](https://developer.apple.com/documentation/appintents/app-intents)

Consequence: implement a focused intent and use Siri's existing recognition. Do
not add a speech service.

### Location authorization

Apple describes When In Use as the preferred authorization because of privacy and
battery impact, and it supports all location services while the app is in use.
Authorization prompts require a foreground iPhone context.

Sources:

- [Requesting authorization to use location services](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)
- [`requestWhenInUseAuthorization`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization())

Consequence: request When In Use during iPhone onboarding, not after CarPlay begins.
Do not request Always/background tracking for a search that intentionally remains
stable.

## Accepted minimum version

iOS 18.0 is accepted as a product support policy rather than the first availability
of the CarPlay templates. It supports the chosen modern SwiftUI, App Intents,
SwiftData, and concurrency baseline while avoiding a three-generation-old minimum
at implementation time. iOS 17.0 is the compatibility alternative. The actual
deployment target must be revalidated in the selected Xcode SDK and entitlement
test before ADR 0001 is accepted.

## Remaining Apple validation

- Obtain entitlement approval criteria/feedback for this exact product.
- Confirm final target/template allow-list with the installed Xcode 26 SDK.
- Test locked-iPhone, knob/non-touch, wide/portrait displays, reduced location
  accuracy, Siri destination resolution, and Apple Maps handoff in CarPlay
  Simulator and at least one real vehicle.
- Re-check App Store Review Guidelines and privacy-manifest requirements at release.
