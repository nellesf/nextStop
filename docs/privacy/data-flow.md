# Privacy and data-flow design

Status: Accepted on 2026-08-13; voluntary support reporting amended on 2026-09-13
by [ADR 0017](../adr/0017-user-initiated-error-reports.md). No accounts, ads,
cross-device sync, user profiling, or third-party analytics SDKs are permitted in MVP.

## Data inventory

| Data | Location | Purpose | Retention |
|---|---|---|---|
| Profiles | iPhone local store | Preconfigure a ride | Until user deletes/app removal |
| Favorites | iPhone local store | Destination selection | Until user deletes/app removal |
| Recent destinations | iPhone local store | Destination selection | Last 20, user-clearable |
| Current precise location | iPhone memory/MapKit request | Route and exact candidate distance | Active operation only |
| Destination text/place | iPhone memory and Apple MapKit | Destination resolution/routing | Ride/session; local recents only after explicit use |
| Route geometry | Backend request + memory | Exact 5 km corridor query | Request lifetime; no application log or durable route table |
| Ride criteria | iPhone and backend request | Candidate filtering | Request/snapshot TTL; no user association |
| Charging corpus | Backend database | Search and freshness | Per source/license and operational policy |
| OSM restaurant corpus | Backend database | Selected-chain proximity filter | Versioned daily projection; per ODbL policy |
| App Attest credential | iPhone Keychain + backend auth tables | Prove an authentic app installation and prevent assertion replay | Device-only, non-synchronizing key ID replaced when invalid; hashed server record until 90 days inactive/revoked |
| App Attest challenge | iPhone Keychain while an attestation is pending + backend auth table | Bind one attestation/assertion exchange and prevent replay | At most 3 minutes; removed locally after Apple succeeds and consumed atomically by the backend |
| Search access token | iPhone memory | Authorize candidate search after App Attest verification | At most 15 minutes; never persisted |
| Aggregate telemetry | Backend metrics | Reliability/performance | Short operational window; no route or persistent user ID |
| Optional app diagnostics | iPhone local protected file, only after explicit activation | Reproduce technical failures; optional attachment to a user-submitted report or local export | At most 200 events from seven days, pruned when the app runs; cleared when disabled; no backup or unattended upload |
| User-submitted error report | Dedicated backend support store | Investigate and fix the described error | Expires after 30 days; physical purge at least hourly; earlier payload deletion on withdrawal |
| Support consent evidence | Same report record: notice version, attachment choice, receipt time | Record the scope of the user's submission | Same report expiry/deletion lifecycle |
| Report receipt and deletion secret | iPhone protected file, excluded from backups | Let the user withdraw even if the upload response is lost | At most 50 unexpired receipts; expired receipts pruned when the app runs |
| Deleted-report replay protection | Backend tombstone: random report reference, deletion-token hash, expiry | Prevent a delayed retry from restoring a withdrawn report | Existing report's original expiry; for a still-unknown reference, 30 days after deletion request; no report content, content hash, logs, or plaintext deletion secret |
| Request diagnostics | Backend/proxy operational logs | Diagnose HTTP status, timing, and coarse failure causes | Bounded rotation per deployment; see operational runbook; no request body, IP, criteria, or installation identity |

## Network flows

### iPhone to Apple services

- MapKit destination search and directions.
- A bounded MapKit charger or restaurant lookup around one result only after the
  user taps that item's Maps button. It matches against already-known authority/OSM
  coordinates and does not run during backend filtering or for untouched items.
- Siri/App Intents system processing when invoked.
- App Attest key generation, initial attestation, and Apple verification traffic on
  supported physical devices. Assertions after attestation are generated locally.
- Apple Maps handoff either to one matched native charger/restaurant by stable
  Place ID on iPhone, or to navigation from CarPlay. When food is selected in
  CarPlay, the navigation route contains the matched restaurant waypoint and the
  original ride destination.

Apple's current privacy disclosures and SDK behavior must be reflected accurately
in App Store privacy answers at release.

### iPhone to nextStop backend

Transmit over TLS:

- detailed route LineString (which inherently reveals origin/destination path);
- fixed search criteria;
- opaque per-request ID generated anew;
- pagination/snapshot token;
- a short-lived App-Attest-backed access token in the Authorization header;
- during authentication only, an App Attest key identifier, single-use challenge,
  and attestation/assertion object. The backend stores only the key identifier's
  hash plus the verified public security material and assertion counter.

Because Apple App Attest reports unsupported in the Simulator, a Debug-only
provider may obtain a short-lived token from a loopback Mac helper. The helper
authenticates the developer through Google Cloud IAP and never writes the token to
the project. That provider is compile-time excluded from Release builds.

Do not transmit:

- profile name/ID, favorites, recent list;
- destination query text or Apple place ID;
- account, advertising identifier, or general-purpose device identifier; the App
  Attest key identifier is sent only for installation-integrity verification;
