import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

void test("the App Attest verifier compatibility boundary stays exactly pinned", async () => {
  const packageJson = JSON.parse(
    await readFile(new URL("../../package.json", import.meta.url), "utf8"),
  ) as { readonly dependencies?: Readonly<Record<string, string>> };

  assert.equal(packageJson.dependencies?.["node-app-attest"], "1.0.1");
});

void test("migration keeps key material hashed and bounds challenge and key retention", async () => {
  const migration = await readFile(
    new URL("../../migrations/0009_app_attest_authentication.sql", import.meta.url),
    "utf8",
  );

  assert.match(migration, /key_id_hash bytea PRIMARY KEY/u);
  assert.match(migration, /octet_length\(key_id_hash\) = 32/u);
  assert.doesNotMatch(migration, /\bkey_id\s+(?:text|varchar)/u);
  assert.match(migration, /expires_at <= created_at \+ interval '3 minutes'/u);
  assert.match(migration, /app_attest_keys_retention/u);
  assert.match(migration, /sign_count bigint/u);
});

void test("deployment isolates mutable authentication tables from the read-only API role", async () => {
  const roles = await readFile(
    new URL("../../../deploy/gcp-vm/database-roles.sql", import.meta.url),
    "utf8",
  );
  const compose = await readFile(
    new URL("../../../deploy/gcp-vm/compose.yaml", import.meta.url),
    "utf8",
  );
  const searchServer = await readFile(
    new URL("../../src/server.ts", import.meta.url),
    "utf8",
  );
  const authServer = await readFile(
    new URL("../../src/auth-server.ts", import.meta.url),
    "utf8",
  );
  const nginx = await readFile(
    new URL("../../../deploy/gcp-vm/nginx-https.conf", import.meta.url),
    "utf8",
  );
  const repository = await readFile(
    new URL("../../src/persistence/postgres-app-attest-authentication.ts", import.meta.url),
    "utf8",
  );
  const simulatorBroker = await readFile(
    new URL("../../../ios/SimulatorAuthBroker/server.mjs", import.meta.url),
    "utf8",
  );
  const simulatorMintService = serviceBlock(compose, "simulator-token-mint");

  assert.match(roles, /CREATE ROLE nextstop_auth LOGIN NOSUPERUSER/u);
  assert.match(roles, /app_attest_keys,[\s\S]*app_attest_challenges[\s\S]*TO nextstop_auth/u);
  assert.match(roles, /nextstop_auth grants do not match the authentication contract/u);
  assert.match(compose, /AUTH_DATABASE_URL: postgresql:\/\/nextstop_auth:/u);
  assert.match(compose, /auth-backend:[\s\S]*dist\/src\/auth-server\.js/u);
  assert.match(compose, /SEARCH_ACCESS_TOKEN_SIGNING_KEY:/u);
  assert.match(compose, /APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS:/u);
  assert.match(compose, /ALLOW_LEGACY_STAGING_BEARER:/u);
  assert.match(simulatorMintService, /profiles: \["development-tools"\]/u);
  assert.match(simulatorMintService, /user: node/u);
  assert.match(simulatorMintService, /network_mode: none/u);
  assert.match(simulatorMintService, /read_only: true/u);
  assert.match(simulatorMintService, /cap_drop: \["ALL"\]/u);
  assert.match(simulatorMintService, /security_opt: \["no-new-privileges:true"\]/u);
  assert.match(simulatorMintService, /SEARCH_ACCESS_TOKEN_SIGNING_KEY:/u);
  assert.match(simulatorMintService, /logging:\s+driver: none/u);
  assert.doesNotMatch(
    simulatorMintService,
    /DATABASE_URL|SNAPSHOT_SIGNING_KEY|SEARCH_API_BEARER_TOKEN/u,
  );
  assert.match(
    simulatorBroker,
    /run --rm --no-deps -T simulator-token-mint/u,
  );
  assert.doesNotMatch(
    simulatorBroker,
    /run --rm --no-deps(?: -T)? backend/u,
  );
  assert.doesNotMatch(searchServer, /AUTH_DATABASE_URL|PostgresAppAttestAuthenticationRepository/u);
  assert.match(authServer, /AUTH_DATABASE_URL/u);
  assert.match(nginx, /location \^~ \/v1\/auth\/app-attest\/[\s\S]*127\.0\.0\.1:3001/u);
  assert.match(nginx, /zone=nextstop_auth:10m rate=12r\/m/u);
  assert.match(nginx, /location \^~ \/v1\/auth\/app-attest\/[\s\S]*limit_req zone=nextstop_auth/u);
  assert.match(nginx, /error_page 429 = @auth_rate_limited/u);
  assert.match(nginx, /error_page 413 = @auth_request_too_large/u);
  assert.match(nginx, /urn:nextstop:error:authentication-rate-limited/u);
  assert.match(nginx, /location @auth_rate_limited[\s\S]*Retry-After 60/u);
  assert.match(nginx, /authentication endpoint body limit/u);
  assert.match(nginx, /location = \/v1\/charging-parks\/search[\s\S]*127\.0\.0\.1:3000/u);
  assert.match(repository, /AND \$3 > sign_count/u);
  assert.match(
    roles,
    /OR granted\.rolname IN \('nextstop_api', 'nextstop_auth', 'nextstop_worker'\)/u,
  );
  assert.match(roles, /inherited or assumable membership/u);
});

function serviceBlock(compose: string, serviceName: string): string {
  const escapedName = serviceName.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const match = compose.match(
    new RegExp(`^  ${escapedName}:\\n[\\s\\S]*?(?=^  [a-z][a-z0-9-]*:\\n|^volumes:)`, "mu"),
  );
  assert.ok(match, `Missing Compose service ${serviceName}.`);
  return match[0];
}
