# App diagnostics and silent recovery

## Send a report

On iPhone, open the info button and the error-report form. Describe the issue in
free text, optionally select the initially unchecked technical-log attachment,
review the privacy notice, and explicitly send the report. The description can be
sent without logs. The attachment choice applies only to that submission and does
not enable future recording or unattended uploads. No account, diagnostic SDK, or
CarPlay report/consent prompt is introduced.

Local recording is enabled by default so retained technical failure evidence can
already exist when the user opens the report form after an unexpected issue. If
**Fehlerberichte lokal speichern** was turned off in the diagnostics screen,
enable it before reproducing the problem. Recording cannot reconstruct failures
that happened while it was disabled. The report form uses the retained allowlist
described below; it does not collect raw system logs or automatically attach the
current journey. The optional attachment preview also shows app version, build
version, and numeric iOS version if all three can be read in their bounded format.
These values describe the environment when the report form opens, not necessarily
the version that produced an older retained event.

The privacy notice explains who receives the description and optional logs, why,
how long they are retained, and how to withdraw. Warn users against including
personal details, exact locations/routes, credentials, or other people's data in
the description. Free text is not automatically anonymized.

Each upload has a random report reference and separate deletion secret. The app
saves a protected, backup-excluded receipt before starting the request, including
when a response is subsequently lost. At most 50 unexpired receipts are retained;
expired receipts are pruned when the app runs. Users can withdraw and delete from
the iPhone report interface. Do not interpret an uncertain connection result as
proof that the server received nothing; preserve the receipt and use the same
identity for any explicit retry.

Submitted payloads expire after 30 days and a scheduled server job purges them at
least hourly. Successful early deletion removes content immediately, leaving only
the random report reference, deletion-token hash, and expiry as replay protection.
An existing report keeps its original expiry. If deletion reaches the server
before the upload, a content-free tombstone for the unknown reference expires
30 days after that deletion request. Creation/deletion must be serialized and
repeated requests must not extend this window. It retains no description, content
hash, logs, or plaintext secret.
Local recording and local event deletion are independent of already submitted
reports. See
[the support runbook](user-error-reports.md) for authenticated operator retrieval,
retention, access controls, and deployment requirements.

**Deployment prerequisite:** the owner must supply genuine controller/contact
details and verify hosting/processor and transfer disclosures. Submission remains
unavailable until the required controller configuration exists. Source changes do
not publish the public privacy policy, update App Store Connect answers, or deploy
the receiving service.

## Local diagnostics and optional export

The JSON export remains an alternative for users who prefer their own sharing
channel. Choose **Bericht exportieren** and share the file deliberately. A local
export does not itself send anything to nextStop.

Recording defaults to on when no saved preference exists. A persisted off choice
is respected on later launches. Turning recording off clears the retained events
and saves the off preference; deleting events alone does not re-enable recording.
Earlier app versions did not always retain an off preference after deleting their
diagnostics file, so an absent legacy file cannot identify a prior opt-out. The
new default applies in that case.

The local file is atomic, excluded from device backups, and uses iOS file
protection after the first device unlock. Keep at most 200 events from the last
seven days, removing the oldest entries first when the limit is exceeded; prune
on load, record, view, and export. A device that remains unused cannot execute
expiry work until the app runs again. This is an event-count and age bound, not
a daily archive rotation. Exported files are user-controlled copies and are not
deleted when the in-app reports are cleared.

Each event has an independently generated UUID, UTC timestamp, fixed operation,
outcome and category, bounded duration/attempt/status/error-code values, and
optional server/proxy correlation IDs. Operation inputs, raw errors, userInfo,
URLs, coordinates, routes, destinations, filters, provider IDs, credentials, and
installation identifiers are absent from the schema. Unknown error domains have
no raw domain name or code in the export. Malformed/oversized storage is discarded;
unknown decoded fields are not re-exported.

For a submitted report with logs selected, optional `diagnosticContext` contains
exactly `appVersion`, `buildVersion`, and `operatingSystemVersion`. These bounded
numeric version strings appear alongside the events in the report's attachment
preview. They are captured when the composer opens and frozen with the request
for retries. An invalid/missing version omits the whole context; a report without
logs never includes it. There is no device model or identifier. The separate local
JSON export still contains the event schema only.

