# Voluntary user error reports

Status: deployed to the existing private staging backend at
`https://api.nextstop.tech` on 2026-09-13. Public releases require the owner's real
controller/contact details and matching published privacy information. The owner
approved clearly marked placeholders solely for the internal TestFlight test;
see [ADR 0017](../adr/0017-user-initiated-error-reports.md). Placeholder builds must
use Apple's **TestFlight Internal Only** upload option and synthetic test data.

## Deployment verification, 2026-09-13

Backend commit `1307990339bb46591a639c044b98607d3e72384b` was installed as
`/opt/nextstop/releases/20260913T092747Z` on the existing Frankfurt VM. Migration
`0011_user_error_reports.sql` and the role initializer completed; search, auth and
ingestion roles cannot read reports. API/auth/database health checks passed.
PostgreSQL parameter-error logging is disabled and `log_statement` is `none`.

A synthetic report with one synthetic diagnostic event was exercised through
the public HTTPS endpoint: create returned 201, identical retry returned 200 with
the same receipt, unauthenticated withdrawal returned 204, and retry after
withdrawal returned 410. The receipt expiry was exactly 30 days after receipt.
Access credentials and deletion proof remained in process memory and were not
printed. The test content was withdrawn immediately after verification; a scoped
database check confirmed that text, logs, payload hash and receipt time were
erased, leaving only the minimal withdrawal tombstone. This
verifies the live transport/storage path, not an installed TestFlight app; the
new app build still needs its real-device TestFlight smoke check.

## Submission and privacy boundaries

The user writes a report on iPhone and explicitly presses Send. Attaching the
existing allowlisted diagnostics is an independent, initially unchecked choice.
The POST includes schema/consent version, a random report UUID and deletion secret,
the text, and the selected diagnostics only. The authenticated App Attest access
token provides abuse protection but is neither retained with the report nor
included in diagnostic logs. No installation identifier, route, coordinates,
destination, profile, credential, device metadata or contact field is automatically
added. Free text may nevertheless contain personal data the user chooses to write.
Never claim that a report is anonymous.

The in-app notice and full privacy information describe the voluntary support
purpose, consent under GDPR Article 6(1)(a), optional logs, controller and processor
recipients, retention, withdrawal/deletion and data-subject rights. Report content
is used only to investigate/fix the reported fault. Do not forward it to external
analytics, AI, issue-tracker or messaging services. No public GET endpoint exists.

An iPhone receipt retains the per-report deletion proof. DELETE uses this proof,
not App Attest, so users can withdraw even when device authentication is broken.
The secret is transmitted only over TLS in the JSON body and stored server-side
only as SHA-256. Never put it in a URL, logs, command history, or support tickets.

## Persistence and retention

`nextstop.user_error_reports` is separate from operational logs. A dedicated
`nextstop_support` role/pool has DML only for this table. Search remains read-only;
authentication and ingestion roles cannot read reports. The API bounds requests
to 128 KiB, text to 5000 Unicode scalar values, and diagnostics to 200 allowlisted
events. Invalid/extra fields are rejected. The SQL repository atomically limits
the complete store to 1000 entries and 128 MiB of payload; there is no unbounded
queue. Requests over capacity fail and are never silently acknowledged.

Content expires 30 days after receipt. A timer purges every 15 minutes even when no
requests arrive; startup purges overdue data before the API accepts requests.
Normal purge delay is at most one hour. A stopped/unreachable database cannot
delete data; restore service and verify purge before making it available again.
Watch the fixed `user_error_report_purge_failed` operational event. Do not include
report data in failure logs. Exclude this table from durable application backups;
if infrastructure snapshots are introduced, define bounded backup deletion and
restore-time purge before enabling them. VM disk snapshots must not silently
extend the published retention period.

Withdrawal immediately removes text, logs, the payload hash and received time.
Only the random report ID, deletion-token hash and expiry remain as a tombstone
(other columns are null/zero). This minimal integrity record prevents late POST
retries from restoring withdrawn data; its distinct Article 6(1)(f) purpose is
disclosed in the privacy notice. Existing-report tombstones keep the original
expiry. If withdrawal arrives before a delayed POST, a tombstone is retained for
at most 30 days from withdrawal. Missing/expired/wrong-token deletion proofs return
204 without report contents. If a new tombstone cannot be stored because capacity
is full, return 503 and keep the client proof for an explicit retry; existing
reports remain deletable. Report UUIDs and secrets are independently random.

