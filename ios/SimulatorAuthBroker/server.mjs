#!/usr/bin/env node

import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import {
  expiryFromMintStart,
  responseWithRemainingLifetime,
} from "./token-cache.mjs";

const execFileAsync = promisify(execFile);
const host = "127.0.0.1";
const port = validatedPort(process.env.NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT ?? "9482");
const mode = validatedMode(process.env.NEXTSTOP_SIMULATOR_AUTH_MODE ?? "staging");
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = validatedIdentifier(
  process.env.NEXTSTOP_GCP_PROJECT ?? "nextstop-tech-staging",
  "NEXTSTOP_GCP_PROJECT",
);
const zone = validatedIdentifier(
  process.env.NEXTSTOP_GCP_ZONE ?? "europe-west3-a",
  "NEXTSTOP_GCP_ZONE",
);
const instance = validatedIdentifier(
  process.env.NEXTSTOP_GCP_INSTANCE ?? "nextstop-backend",
  "NEXTSTOP_GCP_INSTANCE",
);
const remoteMintCommand =
  "cd /opt/nextstop/current && " +
  "sudo docker compose --project-name gcp-vm " +
  "--env-file /etc/nextstop/backend.env " +
  "-f deploy/gcp-vm/compose.yaml run --rm --no-deps -T simulator-token-mint";

let cachedToken;
let refreshPromise;

async function accessToken() {
  const now = Date.now();
  if (cachedToken && responseWithRemainingLifetime(cachedToken, now)) {
    return cachedToken;
  }
  if (!refreshPromise) {
    refreshPromise = mintToken().finally(() => {
      refreshPromise = undefined;
    });
  }
  cachedToken = await refreshPromise;
  return cachedToken;
}

async function mintToken() {
  const mintStartedAt = Date.now();
  const stdout =
    mode === "staging" ? await mintStagingToken() : await mintLocalToken();
  const response = parseTokenResponse(stdout.trim());
  process.stdout.write("Refreshed the short-lived Simulator search credential.\n");
  return {
    response,
    expiresAt: expiryFromMintStart(mintStartedAt, response.expiresInSeconds),
  };
}

async function accessTokenResponse() {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const token = await accessToken();
    const response = responseWithRemainingLifetime(token, Date.now());
    if (response) {
      return response;
    }
    if (cachedToken === token) {
      cachedToken = undefined;
    }
  }
  throw new Error("Unable to mint a Simulator credential with a usable lifetime.");
}

async function mintStagingToken() {
  const { stdout } = await execFileAsync(
    "gcloud",
    [
      "compute",
      "ssh",
      instance,
      `--project=${project}`,
      `--zone=${zone}`,
      "--tunnel-through-iap",
      "--quiet",
      `--command=${remoteMintCommand}`,
    ],
    {
      encoding: "utf8",
      maxBuffer: 128 * 1024,
      timeout: 90_000,
    },
  );
  return stdout;
}

async function mintLocalToken() {
  const signingKey = process.env.SEARCH_ACCESS_TOKEN_SIGNING_KEY;
  if (
    typeof signingKey !== "string" ||
    Buffer.byteLength(signingKey, "utf8") < 32 ||
    /\s/u.test(signingKey)
  ) {
    throw new Error(
      "Local mode requires SEARCH_ACCESS_TOKEN_SIGNING_KEY with at least 32 bytes and no whitespace.",
    );
  }
  const command = resolve(
    repositoryRoot,
    "backend/dist/src/jobs/mint-development-access-token.js",
  );
  const { stdout } = await execFileAsync(process.execPath, [command], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      SEARCH_ACCESS_TOKEN_SIGNING_KEY: signingKey,
    },
    maxBuffer: 128 * 1024,
    timeout: 10_000,
  });
  return stdout;
}

function parseTokenResponse(value) {
  let decoded;
  try {
    decoded = JSON.parse(value);
  } catch {
    throw new Error("The staging token command returned an invalid response.");
  }
  if (
    !decoded ||
    typeof decoded !== "object" ||
    Array.isArray(decoded) ||
    Object.keys(decoded).sort().join(",") !==
      "accessToken,expiresInSeconds,tokenType" ||
    typeof decoded.accessToken !== "string" ||
    decoded.accessToken.length < 32 ||
    decoded.accessToken.length > 4_096 ||
    /\s/u.test(decoded.accessToken) ||
    decoded.tokenType !== "Bearer" ||
    !Number.isSafeInteger(decoded.expiresInSeconds) ||
    decoded.expiresInSeconds < 60 ||
    decoded.expiresInSeconds > 900
  ) {
    throw new Error("The staging token command returned an invalid response.");
  }
  return decoded;
}

const server = createServer(async (request, response) => {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  const forceRefresh = request.headers["x-nextstop-simulator-force-refresh"];

  if (
    request.method !== "POST" ||
    request.url !== "/token" ||
    request.headers["x-nextstop-simulator-auth"] !== "1" ||
    (forceRefresh !== undefined && forceRefresh !== "1") ||
    request.headers.origin !== undefined ||
    !isLoopbackHost(request.headers.host)
  ) {
    response.writeHead(404);
    response.end(JSON.stringify({ error: "not_found" }));
    return;
  }

  let receivedBody = false;
  request.on("data", () => {
    receivedBody = true;
    request.destroy();
  });
  request.on("end", async () => {
    if (receivedBody) {
      return;
    }
    try {
      if (forceRefresh === "1") {
        cachedToken = undefined;
      }
      const tokenResponse = await accessTokenResponse();
      response.writeHead(200);
      response.end(JSON.stringify(tokenResponse));
    } catch (error) {
      process.stderr.write(
        `Unable to mint a Simulator credential: ${safeErrorMessage(error)}\n`,
      );
      response.writeHead(503);
      response.end(JSON.stringify({ error: "credential_unavailable" }));
    }
  });
});

server.on("clientError", (_error, socket) => {
  socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
});

try {
  await accessToken();
  server.listen(port, host, () => {
    process.stdout.write(
      `nextStop Simulator authentication is ready at http://${host}:${port}.\n`,
    );
    process.stdout.write("Keep this process running while using the Simulator.\n");
  });
} catch (error) {
  process.stderr.write(
    `Unable to start Simulator authentication: ${safeErrorMessage(error)}\n`,
  );
  process.exitCode = 1;
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}

function validatedPort(value) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1_024 || parsed > 65_535) {
    throw new Error(
      "NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT must be an integer from 1024 through 65535.",
    );
  }
  return parsed;
}

function validatedMode(value) {
  if (value !== "staging" && value !== "local") {
    throw new Error("NEXTSTOP_SIMULATOR_AUTH_MODE must be staging or local.");
  }
  return value;
}

function validatedIdentifier(value, name) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/u.test(value)) {
    throw new Error(`${name} contains unsupported characters.`);
  }
  return value;
}

function isLoopbackHost(value) {
  return value === `${host}:${port}` || value === `localhost:${port}`;
}

function safeErrorMessage(error) {
  return error instanceof Error ? error.message : "unknown error";
}
