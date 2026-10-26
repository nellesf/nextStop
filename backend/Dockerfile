FROM node:24-alpine3.24 AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.build.json eslint.config.mjs ./
COPY src ./src
COPY migrations ./migrations

RUN npm run build \
    && mkdir -p dist/migrations \
    && cp migrations/*.sql dist/migrations/ \
    && npm prune --omit=dev

FROM node:24-alpine3.24 AS runtime

ENV NODE_ENV=production
WORKDIR /app

RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm "/opt/yarn-v${YARN_VERSION}" \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg

COPY --from=build --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist

USER node
RUN node --input-type=module -e '\
      import assert from "node:assert/strict"; \
      import { gzipSync, gunzipSync } from "node:zlib"; \
      await Promise.all(["node-app-attest", "pg", "fastify", "cbor", "csv-parse", "osm-pbf-parser-node"].map(name => import(name))); \
      assert.equal(gunzipSync(gzipSync(Buffer.from("runtime-smoke"))).toString(), "runtime-smoke"); \
      assert.equal(new Intl.DateTimeFormat("de-DE", { timeZone: "Europe/Berlin", year: "numeric" }).format(new Date("2026-01-01T00:00:00Z")), "2026"); \
      assert.equal(process.getuid(), 1000);' \
    && ! command -v npm \
    && ! command -v yarn

EXPOSE 3000

CMD ["node", "dist/src/server.js"]