- vehicle identity, battery state, contacts, microphone audio;
- exact route in logs, traces, analytics events, or technical diagnostic attachments.

The backend needs the LineString to enforce the exact 5 km rule. This is the
minimum functional disclosure; a coarse bounding box would violate correctness.

### iPhone to nextStop support endpoint

This separate, voluntary flow sends a user-written description only after an
explicit submission from the iPhone form. The user may select an initially
unchecked option to attach the existing diagnostic allowlist. That choice applies
only to this report and does not enable future collection or reporting. The app
does not fill the description from ride data or attach profiles, favorites, recents,
search criteria/results, route geometry, or destination text automatically.

The report contains a random submission reference, consent/notice version, and
the attachment choice. Technical events contain only independent event UUIDs,
timestamps, fixed operation/outcome/category values, bounded duration and attempt
values, optional HTTP status and known error-domain/code values, and validated
server/proxy correlation UUIDs. The attachment includes no raw error messages,
URLs, app/device identifiers, credentials, coordinates, destinations, or routes.
App version/build information is not currently part of this event schema.

Free text can nevertheless contain personal information, including information a
user types about a place or journey. This owner-approved support-only exception
does not change the prohibition on automatically transmitting destination text
from the product flow. The form asks users to avoid personal details, exact
locations/routes, credentials, and other people's data. Do not call these reports
anonymous or promise that arbitrary free text is automatically sanitized.

The existing HTTPS connection necessarily processes network addressing and may
authenticate the request. The report record must not retain IPs, an App Attest key,
an installation hash, an access token, or another user/device association. A
separate deletion secret authorizes withdrawal; the server stores only its hash.
The client persists the reference and secret before sending so it can delete a
report whose response was lost. Reports are not forwarded to a third-party
diagnostic service. Google Cloud is still a hosting processor and must be disclosed.

### Backend to data providers

Ingestion is independent of user requests. Never proxy a user's route to national
or operator providers. Scheduled jobs fetch/cache regional provider data, and
searches use the local normalized PostGIS projection. Restaurant ingestion likewise
downloads Geofabrik-hosted OSM extracts on a schedule. No route, location,
criteria, or other request data is sent to OpenStreetMap or Geofabrik.

## Retention and logging

- HTTP diagnostics use an explicit field allowlist, excluding bodies, raw URLs,
  query strings, IPs, user agents, and all authorization/attestation material.
- Application errors use generated request IDs and coarse failure categories.
- Tracing attributes must not contain coordinates, routes, destination names, or
  provider secrets.
- Candidate snapshot tokens are random/opaque, short-lived, and not user-linked.
- App Attest key identifiers, public keys, receipts, challenges, assertions, and
  access tokens are never logged or attached to route/search metrics. Challenges
  are deleted on use/expiry. Inactive or revoked credential records are removed
  after 90 days.
- If abuse protection uses IP addresses at the edge, document legal basis,
  truncate/hash as appropriate, use a short retention period, and keep it outside
  product analytics.
- Backups contain charging/provider data, never local user profiles or route tables.
  The current disposable staging deployment has no scheduled database backups.
  Any future backup policy must account for report expiry and withdrawal before
  this support data is included; do not promise a deletion deadline that excludes
  recoverable report copies or operator exports.
- Local app diagnostics default to off and are excluded from device backups.
  Enabling them is voluntary on iPhone; there is no CarPlay prompt. Local export
  remains user-initiated. Attachment requires a separate selection for each report;
  report submission is never inferred from local recording consent. Unknown error
  payloads are never serialized. See [app diagnostics](../operations/app-diagnostics.md)
  and [request diagnostics](../operations/request-diagnostics.md) for the schema,
  retry policy, correlation limitations, retention, and report retrieval.
- Submitted report payloads expire after 30 days. A scheduled purge runs at least
  hourly without requiring new requests, giving a normal physical cleanup lag of
  at most one hour. Successful early deletion removes the content and attachment
  immediately. Only minimal replay protection remains until the original expiry.
  If deletion arrives before the upload and the reference is not yet known,
  protection instead expires 30 days after that deletion request. Creation and
  deletion are serialized; repeats never extend protection. An in-flight retry
  therefore cannot recreate withdrawn content during that bounded window. See the
  [support runbook](../operations/user-error-reports.md).
- Descriptions, attachments, receipt secrets, and request bodies never enter
  operational logs. Operator access is restricted and report copies must follow
  the same retention and withdrawal lifecycle.

## Location permission

Request When In Use on iPhone with a concise German purpose string that explains
route and charging-park search. Do not request Always authorization or continuous
background location for MVP. CarPlay must guide the user to complete missing
permission later on iPhone rather than trying to force a driving-time prompt.

## Data subject controls

- Delete individual/all profiles, favorites, and recents in the iPhone app.
- App deletion removes the app's local product data. The operating system manages
  the App Attest key and its Keychain identifier; nextStop replaces an identifier
  when Apple reports the key invalid rather than relying on uninstall as a
  guaranteed security-credential deletion event.
