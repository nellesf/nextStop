# ADR 0014: Single-VM Google Cloud staging deployment

- Status: Accepted
- Date: 2026-08-18
- Amended: 2026-08-21 (bounded search, least-privilege roles, and App Attest rollout)

## Context

The private TestFlight phase has two or three users and needs a reachable backend
before production traffic or availability requirements exist. The owner approved
a cost-minimized Google Cloud deployment that mirrors the working local process
and explicitly declined scheduled backups for this disposable staging corpus.

## Decision

Run one `e2-standard-2` Compute Engine VM in Frankfurt. Run the Node.js API, one
ingestion worker, one release-scoped migrator, and PostgreSQL/PostGIS on that VM
from the same backend artifact. Keep PostgreSQL and the OSM cache on a separately
attached 150 GB persistent disk. Expose only the API through Nginx over HTTPS at
`api.nextstop.tech`; the worker and migrator have no listener, PostgreSQL remains
private, and SSH is allowed only through Google IAP.

Use separate database login roles and credentials. The API role is read-only,
may select only the tables used by candidate search, and has a 15-second statement
deadline. The worker can read and modify ingestion/projection tables and execute
the two projection rebuild functions, but cannot change schemas, migration state,
or roles. The migrator alone uses the database owner for DDL. A deployment runs
migrations and then an idempotent role/grant initializer before starting the API
and worker. Existing persistent volumes are upgraded in place; this separation
does not rebuild or republish projections.

Authenticate physical-device search with Apple App Attest and a server-issued,
15-minute access token while leaving `/health` public. App Attest authentication
uses a separate database role that can modify only its challenge and credential
tables; candidate search remains read-only. During the private-staging rollout,
an explicit compatibility flag may retain the former revocable bearer so already
installed builds continue to work. The Debug Simulator instead receives a
short-lived token through a loopback helper authenticated to the VM over Google
Cloud IAP. The shared bearer is never a production credential and is disabled
after physical-device and TestFlight verification. See ADR 0015.

Reject candidate requests above 512 KiB, over 8,000 route coordinates, outside
the supported European envelope, over 250 km for one segment, or over 2,500 km in
total. Admit at most four search handlers concurrently per API process, retain the
Nginx per-IP rate limit with burst four, and enforce a 15-second PostgreSQL
statement deadline. Requests that exceed a boundary are rejected; route geometry
is never simplified because that could change the exact 5 km corridor rule.

This is a staging exception to the managed-database production target. It does not
change provider, search, privacy, filtering, routing, or data-license decisions.

## Alternatives

- Cloud Run plus Cloud SQL: stronger isolation and managed recovery, but materially
  more expensive for the current private test scope.
- HTTP on a raw IP address: cheaper to configure but rejected because route
  geometry requires transport security and iOS App Transport Security defaults to
  HTTPS.

## Consequences

The VM is a single failure and deployment domain. Process and database privileges
are isolated, but a resource-heavy OSM import can still contend with the API for
VM and database resources. There is no automated backup or point-in-time recovery;
source projections must be rebuilt after data loss. Before public production,
place API and worker roles in independently scalable deployment domains, adopt
managed PostGIS with recovery, disable the shared staging compatibility
credential, and review availability, capacity, and operational ownership. App
Attest activation requires the exact App ID prefix, matching provisioning, and a
physical-device verification; it does not rebuild search projections.
