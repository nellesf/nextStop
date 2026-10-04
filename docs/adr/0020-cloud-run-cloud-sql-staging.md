# ADR 0020: Cloud Run and small Cloud SQL for staging

- Status: Accepted for staging
- Date: 2026-10-04
- Owner authorization: continue with the small Cloud SQL option in staging after
  comparing Google Cloud, Neon, and Kubernetes cash costs. Keep the monthly cost
  below the previous approximately EUR 70. Report a projected overrun and ask;
  do not automatically dismantle the deployment.

## Decision

Replace the staging VM in `nextstop-tech-testing` with request-billed Cloud Run
services and a zonal PostgreSQL 17 Cloud SQL Enterprise `db-g1-small` instance
with 50 GiB SSD in `europe-west1`. PostgreSQL/PostGIS remains the system of record.
Cloud Run scales idle application instances to zero. The database remains running;
it does not automatically resize with demand. Cold starts and database resizing
can delay requests; this decision does not introduce a production availability
guarantee. Production in the historically named `nextstop-tech-staging` project
retains its VM, database, domain, credentials and release process.

The public gateway has no database or signing secrets. API, App Attest, live
refresh and developer token services have separate Google identities and are
protected by Cloud Run IAM. The gateway can invoke only API and authentication.
It forwards application authorization independently of its Google identity token.
Each release pins the API/auth revision URLs and the corresponding service
audiences, preserving previously serving gateways during candidate verification.
Only the gateway is public. The Simulator's local broker obtains a short-lived
token through the IAM-only staging token service using the developer's Google
login. Device and TestFlight configuration continues to target production.

Cloud SQL requires the authenticated connector, has no authorized public IP
networks, and exposes separate owner/API/auth/support/worker/backup credentials.
The API's candidate-search role remains read-only. Runtime identities cannot
fetch one another's secret credentials. Small bounded connection pools release
idle sessions. There is no shared transaction pooler that could break session
locks or temporary tables. SQL and application logs must not retain credentials,
precise routes, or report contents; raw Cloud Run request logs are excluded before
public access is granted.

The monthly schedule and demand-driven availability policy from ADR 0019 stay in
force. A daily job checks monthly due dates and executes only due imports. Across
charging and OSM together it admits at most three heavy attempts in a UTC month,
each with an eight-hour deadline and no automatic Cloud Run execution retry.
Failed imports retain the published data. A private GCS cache streams provider
objects and pins object generations; it does not load PBF files into ephemeral
container memory. Cache objects have bounded retention; an expired object causes
a validated download at the next due import rather than fabricated freshness.

Swiss demand enqueues only the fixed provider identifier through Cloud Tasks.
The private task handler completes download, atomic publication and lease cleanup
before acknowledging success. The existing shared lease/cooldown/fencing rules
remain authoritative. Failed attempts are retried at most three times, with
backoff longer than the ten-minute lease. No routes, candidate IDs or user state
are stored in tasks. No demand means no Swiss polling.

The existing cleanup job runs hourly and performs bounded expired availability
retention before bounded derived-search retention. Expired-data deletion is
outside the live handler's publication and acknowledgement path; it cannot turn
an already published refresh into a failed task merely because cleanup is slow.
The cleanup job visits at most 64 expired snapshot targets within 120 seconds, then
at most 32 batches of 1000 retired search rows, within its 300-second application
deadline. Large snapshots can continue across runs, so observed backlog and
throughput remain acceptance checks. This changes no freshness threshold and
adds no service or job. A separate job performs at least hourly report expiration,
including when the application has no traffic. Daily logical
backups exclude the entire report table using a role without report SELECT.
A catalog-only DDL supplement restores the empty report table. Pin archive and
supplement generations/hashes in a completion receipt; retain successful backups
for seven days. Cloud SQL full-instance backups and PITR remain disabled because
they would retain report payloads outside ADR 0017's deletion boundary.

## Release and migration gates

Transfer only existing staging state, never private production data or keys.
Validate and restore a filtered snapshot into the empty target before switching
traffic. Fence old staging writers for the final handoff and preserve any changed
staging authentication or withdrawal state. Validate schema, grants, published
projection identity and real authenticated synthetic searches on the full corpus.
Health endpoints alone are insufficient. Measure query latency and import
resource use on the small instance before declaring the capacity adequate.

Keep immutable images, trusted-main CI checks, expand-only migrations, candidate
verification, explicit production promotion and application rollback. Pause
staging schedules during release changes; apply migrations and object grants
before promoting candidate traffic. Require live evidence for IAM, client-IP
admission isolation, filtered restore and live-task compatibility. A new backend
artifact is not production-approved merely because it runs in staging.

Use the existing staging domain after its Google ownership and DNS records are
verified. Preserve a tested recovery path before removing the old VM and disks;
stopping the VM alone leaves disk/address charges. After accepting writes on the
new database, the old snapshot is not a lossless data rollback.

## Cash costs

The dated EUR list-price model in `deploy/gcp-run/cost.py` uses approximately
EUR 29.964/month for the database at 730 hours. Application execution, imports,
backup execution/storage, cache, registry, four schedules, secrets and network
are additional. Scenarios including a 10% reserve are approximately
EUR 42.04–59.13 net per month (EUR 50.02–70.36 with illustrative 19% VAT).
The hourly cleanup estimate covers 720 monthly invocations at 60–300 seconds each,
replacing the earlier daily cleanup allowance; startup variation uses the reserve.
These are estimates, not billing-export evidence or enforced spending caps.
On 2026-10-04 the operator verified EUR 6.80 of pre-tax Google Cloud usage for the
staging project over October 1–3, with no credits. The 72-hour sample normalizes to
EUR 68.94 net at 730 hours; this is a comparison rate, not a full monthly invoice.
The period predates the Cloud SQL migration and does not establish actual costs
of the new runtime. Compare net model costs with that net baseline, keeping the
illustrative VAT-inclusive figures separate. Migration overlap is
temporary and must be reported separately; remove obsolete paid resources only
after successful migration and recovery verification. Reassess if measured usage,
capacity needs or prices move the forecast above the owner's baseline.

Kubernetes operational labor is not monetized in this comparison. The owner chose
Cloud SQL after a comparable-storage cash-cost comparison and preferred retaining
the infrastructure within Google Cloud. This ADR changes only staging hosting;
it does not change search rules, providers, privacy categories or production HA.
