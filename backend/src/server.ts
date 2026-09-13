import { createApp } from "./api/app.js";
import { AccessTokenAuthenticator, AccessTokenCodec } from "./api/access-token.js";
import {
  BearerTokenAuthenticator,
  CompositeSearchAuthenticator,
  RejectingSearchAuthenticator,
  type SearchAuthenticating,
} from "./api/bearer-authentication.js";
import { PostGISCandidateSearch } from "./application/postgis-candidate-search.js";
import { SignedPaginationCodec } from "./application/signed-pagination.js";
import { createDatabasePool } from "./persistence/database.js";
import { writeRequestDiagnostic } from "./api/request-diagnostics.js";
import { UserErrorReports, userErrorReportLimits } from "./application/user-error-reports.js";
import { PostgresUserErrorReportRepository } from "./persistence/postgres-user-error-reports.js";

function parsePort(value: string | undefined): number {
  if (value === undefined) {
    return 3_000;
  }

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65_535) {
    throw new Error("PORT must be an integer from 1 through 65535.");
  }
  return parsed;
}

const databaseURL = process.env.DATABASE_URL;
const signingKey = process.env.SNAPSHOT_SIGNING_KEY;
if ((databaseURL === undefined) !== (signingKey === undefined)) {
  throw new Error("DATABASE_URL and SNAPSHOT_SIGNING_KEY must be configured together.");
}
const pool =
  databaseURL === undefined
    ? undefined
    : createDatabasePool(databaseURL, {
        applicationName: "nextstop-api",
        queryTimeoutMilliseconds: 15_000,
        statementTimeoutMilliseconds: 15_000,
      });
const candidateSearch =
  pool === undefined || signingKey === undefined
    ? undefined
    : new PostGISCandidateSearch(pool, new SignedPaginationCodec(signingKey));
if (pool !== undefined) {
  await pool.query("SELECT id FROM nextstop.projection_versions LIMIT 0");
}

const accessTokenSigningKey = process.env.SEARCH_ACCESS_TOKEN_SIGNING_KEY;
const accessTokenCodec =
  accessTokenSigningKey === undefined ? undefined : new AccessTokenCodec(accessTokenSigningKey);
const searchAuthenticators: SearchAuthenticating[] = [];
if (accessTokenCodec !== undefined) {
  searchAuthenticators.push(new AccessTokenAuthenticator(accessTokenCodec));
}
if (parseBooleanEnvironmentValue("ALLOW_LEGACY_STAGING_BEARER", false)) {
  const legacyBearerToken = process.env.SEARCH_API_BEARER_TOKEN;
  if (legacyBearerToken === undefined) {
    throw new Error(
      "SEARCH_API_BEARER_TOKEN is required when ALLOW_LEGACY_STAGING_BEARER is true.",
    );
  }
  searchAuthenticators.push(new BearerTokenAuthenticator(legacyBearerToken));
}
const searchAuthenticator =
  searchAuthenticators.length === 0
    ? new RejectingSearchAuthenticator()
    : new CompositeSearchAuthenticator(searchAuthenticators);

const supportDatabaseURL = process.env.SUPPORT_DATABASE_URL;
const supportPool = supportDatabaseURL === undefined ? undefined : createDatabasePool(supportDatabaseURL, {
  applicationName: "nextstop-support", maxConnections: 4,
  queryTimeoutMilliseconds: 5_000, statementTimeoutMilliseconds: 5_000,
});
const reportRepository = supportPool === undefined ? undefined : new PostgresUserErrorReportRepository(supportPool);
if (reportRepository !== undefined) await reportRepository.purge(new Date());
// Purge independent of submissions; startup purges overdue data before serving requests.
let purgeActive = false;
const purgeTimer = reportRepository === undefined ? undefined : setInterval(() => {
  if (purgeActive) return;
  purgeActive = true;
  void reportRepository.purge(new Date()).catch(() => {
    process.stderr.write('{"event":"user_error_report_purge_failed"}\n');
  }).finally(() => { purgeActive = false; });
}, userErrorReportLimits.purgeIntervalMilliseconds);
purgeTimer?.unref();

const app = createApp({
  ...(candidateSearch === undefined ? {} : { candidateSearch }),
  searchAuthenticator,
  diagnostics: { sink: writeRequestDiagnostic },
  ...(reportRepository === undefined ? {} : { userErrorReports: new UserErrorReports(reportRepository) }),
  ...(accessTokenCodec === undefined ? {} : { reportAuthenticator: new AccessTokenAuthenticator(accessTokenCodec) }),
});

app.addHook("onClose", async () => {
  if (purgeTimer !== undefined) clearInterval(purgeTimer);
  await supportPool?.end();
});

if (pool !== undefined) {
  app.addHook("onClose", async () => {
    await pool.end();
  });
}

await app.listen({
  host: process.env.HOST ?? "127.0.0.1",
  port: parsePort(process.env.PORT),
});

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
