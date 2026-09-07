# CarPlay architecture and screen flow

Status: Accepted on 2026-08-13; ride flow and native-place handoff amended with
owner approval on 2026-09-07.

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
  filter, operator selection, recent/favorite lists, and explicit relaxation
  choices.
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
  Destination + compact summary of all four current criteria
  [Search] -----------------------------------------+
  [Edit filters]                                    |
      |                                            |
      v                                            |
  Filter editor                                    |
    Charging stop range -> fixed-choice list        |
    Minimum EVSEs       -> fixed-choice list        |
    Minimum power       -> fixed-choice list        |
    Fast food           -> fixed-choice list        |
    [Search] in navigation bar ---------------------+
                                                   v
                         Template-native loading -> POI results (0...5)
                               |                         |
                               | no results              +-- select result
                               v                              |
                         Explicit relaxation list             v
                         (one user-selected change)       POI detail card
                                                              |
                                    +-------------------------+----------------+
                                    v                                          v
                           [Choose operator]                        [To restaurant]
                                    |                               (food match only)
                                    v                                          |
                           Native operator list                                |
                           Name + qualifying EVSE count                        |
                                    | select operator                          |
                                    +-------------------+----------------------+
                                                        v
                                            Resolve selected native place
                                                        |
                                                        v
                                            Apple Maps native place card
```

Selecting a profile creates a `RideSearchDraft`; all subsequent CarPlay changes
modify only that draft. Selecting a saved destination uses the central defaults.
The summary offers “Suche starten” and “Filter ändern” immediately and shows the
distance range, minimum EVSEs, minimum power, and food choice before search. There
is no “save profile” action in CarPlay. Returning from a fixed-choice list updates
the editor and summary; the editor's search action avoids scrolling past criteria.

## Result content

Keep picker text scan-friendly and let the detail card carry secondary facts.

Use the same “Passende Ladestopps” title and result identities as iPhone. The POI
picker shows the restaurant or campus name, actual driving distance and total
qualifying EVSEs, then a short operator-name overview. If names exceed the compact
overview, summarize the remaining operators and retain every operator in the
selection list. Counts describe the restaurant group or campus, not one charger
coordinate. Route-corridor distance and minimum power do not compete for space in
the picker.

The detail card keeps the actual driving-distance label, qualifying EVSE total,
each exact operator name with its aggregated count, and applied minimum power.
Known availability, incomplete/stale coverage, food information, and source
attribution remain in the appropriate detail text. CarPlay owns fonts, spacing,
truncation, and touch/knob layout; visual mockups illustrate content and flow, not
a custom vehicle UI.

If availability is incomplete, never print a fully known-looking count. Use a
localized variant such as “mind. 3 frei · teilweise unbekannt”. When every EVSE has
unknown availability, omit the redundant unknown status line. Opening status is
added only from reliable explicit data.

## Apple Maps actions

The primary POI detail action, “Ladeanbieter wählen”, opens a `CPListTemplate` with
one row per exact operator name and its qualifying EVSE total. Selecting a row
resolves only that operator inside the selected restaurant group or no-food
campus. It uses the same bounded Apple-place matcher, evidence, and ride-local
cache as iPhone, then calls the existing native-place opening interface.

“Zum Restaurant” is the second POI action only when that result has a matched
restaurant. It resolves and opens the selected native Apple restaurant just like
the iPhone restaurant button. Both paths open Apple Maps at the native place;
the user starts navigation there. They do not automatically start directions or
insert the restaurant as a waypoint before the original destination.

If no unambiguous native place is found, show a localized error and keep the
current result. Never substitute a guessed coordinate, another operator, the
campus, or the restaurant for the selected item. Apple enrichment cannot change
candidate inclusion, EVSE counts, grouping, displayed driving distance, or result
order. ADR 0010 retains the exact matching policies and records this handoff
amendment.

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
- Cancel pending place resolution on a new ride/search, another place action, or
  scene disconnect. Before opening Maps or reporting an error, also verify that
  the original source screen and selected POI are still current.

## Entitlement-independent tests

- Presenter converts every domain state into abstract list/POI/detail models.
- Snapshot tests verify German localization keys and unknown/partial states.
- Flow coordinator tests profile copying, visible current criteria, direct search,
  ride-only filter editing, no-result relaxation, cancellation, and Maps handoff
  requests.
- Operator/restaurant resolution tests verify exact group scope, native-place
  cache reuse, errors without guessed fallback, and stale-completion rejection.
- The actual CarPlay adapter is covered by small mapping tests and manual CarPlay
  Simulator runs once entitlement/provisioning and full Xcode are available.

## Implemented adapter flow

The app-binary CarPlay scene reads the same local SwiftData profiles, favorites,
and recent destinations as the iPhone UI. Selecting a profile creates a value-copy
ride draft; selecting a saved destination creates a draft from the central
defaults. The summary exposes separate search/edit actions; the filter editor
opens only centrally defined fixed options and keeps search in its navigation
bar. Search delegates to the same location, MapKit route, signed backend candidate,
exact MapKit distance, backend OSM food match, filtering, and distance-only ranking
components as the iPhone flow.

Results use `CPPointOfInterestTemplate`; its picker and map receive the same stable
zero-to-five result snapshot. Partial or unavailable live coverage remains visible
in detail text, a manual refresh creates a new snapshot, and panning never changes
or re-ranks the result. No-results keeps all four criteria available for an
explicit user change. The primary POI action opens the operator list, and the
optional restaurant action resolves that restaurant. Both use the native Apple
place handoff described above.

Each result labels the applied minimum-power criterion as “N kW or higher”; it does
not present the park's highest observed EVSE power as though every EVSE provided
that value. Known complete or partial live availability remains informational.
When every EVSE has unknown availability, the result omits the redundant unknown
status line.

CarPlay performs a location-readiness preflight and never triggers first-time or
reduced-accuracy permission UI while driving. Missing setup is explained on the
CarPlay screen and must be completed in the iPhone app.
