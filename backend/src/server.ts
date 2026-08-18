import { createApp } from "./api/app.js";
import { PostGISCandidateSearch } from "./application/postgis-candidate-search.js";
import { SignedPaginationCodec } from "./application/signed-pagination.js";
import { ProviderIngestionCoordinator } from "./jobs/provider-ingestion-coordinator.js";
import { createDatabasePool } from "./persistence/database.js";
import { applyMigrations } from "./persistence/migrate.js";

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
const pool = databaseURL === undefined ? undefined : createDatabasePool(databaseURL);
if (pool !== undefined) {
  await applyMigrations(pool);
}
const candidateSearch =
  pool === undefined || signingKey === undefined
    ? undefined
    : new PostGISCandidateSearch(pool, new SignedPaginationCodec(signingKey));
const app = createApp(candidateSearch === undefined ? {} : { candidateSearch });
const operationalIngestionLogger = {
  info(details: Readonly<Record<string, unknown>>, message: string): void {
    writeOperationalLog("info", details, message);
  },
  warn(details: Readonly<Record<string, unknown>>, message: string): void {
    writeOperationalLog("warn", details, message);
  },
};
const ingestionCoordinator =
  pool !== undefined && parseBoolean(process.env.INGESTION_ENABLED, true)
    ? new ProviderIngestionCoordinator(
        pool,
        operationalIngestionLogger,
        parseBoolean(process.env.OSM_INGESTION_ENABLED, true, "OSM_INGESTION_ENABLED"),
      )
    : undefined;

if (pool !== undefined) {
  app.addHook("onClose", async () => {
    ingestionCoordinator?.stop();
    await pool.end();
  });
}

await app.listen({
  host: process.env.HOST ?? "127.0.0.1",
  port: parsePort(process.env.PORT),
});
ingestionCoordinator?.start();

function writeOperationalLog(
  level: "info" | "warn",
  details: Readonly<Record<string, unknown>>,
  message: string,
): void {
  process.stdout.write(
    `${JSON.stringify({ level, time: new Date().toISOString(), message, ...details })}\n`,
  );
}

function parseBoolean(
  value: string | undefined,
  defaultValue: boolean,
  name = "INGESTION_ENABLED",
): boolean {
  if (value === undefined) {
    return defaultValue;
  }
  if (value === "true") {
    return true;
  }
  if (value === "false") {
    return false;
  }
  throw new Error(`${name} must be true or false.`);
}
