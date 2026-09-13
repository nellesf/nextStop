# App diagnostics and silent recovery

## Obtain a report

On iPhone, open the info button, **Fehlerberichte**, then enable **Fehlerberichte
lokal speichern** before reproducing the issue. After the search, choose **Bericht
exportieren** and share the JSON file with the developer through a channel chosen
by the user. Include the app version/build separately when reporting a problem.
There is no automatic upload, account, diagnostic SDK, or CarPlay prompt.

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
release. A later automatic app-report upload requires its own explicit privacy
decision and accurate App Store disclosures; do not infer permission from
TestFlight crash sharing or location permission.

Sources reviewed 2026-09-13: [TDDDG section 25](https://www.gesetze-im-internet.de/ttdsg/__25.html),
[GDPR articles 5, 6 and 13](https://eur-lex.europa.eu/eli/reg/2016/679/deu),
[App Review guideline 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy).
