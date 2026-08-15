# CarPlay architecture and screen flow

Status: Accepted on 2026-08-13.

## Entitlement boundary

The app category is EV Charging and requires Apple's managed
`com.apple.developer.carplay-charging` entitlement, an approved App ID capability,
matching provisioning, and the CarPlay entitlement addendum. Requesting and
receiving it is an external prerequisite, not something code can bypass.

Build configurations keep `NextStopCore`, the iPhone app, routing/search services,
presentation models, and scene adapter buildable without the capability. The
scene configuration is present in the app manifest, while the managed entitlement
file is intentionally not fabricated or checked into an unapproved signing setup.

## Template selection

- `CPListTemplate`: profile/destination sources, ride summary, each fixed-choice
  filter, recent/favorite lists, and explicit relaxation choices.
- `CPPointOfInterestTemplate`: final maximum-five map + scrollable result picker.
- `CPInformationTemplate`: optional focused charging-park detail view.
- `CPAlertTemplate`: concise no-results and actionable error states when suitable.

Do not use `CPMapTemplate`, `CPSearchTemplate`, or custom map drawing: those are
navigation-oriented and the app does not navigate. The POI template is explicitly
available to EV-charging apps and supports up to twelve POIs; product logic caps
the list at five.

## Screen flow

```text
Root list
  +-- Saved profile -----------------------------+
  +-- Destination                                |
      +-- Siri / App Intent                      |
      +-- Recent                                 |
      +-- Favorites                              |
                                                   v
Ride summary (ride-scoped copy)
  Destination
  Charging stop range -> fixed-choice list
  Minimum EVSEs      -> fixed-choice list
  Minimum available  -> fixed-choice list
  Minimum power      -> fixed-choice list
  Fast food          -> fixed-choice list
  [Search]
      |
      v
Template-native loading -> POI results (0...5)
      |                         |
      | no results              +-- select park -> detail card/template
      v                                              |
Explicit relaxation list                            v
(one user-selected change)                    [Start navigation]
                                                   |
                                                   v
                                              Apple Maps
```

Selecting a profile creates a `RideSearchDraft`; all subsequent CarPlay changes
modify only that draft. There is no “save profile” action in CarPlay.

## Result content

Keep picker text scan-friendly and let the detail card carry secondary facts:

```text
Köschinger Forst
124 km · 2 km von der Route
20 Ladepunkte · 11 frei · bis 350 kW
McDonald's · 240 m
```

If availability is incomplete, never print a fully known-looking count. Use
localized variants such as “Verfügbarkeit unbekannt” or “mind. 3 frei · teilweise
unbekannt”. Opening status is added only from reliable explicit data.

## Siri / App Intents

The implemented foreground App Intent accepts a destination phrase. Siri/system
services perform speech recognition, MapKit resolves the phrase on the iPhone,
and an injected ride router opens the same default-criteria ride preparation used
by other destination entry points. No custom microphone or speech-to-text stack is
in scope. A saved profile entity remains an optional future Siri parameter; it is
not required for the destination-phrase MVP path.

## Driving safety behavior

- Obtain location permission and other one-time setup in the iPhone app before
  driving; CarPlay never depends on an iPhone prompt while active.
- Use system templates, fixed lists, short labels, and runtime template item limits.
- No free numeric entry, drag controls, custom keyboard, modal onboarding, or
  automatically jumping/re-ranked result list.
- Preserve the draft and a stable result snapshot across recoverable errors.
- Manual refresh is explicit.

## Entitlement-independent tests

- Presenter converts every domain state into abstract list/POI/detail models.
- Snapshot tests verify German localization keys and unknown/partial states.
- Flow coordinator tests profile copying, ride-only mutation, no-result relaxation,
  cancellation, and Maps handoff requests.
- The actual CarPlay adapter is covered by small mapping tests and manual CarPlay
  Simulator runs once entitlement/provisioning and full Xcode are available.

## Implemented adapter flow

The app-binary CarPlay scene reads the same local SwiftData profiles, favorites,
and recent destinations as the iPhone UI. Selecting a profile creates a value-copy
ride draft; selecting a saved destination creates a draft from the central
defaults. Each criterion opens only its centrally defined fixed options. Search
delegates to the same location, MapKit route, signed backend candidate, exact
MapKit distance, food check, filtering, and distance-only ranking components as
the iPhone flow.

Results use `CPPointOfInterestTemplate`; its picker and map receive the same stable
zero-to-five result snapshot. Partial or unavailable live coverage remains visible
in detail text, a manual refresh creates a new snapshot, and panning never changes
or re-ranks the result. No-results keeps all five criteria available for an
explicit user change. The primary POI action sends the park to Apple Maps.

CarPlay performs a location-readiness preflight and never triggers first-time or
reduced-accuracy permission UI while driving. Missing setup is explained on the
CarPlay screen and must be completed in the iPhone app.
