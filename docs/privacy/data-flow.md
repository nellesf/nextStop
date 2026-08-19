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
| Aggregate telemetry | Backend metrics | Reliability/performance | Short operational window; no route or persistent user ID |

## Network flows

### iPhone to Apple services

- MapKit destination search and directions.
- A bounded MapKit POI lookup around a user-selected result to attach Apple Place
  Cards to its already-known charger and restaurant coordinates. This does not run
  during backend filtering or for results the user does not open.
- Siri/App Intents system processing when invoked.
- Apple Maps handoff for the selected park or, when food is selected, for a route
  containing the matched restaurant waypoint and the original ride destination.

Apple's current privacy disclosures and SDK behavior must be reflected accurately
in App Store privacy answers at release.

### iPhone to nextStop backend

Transmit over TLS:

- detailed route LineString (which inherently reveals origin/destination path);
- fixed search criteria;
- opaque per-request ID generated anew;
- pagination/snapshot token.

Do not transmit:

- profile name/ID, favorites, recent list;
- destination query text or Apple place ID;
- account/device/advertising identifier;
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
- App deletion removes local data.
- No server-side user record exists to export or delete.
- Provide a clear privacy notice covering Apple Maps/Siri and the transient backend
  route flow.

## Security controls

- TLS only, HSTS at the edge, modern cipher policy.
- Request size/coordinate-count/region validation and rate limiting.
- Parameterized SQL and least-privilege DB roles.
- Provider keys in deployment secret storage, rotated and never shipped to iOS.
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
