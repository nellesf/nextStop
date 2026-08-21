# Privacy and data-flow design

Status: Accepted on 2026-08-13. No accounts, ads, cross-device sync, user profiling, or third-party
analytics SDKs are permitted in MVP.

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
- exact route in logs, traces, analytics events, or error reports.

The backend needs the LineString to enforce the exact 5 km rule. This is the
minimum functional disclosure; a coarse bounding box would violate correctness.

### Backend to data providers

Ingestion is independent of user requests. Never proxy a user's route to national
or operator providers. Scheduled jobs fetch/cache regional provider data, and
searches use the local normalized PostGIS projection. Restaurant ingestion likewise
downloads Geofabrik-hosted OSM extracts on a schedule. No route, location,
criteria, or other request data is sent to OpenStreetMap or Geofabrik.

## Retention and logging

- HTTP access logs exclude bodies/query coordinates and redact authorization.
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
- Provider attribution/license notices present.
- Route-body logging disabled and tested in app, reverse proxy, APM, and WAF.
