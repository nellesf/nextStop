# App diagnostics and silent recovery

## Send a report

On iPhone, open the info button and the error-report form. Describe the issue in
free text, optionally select the initially unchecked technical-log attachment,
review the privacy notice, and explicitly send the report. The description can be
sent without logs. The attachment choice applies only to that submission and does
not enable future recording or unattended uploads. No account, diagnostic SDK, or
CarPlay report/consent prompt is introduced.

To include technical events from a reproduced issue, first enable **Fehlerberichte
lokal speichern** in the diagnostics screen, then reproduce it. Existing logs
cannot reconstruct failures that happened while recording was disabled. The report
form uses the retained allowlist described below; it does not collect raw system
logs or automatically attach the current journey. App version/build is not part of
the current diagnostic event schema.

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

Recording defaults to off. Turning it off clears the retained events. The local
file is atomic, excluded from device backups, and uses iOS file protection after
the first device unlock. Keep at most 200 events from the last seven days; prune
on load, record, view, and export. A device that remains unused cannot execute
expiry work until the app runs again. Exported files are user-controlled copies
and are not deleted when the in-app reports are cleared.

Each event has an independently generated UUID, UTC timestamp, fixed operation,
outcome and category, bounded duration/attempt/status/error-code values, and
optional server/proxy correlation IDs. Operation inputs, raw errors, userInfo,
URLs, coordinates, routes, destinations, filters, provider IDs, credentials, and
installation identifiers are absent from the schema. Unknown error domains have
no raw domain name or code in the export. Malformed/oversized storage is discarded;
unknown decoded fields are not re-exported.

The simulator suite checks backup exclusion, storage bounds, opt-in, deletion,
and sanitized exports. Run
`AppDiagnosticsTests.testStoreUsesFileProtectionOnPhysicalDevice` on a provisioned
physical iPhone to verify the file's protection class. The simulator does not
provide a usable protection attribute in the CI environment; this one hardware
check is explicitly skipped there. The device test still requires the exact
`completeUntilFirstUserAuthentication` value and fails if it is absent or different.

Captured paths are candidate HTTP requests, authentication failures surfaced by
candidate search, main-route planning, candidate driving distances, and native
charger/restaurant lookups. Ordinary successful app operations and cancellation
are not recorded. A recovered HTTP attempt is recorded only after a failure.
This is bounded technical diagnosis, not a record of all app activity.

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

The app introduces no unsolicited permission dialog. Local diagnostics are
voluntary and explicitly activated in the iPhone screen; there is no background
report transfer. This is a conservative implementation boundary, not an assertion
that any local or anonymized diagnostic collection is automatically exempt from
consent requirements. Section 25 TDDDG also covers terminal storage/access, with
a narrowly defined necessity exception. Apple's consent requirements also cover
data described as anonymous.

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

The app privacy manifest includes the report data, and App Store Connect privacy
answers must be changed manually before distribution. Do not assume occasional
support submissions meet Apple's optional-disclosure exception. Free text may be
identifying and logs can accompany it, so no anonymous-report promise is made.
Do not infer report consent from TestFlight crash sharing, Apple's system analytics
choice, location permission, or the local recording toggle.

Sources reviewed 2026-09-13: [TDDDG section 25](https://www.gesetze-im-internet.de/ttdsg/__25.html),
[GDPR articles 5, 6 and 13](https://eur-lex.europa.eu/eli/reg/2016/679/deu),
[App Review guideline 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy),
[EDPB consent guidance](https://www.edpb.europa.eu/system/files/documents/files/file1/edpb_guidelines_202005_consent_en.pdf),
[Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/),
[Google Cloud processing terms](https://cloud.google.com/terms/data-processing-addendum).