The simulator suite checks backup exclusion, storage bounds, default recording,
persisted opt-out, deletion, and sanitized exports. Run
`AppDiagnosticsTests.testStoreUsesFileProtectionOnPhysicalDevice` on a provisioned
physical iPhone to verify the file's protection class. The simulator does not
provide a usable protection attribute in the CI environment; this one hardware
check is explicitly skipped there. The device test still requires the exact
`completeUntilFirstUserAuthentication` value and fails if it is absent or different.

Captured paths are candidate HTTP requests, authentication failures surfaced by
candidate search, main-route planning, candidate driving distances, native
charger/restaurant lookups, iPhone destination search, shared iPhone/CarPlay
location requests, and rejected Apple Maps launches on iPhone and CarPlay.
Ordinary successful app operations and cancellation are not recorded. A recovered
HTTP attempt is recorded only after a failure. Route validation uses stable codes
under `errorDomain: routePlanning`: `1` means no route, `2` invalid distance,
`3` invalid travel time, and `4` invalid polyline. A failed Maps launch records its
operation and duration without the launch URL or place details.

Destination search records thrown MapKit failures under `destinationSearch`
without the query text. Location request failures use `location`; only known
CoreLocation errors retain their numeric code under `errorDomain: coreLocation`.
Its network error (`2`) maps to `connection`; other CoreLocation codes map to
`unknown`. Empty or invalid location callbacks record an unknown failure without
a code or coordinate. Permission denial, restricted access, and reduced accuracy
are not diagnostic faults and are not recorded. No new location deadline is
introduced: the provider still relies on the existing system callback behavior.

This is bounded technical diagnosis, not a record of all app activity. Siri's
separate destination-lookup path is not instrumented. A bug in uninstrumented
code, an immediate process termination, an unavailable or full local store, or
already rotated events can leave gaps. The feature does not capture arbitrary
crashes, stack traces, or hangs; use Apple's crash reports below for those
investigations. Do not promise that all information needed for every future bug
will be available.

## Correlate with the backend

Use the event time and the instructions in [request diagnostics](request-diagnostics.md).
`serverRequestID` comes from the API's `X-Request-ID` UUID. `edgeRequestID` comes
from the proxy's `X-Edge-Request-ID`, accepted only as exactly 32 hexadecimal
characters and exported in UUID notation. Remove its hyphens to find the nginx
record. Proxy records can contain the validated upstream UUID as a bridge.
Neither ID comes from the search-body request ID, snapshot, or App Attest key.

No response means there may be no correlation ID. A URL transport error may have
occurred before reaching nginx. A successful API response followed by a MapKit
failure is a separate operation. Missing logs cannot prove a particular network
or provider outage; the historical 2026-09-11 08:49:15 Europe/Berlin failure cannot
be reconstructed from logs that were disabled at that time.

## Silent HTTP retry policy

- One transient retry budget per candidate page request, with a 400 ms fallback
  delay. The existing single authentication refresh has a separate budget, so
  there are at most three HTTP attempts across both kinds of recovery.
- Retry connection loss, timeout, offline, refusal, or DNS failure, and HTTP 408,
  500, 502, 504, or generic 429/503 unavailability.
- Honor valid `Retry-After` seconds or HTTP dates only when within the two-second
  interactive cap. A longer or malformed supplied value is not shortened or
  ignored to retry early.
- Do not retry cancellation, TLS/certificate failures, malformed/oversized
  responses, invalid requests, snapshot expiry, final authentication failure, or
  known charging/restaurant projection preparation responses.
- Preserve the exact encoded request, page cursor, and snapshot through recovery;
  only replace the authorization header after a token refresh. Never relax search
  filters or substitute estimated driving distances.
- Keep the existing loading UI throughout recovery. Only a final failure becomes
  visible. The service-unavailable text no longer refers to a local server.

## Apple crash reports

Upload symbol information with each TestFlight/App Store build. Use Xcode's
Organizer, Crashes, to retrieve Apple's symbolicated crash reports. TestFlight
automatically shares crash reports through Apple's existing beta-testing flow;
App Store reports depend on the user's Apple diagnostic-sharing choices.
Handled search errors such as HTTP timeouts do not create crash reports. Raw
Apple reports can contain more information than this app's allowlist: inspect
them before sharing and do not automatically forward them to the backend.

