# nextStop backend

Strict TypeScript/Fastify modular-monolith scaffold for the versioned charging-park
candidate API.

## Current behavior

- `POST /v1/charging-parks/search` validates the accepted request contract.
- Unknown fields are rejected, including profile names and destination text that
  must remain on-device.
- Degenerate route geometry is rejected before it reaches the application port.
- A missing charging-data projection returns `503 application/problem+json`; it is
  never represented as an empty successful result.
- `GET /health` reports process health only. It does not claim provider or
  projection readiness.
- With database configuration present, pending migrations run at startup and the
  provider coordinator immediately refreshes the official Bundesnetzagentur and
  Swiss `ich-tanke-strom` feeds without manual seed data.
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
npm run dev
```

`npm run refresh:providers` is an explicit operational run; normal server startup
performs the same refresh in the background. `INGESTION_ENABLED=false` disables
that coordinator for a separately managed API process role.

Node.js 24 LTS is pinned through `package.json`; exact package versions are locked
in `package-lock.json`.
