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

There is intentionally no charging provider or PostGIS repository in this slice.
The next slice adds the Bundesnetzagentur adapter, migrations, and exact
`ST_DWithin` corridor query.

## Commands

```bash
npm ci
npm run lint
npm run typecheck
npm run build
npm test
npm run test:integration
npm run dev
```

Node.js 24 LTS is pinned through `package.json`; exact package versions are locked
in `package-lock.json`.
