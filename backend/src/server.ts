import { createApp } from "./api/app.js";
import { AvailabilityContextCodec, CandidateAvailability } from "./application/candidate-availability.js";
import { PostgresCandidateAvailability } from "./persistence/postgres-candidate-availability.js";
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
import { UserErrorReports } from "./application/user-error-reports.js";
import { PostgresUserErrorReportRepository } from "./persistence/postgres-user-error-reports.js";
import { SearchReadiness } from "./persistence/runtime-readiness.js";
import { installHTTPShutdown } from "./runtime/graceful-shutdown.js";
import { deploymentRuntime, httpShutdownGraceMilliseconds } from "./runtime/deployment-runtime.js";
import { startReportPurge } from "./runtime/report-purge.js";
import { liveRefreshTransport } from "./runtime/live-refresh-transport.js";

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

const runtime = deploymentRuntime();
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
const demandLiveEnabled = parseBooleanEnvironmentValue("DEMAND_LIVE_AVAILABILITY_ENABLED", false);
// Keep encoding existing demand snapshots after disabling the rollout flag;
// only new searches and the optional refresh endpoint depend on that flag.
const availabilityCodec = signingKey === undefined ? undefined : new AvailabilityContextCodec(signingKey);
const refreshTransport = demandLiveEnabled ? await liveRefreshTransport(runtime) : undefined;
const candidateAvailability = pool !== undefined && availabilityCodec !== undefined && refreshTransport !== undefined
  ? new CandidateAvailability(availabilityCodec, new PostgresCandidateAvailability(pool), refreshTransport.signal) : undefined;
const candidateSearch =
  pool === undefined || signingKey === undefined
    ? undefined
    : new PostGISCandidateSearch(pool, new SignedPaginationCodec(signingKey), () => new Date(), availabilityCodec, demandLiveEnabled);

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
const readinessPool = databaseURL === undefined ? undefined : createDatabasePool(databaseURL, {
  applicationName: "nextstop-api-readiness", maxConnections: 1,
  connectionTimeoutMilliseconds: 1_000, queryTimeoutMilliseconds: 1_500, statementTimeoutMilliseconds: 1_000,
});

const supportDatabaseURL = process.env.SUPPORT_DATABASE_URL;
const supportPool = supportDatabaseURL === undefined ? undefined : createDatabasePool(supportDatabaseURL, {
  applicationName: "nextstop-support", maxConnections: 4,
  queryTimeoutMilliseconds: 5_000, statementTimeoutMilliseconds: 5_000,
});
const reportRepository = supportPool === undefined ? undefined : new PostgresUserErrorReportRepository(supportPool);
const stopReportPurge = await startReportPurge(reportRepository, runtime, {
  failure: () => {
    process.stderr.write('{"event":"user_error_report_purge_failed"}\n');
  },
});

const app = createApp({
  ...(candidateAvailability === undefined ? {} : { candidateAvailability }),
  ...(process.env.RELEASE_IMAGE_DIGEST === undefined ? {} : { release: process.env.RELEASE_IMAGE_DIGEST }),
  ...(candidateSearch === undefined ? {} : { candidateSearch }),
  searchAuthenticator,
  diagnostics: { sink: writeRequestDiagnostic },
  ...(reportRepository === undefined ? {} : { userErrorReports: new UserErrorReports(reportRepository) }),
  ...(accessTokenCodec === undefined ? {} : { reportAuthenticator: new AccessTokenAuthenticator(accessTokenCodec) }),
  ...(readinessPool === undefined ? {} : {
    readiness: new SearchReadiness(readinessPool, candidateSearch !== undefined && searchAuthenticators.length > 0),
  }),
});

app.addHook("onClose", async () => {
  stopReportPurge();
  await refreshTransport?.close();
  await supportPool?.end();
  await readinessPool?.end();
});

if (pool !== undefined) {
  app.addHook("onClose", async () => {
    await pool.end();
  });
}

installHTTPShutdown(app, { graceMilliseconds: httpShutdownGraceMilliseconds(runtime) });
await app.listen({
  host: process.env.HOST ?? (runtime === "cloud-run" ? "0.0.0.0" : "127.0.0.1"),
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
