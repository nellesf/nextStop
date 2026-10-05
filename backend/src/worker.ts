import { createLiveRefreshApp, DemandLiveRefresh } from "./jobs/demand-live-refresh.js";
import { refreshSwissLiveAvailability } from "./jobs/refresh-providers.js";
import { PostgresLiveRefreshControl } from "./persistence/live-refresh-control.js";
import { ProviderIngestionCoordinator } from "./jobs/provider-ingestion-coordinator.js";
import { createDatabasePool } from "./persistence/database.js";

const databaseURL = process.env.DATABASE_URL;
if (databaseURL === undefined) {
  throw new Error("DATABASE_URL is required.");
}

const pool = createDatabasePool(databaseURL, {
  applicationName: "nextstop-worker",
  maxConnections: 4,
  statementTimeoutMilliseconds: 5 * 60 * 1_000,
});
const demandLiveAvailability = parseBoolean(process.env.DEMAND_LIVE_AVAILABILITY_ENABLED, false, "DEMAND_LIVE_AVAILABILITY_ENABLED");
const schedule = process.env.INGESTION_SCHEDULE ?? "daily";
if (schedule !== "daily" && schedule !== "monthly") throw new Error("INGESTION_SCHEDULE must be daily or monthly.");
const refreshControlPool = demandLiveAvailability ? createDatabasePool(databaseURL, {
  applicationName: "nextstop-live-refresh-control", maxConnections: 2,
  connectionTimeoutMilliseconds: 500, queryTimeoutMilliseconds: 750, statementTimeoutMilliseconds: 500,
}) : undefined;
const demandRefresh = refreshControlPool === undefined ? undefined : new DemandLiveRefresh(
  new PostgresLiveRefreshControl(refreshControlPool),
  (lease) => refreshSwissLiveAvailability(pool, { liveRefreshLease: lease }),
  () => writeOperationalLog("warn", { event: "live-provider-refresh-failed" }, "On-demand availability refresh failed; existing data retained."),
);
const refreshApp = demandRefresh === undefined ? undefined : createLiveRefreshApp(demandRefresh, process.env.LIVE_REFRESH_TOKEN ?? "");
const coordinator = new ProviderIngestionCoordinator(
  pool,
  {
    info(details, message): void {
      writeOperationalLog("info", details, message);
    },
    warn(details, message): void {
      writeOperationalLog("warn", details, message);
    },
  },
  parseBoolean(process.env.OSM_INGESTION_ENABLED, true, "OSM_INGESTION_ENABLED"),
  { monthlyStaticRefresh: schedule === "monthly", demandLiveAvailability },
);

let isStopping = false;
async function stop(signal: NodeJS.Signals): Promise<void> {
  if (isStopping) {
    return;
  }
  isStopping = true;
  writeOperationalLog("info", { event: "worker-stop", signal }, "Stopping ingestion worker.");
  coordinator.stop();
  await refreshApp?.close();
  await demandRefresh?.stop();
  await refreshControlPool?.end();
  await pool.end();
}

process.once("SIGINT", () => void stop("SIGINT"));
process.once("SIGTERM", () => void stop("SIGTERM"));

await refreshApp?.listen({ host: "0.0.0.0", port: 8091 });
coordinator.start();
writeOperationalLog("info", { event: "worker-start" }, "Ingestion worker started.");

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
  name: string,
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
