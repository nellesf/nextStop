# ADR 0017: User-initiated error reports

- Status: Accepted
- Date: 2026-09-13
- Approval: The owner explicitly requested an in-app report form with free text,
  an optional log attachment, and the necessary privacy notices.

## Context

Apple's crash-report channel does not capture handled search failures. Local
diagnostics and the silent candidate-request retry improve diagnosis and recovery,
but requiring users to export and separately forward a file adds friction.

The report description is user content and can contain personal information.
Sanitized technical fields and a random report reference do not make arbitrary
free text anonymous. A deliberate support request needs a separate data boundary
from ordinary ride preparation and search.

## Decision

Add a voluntary iPhone report form that sends a description to the nextStop
backend only after the user explicitly submits it. A separate, initially unchecked
choice attaches the existing `AppDiagnosticEvent` allowlist for that report only.
No automatic background reporting, analytics SDK, account, or CarPlay consent
prompt is introduced. The attachment choice does not activate future local
recording; recording remains a separate, default-off choice.

The form identifies the controller, purpose, data, retention, and withdrawal path
before submission and links to a localized Article 13 privacy notice. Use consent
under Article 6(1)(a) GDPR for the report and the separately selected attachment.
Record the notice version, attachment choice, and server receipt time. Public
reporting must remain unavailable until genuine controller/contact information is
configured; placeholder contact information is not a complete privacy notice.

On 2026-09-13 the owner explicitly approved clearly marked placeholders for the
internal TestFlight test and authorized backend deployment. This narrow test
exception uses `usesInternalTestPlaceholders` in `SupportContact.plist`, a reserved
unreachable `privacy@example.invalid` address, and a prominent German/English
warning in both the report form and privacy notice. It instructs testers to send
only synthetic data without personal information, states that submissions reach
the real backend, and directs questions to their already known internal TestFlight
contact. Placeholders never satisfy the public `isComplete` configuration check.

Debug builds may exercise the form; Release builds additionally require a
StoreKit-verified sandbox `AppTransaction`. Production, unverified, missing, and
unknown environments fail closed. StoreKit does not distinguish internal and
external TestFlight groups, so uploads using the exception must use Apple's
**TestFlight Internal Only** distribution option, which prevents external testing
and App Store submission of that build. Replace all placeholder contact values and
disable the flag before external testing or public release. This is an explicitly
bounded engineering test exception, not a claim that placeholder notices meet
GDPR transparency requirements.

This decision narrowly amends the prior backend destination-text prohibition for
text a user freely writes into a support report. The app must not populate that
text from a destination, route, profile, favorite, search result, or recent list.
None of those objects may be attached automatically. Warn against entering
personal details, exact locations/routes, credentials, or another person's data.
The technical attachment schema continues to exclude all such values.

Use a dedicated bounded API and report store with no report association to an
account, device, or App Attest installation. A random report reference identifies
one submission; a separately generated secret authorizes deletion. Save the
reference and deletion secret in a protected local receipt store before starting
the upload so an ambiguous network outcome does not remove the user's ability to
withdraw a report that reached the server. Keep at most 50 unexpired receipts,
exclude this store from backups, and prune expired receipts when the app runs.

Support retries must use the same submission identity. After early deletion,
retain only the random report reference, deletion-token hash, and expiry
needed to reject a replay; never retain the description, its hash, attachment, or
plaintext deletion secret in that tombstone. The app
provides withdrawal/deletion from the same iPhone interface. Successful deletion
removes the server payload immediately. Expire reports after 30 days and run
server cleanup at least hourly, including during periods without report traffic.
The physical cleanup lag is therefore at most one hour under normal operation.
For an existing report, replay protection expires at its original expiry. If
withdrawal arrives before a delayed upload and the reference is still unknown,
create a content-free tombstone expiring 30 days after the deletion request.
Serialize creation and deletion so this reversed arrival order cannot restore a
withdrawn report. Neither a repeat deletion nor an upload extends the tombstone.

Treat this minimal replay protection as a separate security purpose: enforcing
withdrawal and preventing a delayed request from restoring deleted content. Its
basis is Article 6(1)(f) GDPR, with a documented necessity/interests assessment and
advance disclosure of the interest and Article 21 objection right. Do not silently
switch the basis for continued report analysis after withdrawal; that analysis
stops and its payload is deleted.

Keep request bodies, descriptions, diagnostic attachments, receipt secrets, and
authentication material out of operational logs. Validate the whole report at the
API boundary, bound storage and request sizes, restrict administrative access, and
use the existing first-party HTTPS deployment. Reporting failure must not block
charging search or change its retry, filter, distance, or ranking rules.

## Consequences

The backend gains deliberately submitted support content with a defined deletion
and access lifecycle. Its operational handling is specified in
[the user error report runbook](../operations/user-error-reports.md).
Deploying the feature requires a verified Google Cloud processing agreement,
accurate processor/transfer disclosures, and a matching public privacy policy.
Frankfurt storage alone does not establish that every processor access stays in
the EEA. No deployment or contract verification is implied by this ADR.

Update the app privacy manifest and manually update App Store Connect privacy
answers before distribution. Conservatively disclose support/free-text content
and the optional diagnostic data for app functionality; do not rely on Apple's
optional-support disclosure exception without satisfying every criterion. Because
free text can identify the sender and accompany logs, the report must not be
advertised as anonymous. No tracking purpose is added.

The local JSON export remains an optional alternative. Apple crash reports remain
a separate Apple-operated channel and do not authorize this report transport.

## Sources

- [GDPR Articles 6, 7, 11–13 and 15–20](https://eur-lex.europa.eu/legal-content/DE/TXT/?uri=CELEX%3A32016R0679)
- [EDPB consent guidelines, especially paragraphs 64, 107–108 and 113–114](https://www.edpb.europa.eu/system/files/documents/files/file1/edpb_guidelines_202005_consent_en.pdf)
- [Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Google Cloud Data Processing Addendum](https://cloud.google.com/terms/data-processing-addendum)
- [Apple: verified app transaction](https://developer.apple.com/documentation/storekit/apptransaction/shared)
- [Apple: StoreKit test environments](https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox)
- [Apple: internal-only TestFlight builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)