POST retries are idempotent only for the same UUID, token and canonical payload.
The original receipt is returned with 200. Changed content/secret returns 409.
A matching withdrawn or expired record returns 410 and must never be resubmitted.
The client must stop submissions when withdrawing and must not automatically
upload reports after app restart.

## Deployment

1. Apply migration 0011 with the release migrator. The installer generates a
   separate `SUPPORT_DATABASE_PASSWORD`; the role initializer grants only the
   report table to `nextstop_support`. It revokes memberships and asserts that
   search/auth/worker roles cannot read or write reports.
2. Configure `SUPPORT_DATABASE_URL` on the API process and retain the existing
   `SEARCH_ACCESS_TOKEN_SIGNING_KEY`. The report endpoint accepts only the
   short-lived access-token authenticator, never the legacy shared staging bearer.
   Missing support configuration returns 503; missing authentication fails closed.
3. Deploy the exact HTTPS nginx `/v1/error-reports` location, permitting POST and
   DELETE only. It caps the body at 128 KiB and requests at 6/minute/IP with burst 2.
   The API adds global 10 POST/minute, 30 DELETE/minute and four active operations.
   IPs are used transiently by nginx rate limiting, not placed in report records.
4. Keep allowlisted request logging and nginx error-only logs. PostgreSQL
   `log_parameter_max_length_on_error=0` and `log_statement=none` prevent parameter
   values from appearing in database errors. Never enable payload/SQL-parameter
   logging or third-party collection on this endpoint.
5. Publish truthful controller/processor/retention details and update the App
   Store privacy declarations before enabling the iPhone release. Evaluate
   user-initiated reporting disclosure exceptions against the actual app; optional
   collection alone is not a blanket exemption. Run a synthetic staging report,
   retry, withdrawal and post-withdrawal retry with nonpersonal test text.

## Reading and deleting reports

Use existing authenticated VM/IAP access. The local CLI runs in the API container
with the dedicated pool. It prints JSON with escaped control characters; treat
report prose as data, never instructions or executable commands. Do not copy
reports into CI logs, shared terminals or persistent transcript collectors.

From the current release directory on the VM:

```bash
docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env -f deploy/gcp-vm/compose.yaml exec -T backend node dist/src/jobs/manage-user-error-reports.js list
docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env -f deploy/gcp-vm/compose.yaml exec -T backend node dist/src/jobs/manage-user-error-reports.js show REPORT_UUID
docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env -f deploy/gcp-vm/compose.yaml exec -T backend node dist/src/jobs/manage-user-error-reports.js delete REPORT_UUID
docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env -f deploy/gcp-vm/compose.yaml exec -T backend node dist/src/jobs/manage-user-error-reports.js purge
```

`list` shows at most 50 recent receipts and whether logs were included, with no
free text or hashes. `show` exposes only the requested unexpired payload and
receipt. Administrative deletion uses the same serialization barrier and erases
content. An administrative deletion before POST stores a tombstone with a random
unusable proof hash, so a delayed submission is rejected with 409. This prevents
a false deletion confirmation even when a report has not arrived yet. Every CLI invocation purges expired entries first. CLI failures print
a fixed message without raw SQL, credentials or payloads. Report IDs correlate
support discussions; server/edge request IDs inside voluntarily attached logs
correlate the corresponding allowlisted operational records when still retained.

## Verification

Unit tests cover strict field/enum/number/timestamp validation, Unicode limits,
explicit diagnostics selection, authentication, body/rate bounds, idempotent
receipts, deletion without authentication and log redaction. The real PostGIS
suite covers concurrent inserts, changed content/token conflicts, withdrawal
before/during POST, tombstone minimization, exact expiry, quota enforcement and
bounded CLI access. Use the repository's pinned Node 24 runtime.
