# nextStop backend

Strict TypeScript/Fastify modular-monolith scaffold for the versioned charging-park
candidate API.

## Current behavior

- `POST /v1/charging-parks/search` validates the accepted request contract.
- Candidate search requires a configured bearer credential; `/health` remains
  public for load-balancer and container liveness checks.
- Unknown fields are rejected, including profile names and destination text that
  must remain on-device.
- Route requests are bounded by body size, point count, supported region, segment
  length, total length, and concurrent-search admission before PostGIS work runs.
- A missing charging-data projection returns `503 application/problem+json`; it is
  never represented as an empty successful result.
- `GET /health` reports process health only. It does not claim provider or
  projection readiness.
- Migrations, HTTP search, and provider refresh run as separate process roles from
  one artifact. The worker immediately refreshes the official Bundesnetzagentur
  and Swiss `ich-tanke-strom` feeds without manual seed data; the API never runs
  DDL or ingestion.
- Static data is published as an atomic combined PostGIS projection. Swiss live
  status is published independently as an atomic, freshness-limited snapshot.
- Publication also builds power-filtered park summaries for every supported filter
  value and normalized park/location memberships. Search uses those summaries,
  exact geography `ST_DWithin` for the inclusive 5 km route corridor, and a safe
  straight-line upper-bound rejection before selecting a page.
- Search joins live state by provider EVSE identity only after page selection and
  only for informational presentation.

## Commands

```bash
npm ci
npm run lint
npm run typecheck
npm run build
npm test
npm run test:integration
npm run refresh:providers
npm run db:migrate
npm run dev
npm run dev:worker
```

`npm run refresh:providers` is an explicit operational run. `npm run dev` starts
only the HTTP API and `npm run dev:worker` starts the scheduled provider
coordinator. Staging gives the API a table-scoped read-only database login, the
worker a DML-only login, and reserves the owner login for `npm run db:migrate`.
The API fails at startup unless `SEARCH_API_BEARER_TOKEN` contains at least 32
bytes without whitespace.

Node.js 24 LTS is pinned through `package.json`; exact package versions are locked
in `package-lock.json`.