Sources: [Apple: acquiring crash reports](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs),
[Apple: TestFlight privacy](https://testflight.apple.com/).

## Consent and release scope

The owner approved default-on local diagnostics on 2026-09-14. The app introduces
no unsolicited permission dialog or background report transfer. The iPhone
settings and privacy notice disclose automatic local storage, its diagnostic
purpose, bounded retention, and the control to disable it and delete events. The
setting is separate from consent to send a report or attach logs.

Default-on implementation does not by itself establish a legal exemption. Keep the
scope restricted to technical fault diagnosis and document the applicable basis
and necessity of local storage before release; do not treat an opt-out as consent.
Section 25 TDDDG also covers terminal storage/access, with a narrowly defined
necessity exception. Apple's App Store privacy answers distinguish data processed
only on device from data sent off device; that label definition is not a blanket
exemption from applicable privacy law or App Review guideline 5.1.1.

Necessary server operation logs can have a non-consent legal basis, subject to
documented necessity, proportionality, interests balancing, transparency, and
retention. Review the deployed log lifecycle and the public privacy notice before
release. [ADR 0017](../adr/0017-user-initiated-error-reports.md) authorizes the
separate, user-initiated description and optional log upload. Its lawful basis is
consent under Article 6(1)(a) GDPR, with the notice version, attachment choice, and
server receipt time retained as evidence. The send action is preceded by the
localized notice; the attachment choice is not preselected. Withdrawing must be
as easy as submitting, using the in-app deletion control rather than requiring
an email or file export.

The minimal replay tombstone has a different security purpose: making withdrawal
effective even if a late upload arrives. Its separately disclosed basis is Article
6(1)(f) GDPR, subject to documented necessity and interests balancing. Include its
bounded retention and the Article 21 right to object in the privacy notice,
including the 30-day window for a reference not yet known when deletion arrives.
This is not an alternative basis for retaining or continuing to analyze withdrawn
report content.

Keep the full Article 13 information accessible before submission and in the
iPhone information/privacy screen. Use accurate controller identity/contact,
purpose, recipients, transfer safeguards, retention, rights and complaint
information; explain that both reporting and attaching logs are optional. A
Frankfurt storage region alone does not guarantee all Google processor access
stays in the EEA. Record actual contractual safeguards in the public policy before
release. No identity or hosting facts should be invented to enable the form.

The owner authorized an internal TestFlight exception on 2026-09-13. The checked-in
`SupportContact.plist` explicitly marks contact values as placeholders and uses
`privacy@example.invalid`, which cannot receive mail. Both form and privacy notice
warn that controller details are incomplete, require synthetic test data without
personal information, identify the real backend transmission, and direct questions
to the tester's known internal TestFlight contact. This does not make the notice
legally complete. Use **TestFlight Internal Only** when distributing this build;
Apple prevents such a build from reaching external groups or the App Store.

The flag does not make `SupportPrivacyConfiguration.isComplete` true. Debug builds
may test submission. Release builds require `AppTransaction.shared` to return a
verified sandbox environment; a production or unverified/unknown environment keeps
submission disabled. This check may need internet access. It requests no purchase,
does not refresh a receipt interactively, and sends no StoreKit transaction or
identifier to the nextStop backend. Internal and external TestFlight share the
sandbox environment, so the internal-only upload restriction remains necessary.
Before external testing or public release, replace every placeholder and set
`usesInternalTestPlaceholders` to `false`. Check real controller/contact data and
complete the remaining release privacy and contractual requirements above.

The app privacy manifest includes the report data, and App Store Connect privacy
answers must be changed manually before distribution. Do not assume occasional
support submissions meet Apple's optional-disclosure exception. Free text may be
identifying and logs can accompany it, so no anonymous-report promise is made.
Do not infer report consent from TestFlight crash sharing, Apple's system analytics
choice, location permission, or the local recording toggle.

Sources reviewed 2026-09-13; Apple privacy guidance rechecked 2026-09-14: [TDDDG section 25](https://www.gesetze-im-internet.de/ttdsg/__25.html),
[GDPR articles 5, 6 and 13](https://eur-lex.europa.eu/eli/reg/2016/679/deu),
[App Review guideline 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy),
[EDPB consent guidance](https://www.edpb.europa.eu/system/files/documents/files/file1/edpb_guidelines_202005_consent_en.pdf),
[Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/),
[Google Cloud processing terms](https://cloud.google.com/terms/data-processing-addendum).
