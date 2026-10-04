# ADR 0019: Monthly staging imports and demand-driven availability

- Status: Accepted for staging
- Date: 2026-10-04
- Owner authorization: implement the discussed monthly static imports and live
  availability on demand in staging, validate costs early, and do not exceed the
  previous staging cost. The owner supplied approximately EUR 70/month.

## Decision

Enable the change only through staging configuration. Keep the existing VM,
PostgreSQL/PostGIS, disks, domain, authentication and release isolation. Production
retains its existing configuration. Any subsequent hosting migration has its own
cost comparison and access prerequisites; this change does not provision a new
database, container service, load balancer, queue or paid scheduler.

Charging and OSM static imports run once per calendar month, sequentially, starting
on the first at 02:00 UTC. A database schedule survives restarts and unchanged
downloads. Enabling the policy on an existing corpus schedules the next month;
an empty database can bootstrap immediately. Failed source refreshes retain the
published projection and retry no earlier than the following day. Timers are
bounded below Node's maximum delay. Existing download caches are reused. Derived
search retention runs daily in bounded batches in this mode. Support deletion
continues independently under ADR 0017.

There is no periodic Swiss live download in demand mode. The normal candidate
search remains read-only and returns immediately from the published corpus,
including an optional signed availability context. Its one-hour lifetime binds
the static projection, power threshold and campus/fine-park mode, without a route,
profile, destination or installation identity. The context is stable across pages.

After displaying results, the app requests optional availability for the surviving
candidate IDs and exact confirmed operator names. The API recomputes deduplicated,
power-qualified availability only for that selection. It cannot restore an
Apple-excluded operator or change candidate membership, counts, distances,
restaurant grouping, order, selection or original Apple lookup evidence. iPhone
and CarPlay use a separate display overlay and discard abandoned-search updates.

Only an actual selected Swiss EVSE can trigger a refresh. A fresh shared database
snapshot serves concurrent requests. Data older than 60 seconds can request a
refresh; data older than 300 seconds is unknown. The secondary endpoint sends a
bounded private acknowledgement request to the worker; it never waits for provider
download or database publication. The worker uses a database-wide lease spanning
download and publication, a shared cooldown and a publication fencing check.
Failures retain old data without inventing freshness. With no demand, no live
download occurs. App retries are bounded and availability failure never fails search.

This narrowly amends the listenerless-worker boundary for opt-in staging: the
worker exposes a Docker-internal authenticated refresh signal on port 8091.
The port is not published and accepts only the fixed Swiss provider identifier.
A dedicated random secret is shared only with the API and worker. Candidate DB
credentials stay read-only; only the worker can modify scheduling/lease tables.
The public secondary endpoint uses existing search authentication, body and
concurrency limits, and redacted diagnostics. Requests and selected IDs are not
stored as jobs or logged.

The current public national Swiss feed remains the source. The BFE API documented
for November 2026 is not assumed available and is not enabled by this change.

## Cost and release consequences

The VM and disk allocation is unchanged, so fixed provisioned infrastructure
charges do not increase or decrease. Reduced background work is not a claimed
VM-bill saving. Usage-dependent charges and billing lag still need observation.
Do not describe a list-price inventory estimate as an actual invoice comparison.
Record baseline inventory and the owner's cost figure before deployment.

Stage a tested immutable branch artifact through the existing readiness/search
gates. This permits the requested staging experiment without merging the feature
branch into main. It is not eligible for production promotion until the ordinary
main/staging verification rules and explicit owner instruction are satisfied.
Additive migrations preserve prior readers/writers and application rollback.

Verify no idle live polling, one download for concurrent Swiss demand, no download
for German-only demand, unknown status on failure/staleness, durable monthly dates,
read-only API grants, and unchanged search results before calling staging complete.
