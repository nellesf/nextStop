# Request diagnostics

Candidate search and App Attest emit a single structured completion record for
each request handled by their API process. The entrypoints enable this dedicated
stdout sink. Fastify automatic request/error logging remains disabled, as do the
raw nginx application access logs. A separate nginx format records only HTTP
errors with the allowlist below. Do not turn on raw request, body, header, SQL, or
error-object logging while investigating an incident. These diagnostics require
a release deployment; they cannot reconstruct earlier incidents.

## Record contract

```json
{
  "event": "http_request_completed",
  "timestamp": "2026-09-11T06:49:15.000Z",
  "service": "candidate_api",
  "route": "charging_park_search",
  "requestId": "11111111-2222-4333-8444-555555555555",
  "status": 500,
  "durationMs": 15001,
  "errorCategory": "database_query_canceled"
}
```

- `timestamp` is the completion time in UTC. `durationMs` is elapsed monotonic time,
  rounded to a nonnegative integer, so wall-clock corrections do not distort it.
- `service` is `candidate_api` or `auth_api`.
- `route` is one of `health`, `charging_park_search`, `app_attest_challenge`,
  `app_attest_attestation`, `app_attest_assertion`, or `unknown`. Unknown paths and
  query strings are never copied into the record.
- `requestId` is a new server-generated UUID for this HTTP request. The same value
  is returned in `X-Request-ID` on success and failure. Supplied `X-Request-ID` and
  `Request-ID` headers are ignored. The body request ID, snapshot token, App Attest
  key, and installation are not associated with this identifier in the log.
- `status` is the completed HTTP response status. Existing response statuses and
  problem bodies are unchanged; their legacy `errorId` is a separate identifier.
- `errorCategory` is an explicit enum. Successful requests use `none`.

No record contains bodies, coordinates, routes, destination text, criteria,
headers, cookies, client IPs, user agents, tokens, cryptographic material, key IDs,
raw error messages, or stack traces. Do not add these fields to the sink or use
the request ID as a persistent user identifier. Error classification inspects
only fixed error types/codes and, for node-postgres's uncoded client deadline,
the exact library message; the inspected values are never emitted.

## Interpreting failures

| Category | Meaning |
|---|---|
| `invalid_request`, `body_too_large` | Schema, semantic, parser, or body-size rejection |
| `unauthorized` | Missing/rejected access token or rejected App Attest proof |
| `capacity_limited` | API concurrency or App Attest rate admission rejected the request |
| `projection_unavailable`, `food_projection_unavailable` | Charging or restaurant projection is unavailable |
| `snapshot_invalid` | Candidate pagination/snapshot validation failed |
| `app_attest_key_missing`, `app_attest_counter_conflict` | Existing actionable App Attest key/counter conditions |
| `database_query_canceled` | PostgreSQL SQLSTATE 57014: query canceled, including statement deadlines; this code alone does not prove which cancellation source fired |
| `database_timeout` | node-postgres client-side query deadline |
| `database_connection` | PostgreSQL connection/session/startup failure |
| `database_capacity` | PostgreSQL reports too many connections |
| `dependency_connection` | A fixed system connection error such as reset, refusal, or timeout; the record does not assume which dependency failed |
| `not_found`, `conflict`, `unavailable` | Other explicit HTTP 404, 409, or 503 outcome |
| `unexpected` | Failure outside the allowlist; no raw exception is retained |

Classification is diagnostic only. It never changes authentication, status codes,
candidate filtering, pagination, or retries. A broken diagnostic sink cannot
replace an HTTP response.

## Proxy errors and correlation

Nginx records only completed HTTP 4xx/5xx requests in
`/var/log/nextstop/nginx-errors.jsonl`. Successful requests and redirects are omitted
at the proxy. API completion records include successes so an operator can establish
whether a retry succeeded and compare server processing time without retaining
request contents. Neither format records a persistent device or user identifier.

```json
{
  "event": "http_edge_error",
  "timestamp": "2026-09-11T06:49:15+00:00",
  "route": "charging_park_search",
  "edgeRequestId": "0123456789abcdef0123456789abcdef",
  "upstreamRequestId": "",
  "status": 429,
  "durationSeconds": 0.001,
  "errorCategory": "capacity_limited"
}
```

- `timestamp` includes the proxy host's explicit timezone offset; use UTC for the
  incident window. `durationSeconds` is nginx's numeric elapsed request time with
  millisecond resolution, including time receiving and responding to the client.
