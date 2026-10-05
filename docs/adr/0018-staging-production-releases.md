# ADR 0018: Separate environments and compatible production releases

- Status: Accepted
- Date: 2026-10-01
- Owner authorization: the staging/production concept and the smaller two-VM
  implementation were approved in the implementation conversation on 2026-10-01.

## Context

The existing private TestFlight service runs on one VM and database. The
2026-09-30 import incident showed that resource contention can make the published
search corpus unavailable even when projection publication is atomic. Development
and release testing must be isolated from that service. Routine application
releases should keep the published search available while a candidate is checked.

The owner selected the smaller implementation within a EUR 200/month combined
budget. The existing VM/database stays in place as production; one separate
staging VM is added. The planning estimate is EUR 155–175/month on the same tax
basis as the owner's reported current EUR 72/month. It is an estimate, not a hard
billing cap. Report expected overruns to the owner; do not automatically shut down
or remove services in response to a budget alert.

## Decision

[ADR 0020](0020-cloud-run-cloud-sql-staging.md) subsequently replaces staging
hosting with Cloud Run and Cloud SQL. Production topology and the isolation,
compatibility, immutable-artifact and explicit-promotion requirements below
remain in effect.

Run one `e2-standard-2` VM per environment in Frankfurt (`europe-west3-a`), each
with its own local PostgreSQL/PostGIS database and persistent data/cache disk.
Each VM runs separate API, App Attest auth, singleton ingestion-worker and
release-scoped migrator processes from one backend artifact. Nginx terminates TLS;
PostgreSQL has no public listener and administrative SSH uses IAP.

| Environment | Google Cloud project | VM | Public API |
| --- | --- | --- | --- |
| Production | `nextstop-tech-staging` (historical ID) | `nextstop-backend` | `https://api.nextstop.tech` |
| Staging | `nextstop-tech-testing` | `nextstop-backend` | `https://api-staging.nextstop.tech` |

The existing production VM, database, persistent volumes, App Attest records,
report-withdrawal state and keys remain in place. There is no production database
move or production DNS cutover. The historical project ID is retained deliberately;
it no longer describes that environment's role. Staging has independent database
credentials, token/signing keys, authentication state, support storage and caches.
Seed it only with public provider data, never production authentication records,
report payloads, deletion proofs or operational secrets.

The approved scope has no managed database, load balancer, redundant API hosts or
separate worker VM. This decision replaces the managed-database production target
and migration prerequisites described in ADR 0014 for this deployment phase.
Changes to that topology require a separate owner decision. Environment settings
are committed; private configuration and credentials are not.

Keep the central immutable image repository in `nextstop-tech-staging` and record
its project independently of the staging compute project. Backend changes pass
unit, contract, provider and real PostGIS tests. Trusted main commits produce a
commit-tagged image in a repository that enforces immutable tags. A rerun reuses
the exact verified digest; registry errors must not be interpreted as a missing
image. Deploy that artifact to staging first. Production promotion is an explicit
protected workflow selecting a successfully staged commit and its identical image
digest. Keep the API compatible with deployed app versions.

Before production DDL, require a successful recent backup of that exact local
database in the private production GCS backup bucket. Bind its receipt to the
project, VM/database, object generation and release image. Exclude submitted report
payloads from durable application backups as required by the existing report
retention policy. Verify recovery in an isolated database; do not restore over
production as part of an application rollback. Disposable staging needs no copy
of private production state.

Serialize migrations, use short lock waits and finite statement budgets, and
permit only classified additive/compatible migrations in automatic releases.
Removal or incompatible schema work requires a separate staged plan. Start the
candidate API and auth processes beside the serving version on the same VM,
verify readiness and authenticated synthetic searches, then reload Nginx
gracefully. Let existing requests drain, retain the previous version for rollback,
and replace the singleton worker only after serving checks pass. Application
rollback does not reverse DDL or rebuild the database.

Use one iOS bundle ID. Debug Simulator presets bind staging/production APIs to
the corresponding IAP token broker. Every physical-device build and every archive,
including TestFlight, targets production. There is no separate Dev app or runtime
environment picker. App Attest remains configured by signing environment;
production does not automatically accept development attestations. Partition
backend-bound local capabilities, tokens and search snapshots by backend origin.

## Consequences

Environment isolation protects production from staging work. Parallel application
slots avoid an intentional API restart gap during compatible releases. One VM and
one local database per environment remain a single failure domain, and production
ingestion can still contend for the same VM/database resources. The chosen scope
does not provide automatic failover or guarantee continuous availability. Retain
complete published projections during imports, bound resource use, and monitor
aggregate latency, errors, import duration and source freshness.

The environment split does not change search, EVSE, geographic, availability,
routing, privacy or licensing policies. Never retain precise routes or
credentials in release probes/logs. App Store/public support-report distribution
still requires the existing privacy, signing and CarPlay gates. Infrastructure and
protected release activation remain subject to their operational verification.
