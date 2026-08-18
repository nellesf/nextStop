FROM node:24-bookworm-slim AS build

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

FROM node:24-bookworm-slim AS runtime

ENV NODE_ENV=production
WORKDIR /app

COPY --from=build --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist

USER node
EXPOSE 3000

CMD ["node", "dist/src/server.js"]
