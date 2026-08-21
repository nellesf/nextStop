import { createAuthApp } from "./api/auth-app.js";
import { AccessTokenCodec } from "./api/access-token.js";
import { HardenedAppAttestVerifier } from "./api/app-attest-verifier.js";
import { AppAttestAuthenticationService } from "./application/app-attest-authentication.js";
import { createDatabasePool } from "./persistence/database.js";
import { PostgresAppAttestAuthenticationRepository } from "./persistence/postgres-app-attest-authentication.js";

const appAttestAppId = nonemptyEnvironmentValue("APP_ATTEST_APP_ID");
const authDatabaseURL = nonemptyEnvironmentValue("AUTH_DATABASE_URL");
const accessTokenSigningKey = nonemptyEnvironmentValue("SEARCH_ACCESS_TOKEN_SIGNING_KEY");
if (
  appAttestAppId !== undefined &&
  (authDatabaseURL === undefined || accessTokenSigningKey === undefined)
) {
  throw new Error(
    "AUTH_DATABASE_URL and SEARCH_ACCESS_TOKEN_SIGNING_KEY are required when APP_ATTEST_APP_ID is configured.",
  );
}

const authPool =
  appAttestAppId === undefined || authDatabaseURL === undefined
    ? undefined
    : createDatabasePool(authDatabaseURL, {
        applicationName: "nextstop-auth",
        maxConnections: 4,
        queryTimeoutMilliseconds: 5_000,
        statementTimeoutMilliseconds: 5_000,
      });
const accessTokenCodec =
  accessTokenSigningKey === undefined ? undefined : new AccessTokenCodec(accessTokenSigningKey);
const appAttestAuthentication =
  appAttestAppId === undefined || authPool === undefined || accessTokenCodec === undefined
    ? undefined
    : new AppAttestAuthenticationService(
        new PostgresAppAttestAuthenticationRepository(authPool),
        new HardenedAppAttestVerifier(appAttestAppId, {
          allowDevelopmentEnvironment: parseBooleanEnvironmentValue(
            "APP_ATTEST_ALLOW_DEVELOPMENT",
            false,
          ),
          supportedBundleVersions: parseBundleVersionAllowlist(
            requiredEnvironmentValue("APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS"),
          ),
        }),
        accessTokenCodec,
      );
if (authPool !== undefined) {
  await authPool.query("SELECT key_id_hash FROM nextstop.app_attest_keys LIMIT 0");
}

const app = createAuthApp(
  appAttestAuthentication === undefined ? {} : { appAttestAuthentication },
);
if (authPool !== undefined) {
  app.addHook("onClose", async () => {
    await authPool.end();
  });
}

await app.listen({
  host: process.env.HOST ?? "127.0.0.1",
  port: parsePort(process.env.PORT),
});

function parsePort(value: string | undefined): number {
  if (value === undefined) {
    return 3_001;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65_535) {
    throw new Error("PORT must be an integer from 1 through 65535.");
  }
  return parsed;
}

function nonemptyEnvironmentValue(name: string): string | undefined {
  const value = process.env[name];
  return value === undefined || value.length === 0 ? undefined : value;
}

function requiredEnvironmentValue(name: string): string {
  const value = nonemptyEnvironmentValue(name);
  if (value === undefined) {
    throw new Error(`${name} must be configured.`);
  }
  return value;
}

function parseBundleVersionAllowlist(value: string): readonly string[] {
  if (value.length > 2_079 || /\s/u.test(value)) {
    throw new Error(
      "APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS must be a comma-separated allowlist without whitespace.",
    );
  }
  return value.split(",");
}

function parseBooleanEnvironmentValue(name: string, defaultValue: boolean): boolean {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    return defaultValue;
  }
  if (value === "true") {
    return true;
  }
  if (value === "false") {
    return false;
  }
  throw new Error(`${name} must be either true or false.`);
}
