# Optional iOS 27 experience improvements

Reviewed: 2026-09-16. Status: proposals only; none of these features is implemented
by the iOS 27 compatibility work. Effort estimates are relative engineering scope,
including focused tests and device/CarPlay validation, not delivery commitments.

Keep iOS 18 as the minimum, the EV-charging entitlement, local profiles and
favorites, ride-scoped edits, the five-result limit, and Apple Maps navigation.
New APIs require availability guards and the existing flow on older systems.

## 1. Search for a new destination directly in CarPlay

**Value: high. Effort: medium. New permission in iOS 27.**

Add an optional destination-search entry using `CPSearchTemplate`, backed by the
existing MapKit destination-search application interface. This fills the current
gap between a saved/recent destination and an unfamiliar destination that has not
been prepared on iPhone. Selecting a result would open the existing ride summary;
it would not start navigation or change charging-result selection.

Apple's current category matrix permits the search template for EV-charging apps
starting in iOS 27. The guide also requires search to remain an alternative:
vehicles can disable the keyboard while driving. Profiles, favorites, recents,
and the existing Siri path must remain usable without it. Respect runtime list
limits, cancel obsolete searches, and handle ambiguous destinations explicitly.
Do not assume this template supplies dictation or Siri integration.

**Approval:** explicit owner approval and an amendment to ADR 0002 and the CarPlay
architecture are required. They currently prohibit `CPSearchTemplate`. Apple's
expanded API permission does not itself change the accepted product decision.
On iOS 18–26, retain the existing destination entry paths.

Source: [CarPlay Developer Guide, pp. 14 and 24](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf).

## 2. Select a saved profile through Siri or Shortcuts

**Value: high. Effort: medium. Existing App Intents capability.**

Expose a lightweight saved-profile `AppEntity` and an explicit profile-based ride
action, so a person can request a named commute or holiday profile without
reselecting its criteria. The current `PrepareRideIntent` only accepts destination
text. The CarPlay architecture already identifies a profile entity as a future
option; this is useful alongside iOS 27 but does not require a new iOS 27 API.

Resolve a profile by stable local identity, ask the system to disambiguate duplicate
names, and copy its values into a ride draft. Saved profiles remain immutable from
the driving flow. Do not add custom microphone access, broad Spotlight indexing,
or promises about Siri AI language/region availability as part of this proposal.

**Approval:** normal feature approval; no accepted domain rule or template-family
change is needed. The existing destination-only action remains available on all
supported systems. Validate the new action through the system, not only by calling
the injected handler directly.

Sources: [AppEntity](https://developer.apple.com/documentation/appintents/appentity),
[defining app entities](https://developer.apple.com/documentation/appintents/defining-app-entities-for-your-custom-data-types).

## 3. Evaluate clearer CarPlay list context

**Value: medium. Effort: medium. Available since iOS 26.4.**

Prototype `CPListTemplateDetailsHeader` on the existing operator list or ride
summary to keep the selected place and essential context visible above the rows.
This may help with the missing detail summaries recorded by the current
[display audit](../testing/carplay-layout/visual-review.md), but improved fit is a
hypothesis that needs measurement on small, wide, portrait, touch, and knob displays.

Use concise text variants and restrained imagery; the API requires a thumbnail.
Preserve exact operator names, truthful driving distance, informational availability,
and current Apple Maps actions. Do not replace the five-result POI picker.
Although highlighted at WWDC26, the header API, `listHeader`, and `bodyVariants`
are documented as available from iOS 26.4, not exclusively iOS 27.

**Approval:** approve the visual/flow design before implementation. Using a header
inside the existing list family needs no new template-family ADR; replacing the
accepted result/detail flow would require the relevant decision amendment.
Keep existing lists on iOS 18–26.3 and if testing shows the header reduces usability.

Sources: [details header API](https://developer.apple.com/documentation/carplay/cplisttemplatedetailsheader),
[WWDC26 CarPlay session](https://developer.apple.com/videos/play/wwdc2026/212/).

## 4. Keep the local CarPlay library current

**Value: medium. Effort: medium. New API in iOS 27.**

Use SwiftData `ResultsObserver` behind an application/repository interface to
notice profile or favorite edits made on iPhone while CarPlay is connected.
Currently the CarPlay library fetches these values when its root template is built.
Observation could refresh the next library presentation without a reconnect.

Apply updates at safe navigation boundaries; do not reorder rows under selection,
replace an active ride draft, or update/rerank a charging-result snapshot. Keep
persistence types outside presenters. The existing reload path remains the fallback
on iOS 18–26. No schema migration or change to stored MapKit identifiers is needed.

**Approval:** normal feature approval; the existing local-persistence and immutable
ride-draft decisions can remain unchanged. `HistoryObserver` cloud synchronization
and a `.codable` storage rewrite offer no required benefit for this proposal.

Sources: [ResultsObserver](https://developer.apple.com/documentation/swiftdata/resultsobserver),
[WWDC26 SwiftData session](https://developer.apple.com/videos/play/wwdc2026/274/).

## 5. Test the complete Siri integration

**Value: medium, indirect UX benefit. Effort: small–medium. New in iOS 27.**

Add `AppIntentsTesting` coverage for discovery, parameter resolution, destination
errors, and the prepared-ride handoff. Existing `RideIntentHandlerTests` cover the
application handler; the new framework invokes intents through the system
infrastructure used by Siri and Shortcuts and can catch integration failures.

**Approval:** normal test-scope approval; no ADR changes or new user-facing feature.
Run only in an iOS 27 test target/environment with the installed app and matching
development-team signing for app and test runner. Keep existing unit tests and
manual spoken-Siri checks; this is not possible with Command Line Tools alone.

Sources: [App Intents Testing](https://developer.apple.com/documentation/appintentstesting),
[WWDC26 testing session](https://developer.apple.com/videos/play/wwdc2026/295/).

## Features outside these proposals

The iOS 27 category matrix also allows `CPVoiceControlTemplate` for EV-charging
apps. It presents a voice-service interface; it does not implement speech
recognition or connect an app to Siri. A custom conversation/audio stack would
change the accepted voice scope and needs separate owner approval.

New map panels and route sharing belong to CarPlay navigation apps. They are not
an appropriate shortcut for nextStop's EV-charging category or Apple Maps handoff.
Vehicle state of charge, automatic charging-stop suggestions, video playback, and
cloud profile sync remain outside the accepted product scope.
