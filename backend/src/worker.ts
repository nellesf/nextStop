import { ProviderIngestionCoordinator } from "./jobs/provider-ingestion-coordinator.js";
import { createDatabasePool } from "./persistence/database.js";

const databaseURL = process.env.DATABASE_URL;
if (databaseURL === undefined) {
  throw new Error("DATABASE_URL is required.");
}

const pool = createDatabasePool(databaseURL, {
  applicationName: "nextstop-worker",
  maxConnections: 4,
});
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
);

let isStopping = false;
async function stop(signal: NodeJS.Signals): Promise<void> {
  if (isStopping) {
    return;
  }
  isStopping = true;
  writeOperationalLog("info", { event: "worker-stop", signal }, "Stopping ingestion worker.");
  coordinator.stop();
  await pool.end();
}

process.once("SIGINT", () => void stop("SIGINT"));
process.once("SIGTERM", () => void stop("SIGTERM"));

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
