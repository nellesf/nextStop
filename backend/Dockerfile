FROM node:24-alpine3.24 AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.build.json eslint.config.mjs ./
COPY src ./src
COPY migrations ./migrations
COPY operations ./operations

RUN npm run build \
    && mkdir -p dist/migrations \
    && cp migrations/*.sql dist/migrations/ \
    && mkdir -p dist/operations \
    && cp operations/*.sql dist/operations/ \
    && npm prune --omit=dev

FROM node:24-alpine3.24 AS runtime

ENV NODE_ENV=production
WORKDIR /app

# Alpine's supported PG17 client avoids server packages and Debian's Perl wrappers.
# Preserve the versioned tool paths used by the backup and migration entrypoints.
RUN apk upgrade --no-cache \
    && apk add --no-cache ca-certificates postgresql17-client \
    && mkdir -p /usr/lib/postgresql/17/bin \
    && for tool in psql pg_dump pg_restore; do \
         path="$(command -v "$tool")"; \
         case "$("$path" --version)" in "$tool (PostgreSQL) 17."*) ;; *) exit 1 ;; esac; \
         ln -s "$path" "/usr/lib/postgresql/17/bin/$tool"; \
       done \
    && rm -rf /usr/local/lib/node_modules/npm "/opt/yarn-v${YARN_VERSION}" \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg

COPY --from=build --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist

USER node
# These execute in the final image as the same unprivileged user used in production.
# A libc/dependency/tool regression fails the build before the security scan/push.
RUN node --input-type=module -e '\
      import assert from "node:assert/strict"; \
      import { gzipSync, gunzipSync } from "node:zlib"; \
      await Promise.all(["@google-cloud/storage", "@google-cloud/tasks", "google-auth-library", "node-app-attest", "pg", "fastify", "cbor", "csv-parse", "osm-pbf-parser-node"].map(name => import(name))); \
      assert.equal(gunzipSync(gzipSync(Buffer.from("runtime-smoke"))).toString(), "runtime-smoke"); \
      assert.equal(new Intl.DateTimeFormat("de-DE", { timeZone: "Europe/Berlin", year: "numeric" }).format(new Date("2026-01-01T00:00:00Z")), "2026"); \
      assert.equal(process.getuid(), 1000);' \
    && /usr/lib/postgresql/17/bin/psql --version \
    && /usr/lib/postgresql/17/bin/pg_dump --version \
    && /usr/lib/postgresql/17/bin/pg_restore --version \
    && ! command -v npm \
    && ! command -v yarn

EXPOSE 3000

CMD ["node", "dist/src/server.js"]