- `route` uses the same fixed endpoint labels as the API, with `unknown` for every
  other path. Raw paths, query strings, incoming headers, and client IPs are absent.
- `edgeRequestId` is nginx's generated 32-character hexadecimal request ID. It is
  returned in `X-Edge-Request-ID`, including proxy rejections. Incoming correlation
  headers never supply either generated ID.
- `upstreamRequestId` is the local API's `X-Request-ID` response value, accepted
  only when it matches a UUID v4. It links an API error to the proxy error. An empty
  value means no valid API response ID was available, including proxy admission
  rejections and failures to reach the API; it does not prove the API did no work.
- `errorCategory` is a fixed status classification. For example, 429 is
  `capacity_limited`, 502 is `upstream_failure`, 504 is `upstream_timeout`, and 499
  is `client_closed`. The status alone cannot identify the failing dependency or
  distinguish proxy admission from API admission; use the API record when present.

Keep the API UUID and edge hexadecimal ID as separate fields. A transport failure
with no HTTP response can have neither ID on the client. TLS failures before an
HTTP request and abrupt process termination may produce neither completion event.
Existing general nginx/PostgreSQL/system error logs are outside this allowlist and
may contain sensitive values; inspect them privately and sanitize any excerpt.

The release/TLS installers install the format before `nginx -t` and enable a
dedicated logrotate policy outside Ubuntu's `/var/log/nginx/*.log` rotation. The
directory is mode 0750 and files 0640, limited to nginx and administrators. Rotation
is daily, with a 10 MB early-rotation threshold, at most seven archives, and a
seven-day maximum archive age checked on rotation. Size/age checks run when the
system logrotate job runs; they are not hard real-time size or retention limits.
The active file can grow past 10 MB between checks. Rotation uses nginx's reopen
signal and does not truncate an open file or erase retained errors on deployment.

## Investigating an incident

1. Convert the reported local time to UTC, retaining the original timezone and
   daylight-saving offset. Start with a narrow window of a few minutes.
2. Obtain the reported `X-Request-ID` when the app received an HTTP response. Search
   the API completion records for that exact UUID and compare status, duration,
   and category. Every retry is a different HTTP request and receives a fresh UUID.
3. Use the documented IAP access in the deployment runbook. In the current release
   directory, read the bounded Docker window:

   ```bash
   sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env \
     -f deploy/gcp-vm/compose.yaml logs --no-color --no-log-prefix \
     --since 2026-09-11T06:47:00Z --until 2026-09-11T06:51:00Z backend auth-backend
   ```

4. Check the dedicated nginx JSON error log and retained rotations for the same
   window, correlating `upstreamRequestId` with the API UUID or `edgeRequestId`
   with the app's `X-Edge-Request-ID` when available. If neither identifies the
   failure, inspect container lifecycle metadata and existing nginx/PostgreSQL/
   system error logs in the same narrow window. Export only sanitized timing,
   status, and error categories. PostgreSQL statement logs may contain the precise
   route and general nginx error logs may contain client IPs; do not attach raw
   records to an issue.
5. A completed search can be followed by a client-side MapKit failure. The API
   completion event proves only that this HTTP request completed, not that the
   whole ride search or Maps handoff succeeded.

The current staging Docker policy rotates five files of 10 MB per service. This
is a size limit, not a guaranteed number of days. Check retention before drawing
conclusions. Requests rejected at nginx, failed TLS connections, malformed HTTP
before Fastify routing, client transport failures, and process termination before
completion may have no API completion record. Missing records do not prove that
the server or network was healthy. Records from before this diagnostic feature
was deployed cannot be reconstructed retrospectively.

## Validation

The request-diagnostics unit suite injects the sink and both clocks. It verifies
the exact allowed fields, UTC/integer timing, fresh server UUIDs, header spoofing,
success and failure statuses, admission/authentication outcomes, database error
classification, and sink-failure isolation. Sentinel values in request/response
bodies, query strings, unknown paths, headers, IPs, proofs, tokens, and exception
details must never appear in output.

The nginx diagnostics unit suite checks the interpolated-variable allowlist,
fixed endpoint mappings, strict upstream UUID validation, error-only selection,
response-header inheritance for local rejections, installer order, private file
permissions, and bounded rotation. These are static configuration/privacy checks;
they do not replace `nginx -t` against the target nginx build before reload.