- No account or server-side product profile exists to export. App Attest leaves an
  unlinkable installation-security record that expires automatically after 90
  days of inactivity; it is not used to reconstruct app data or activity.
- Provide a clear privacy notice covering Apple Maps/Siri and the transient backend
  route flow.
- The iPhone report form offers withdrawal and server deletion from the same
  interface used to submit. Protected local receipts preserve that capability
  after an uncertain network result. Other access, rectification, restriction, or
  portability requests use the published controller contact and report reference;
  collect no additional identity merely to maintain an accountless report store.
- Withdrawal of report consent does not change the lawfulness of processing before
  withdrawal. The optional local diagnostic recording control is separate from
  deletion of already submitted reports, which must be requested explicitly.

## Support-report transparency and legal basis

The form uses consent under Article 6(1)(a) GDPR for its description and separately
selected logs. Its localized notice is available before submission and from the
iPhone information/privacy surface. It identifies the controller and contact,
purpose and data, hosting recipients, applicable international-transfer safeguards,
retention, withdrawal and other rights, supervisory-authority complaint rights,
and the voluntary nature of the feature. No profiling or automated decisions are
performed with report content. Rejecting reporting or logs never disables search.

After withdrawal, a separate, minimal security record prevents delayed retries
from restoring deleted content. Its purpose is enforcing the user's withdrawal
and preserving intake integrity, not continuing error investigation. This record
contains only the random report reference, deletion-token hash, and expiry, with
no description, logs, or content hash. For an existing report the original expiry
applies; an unknown reference is protected for 30 days after the deletion request.
Its separate basis is the
controller's legitimate interest under Article 6(1)(f) GDPR, subject to a documented
necessity and interests assessment. Disclose that interest and the Article 21
right to object through the published controller contact. This limited security
basis is disclosed before submission and must not be used to continue the
consent-based report processing after withdrawal.

Genuine controller identity/address/contact details are a release prerequisite.
Placeholders and unverified email addresses cannot satisfy this notice. The owner
explicitly authorized a limited internal TestFlight test with marked placeholders
on 2026-09-13. Both report and privacy screens explain the incomplete contact
details, actual backend transmission, synthetic-data-only test scope, and the
existing internal TestFlight contact path. The reserved `.invalid` address is
clearly unreachable. This test exception is not a representation of GDPR-complete
controller information.

The test flag is independent of contact completeness: only Debug or a verified
sandbox `AppTransaction` enables the placeholder form; production or unknown
environments remain blocked. StoreKit transaction data is evaluated only on the
device and is never attached, stored in diagnostics, or sent to nextStop. Internal
and external TestFlight share the sandbox, so this build must be uploaded using
Apple's **TestFlight Internal Only** option. Remove the exception and supply real
contact information before external testing or public release. The public privacy
policy must contain the same information. The owner must verify the Google Cloud
processing agreement, subprocessors and transfer safeguards for the actual account.
Choosing a Frankfurt VM establishes the intended storage region, not a blanket
guarantee against third-country processor access. These deployment prerequisites
are not completed merely by adding the reporting code.

The privacy manifest and App Store Connect answers disclose customer-support/free-
text content and optional technical diagnostics for app functionality, without
tracking. Treat potentially identifying free text and its attached logs
conservatively as linked data. Apple's occasional-support exception requires all
its conditions; this accountless form does not rely on it. App Store answers must
be updated manually; the manifest does not publish them automatically. See
[ADR 0017](../adr/0017-user-initiated-error-reports.md) for the primary sources.

## Security controls

- TLS only, HSTS at the edge, modern cipher policy.
- Request size/coordinate-count/region validation and rate limiting.
- Segment/total-route limits, bounded concurrent search admission, and database
  statement deadlines.
- Parameterized SQL and least-privilege DB roles.
- Provider keys in deployment secret storage, rotated and never shipped to iOS.
- App Attest on supported physical devices, single-use challenges, strictly
  increasing assertion counters, and 15-minute server access tokens. Static
  client credentials are absent from new builds; Simulator access uses the
  loopback/IAP development-token path.
- Signed/pinned deployment artifacts and dependency/vulnerability scanning.
- Bounded provider payloads, schema validation, timeouts, and quarantine.
- No sensitive values in crash reporting. Prefer no third-party crash SDK for MVP;
  if added later, require an explicit privacy decision.

## Release checklist

- Privacy policy and App Store privacy labels reviewed against actual traffic.
- `PrivacyInfo.xcprivacy` and required-reason API declarations verified with the
  current SDK.
- Data-processing agreements/hosting region and subprocessors documented.
- Real support controller/contact information configured; in-app and public
  Article 13 notices agree with the deployed report flow and transfer safeguards.
- Report expiry, scheduled purge, early deletion, replay protection, and handling
  of any operator copies verified before report ingestion is enabled.
- Provider attribution/license notices present.
- Route-body logging disabled and tested in app, reverse proxy, APM, and WAF.
