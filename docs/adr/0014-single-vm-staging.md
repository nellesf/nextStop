# ADR 0014: Single-VM Google Cloud staging deployment

- Status: Accepted
- Date: 2026-08-18

## Context

The private TestFlight phase has two or three users and needs a reachable backend
before production traffic or availability requirements exist. The owner approved
a cost-minimized Google Cloud deployment that mirrors the working local process
and explicitly declined scheduled backups for this disposable staging corpus.

## Decision

Run one `e2-standard-2` Compute Engine VM in Frankfurt. Run the Node.js API and its
single in-process ingestion coordinator together with PostgreSQL/PostGIS on that
VM. Keep PostgreSQL and the OSM cache on a separately attached 150 GB persistent
disk. Expose only Nginx over HTTPS at `api.nextstop.tech`; keep PostgreSQL private
and allow SSH only through Google IAP.

This is a staging exception to the managed-database production target. It does not
change provider, search, privacy, filtering, routing, or data-license decisions.

## Alternatives

- Cloud Run plus Cloud SQL: stronger isolation and managed recovery, but materially
  more expensive for the current private test scope.
- HTTP on a raw IP address: cheaper to configure but rejected because route
  geometry requires transport security and iOS App Transport Security defaults to
  HTTPS.

## Consequences

The VM is a single failure and deployment domain. A resource-heavy OSM import can
temporarily reduce API performance. There is no automated backup or point-in-time
recovery; source projections must be rebuilt after data loss. Before public
production, split API and worker roles, adopt managed PostGIS with recovery, and
review edge authentication, availability, capacity, and operational ownership.
