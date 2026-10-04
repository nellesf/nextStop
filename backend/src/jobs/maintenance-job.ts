import { fileURLToPath } from "node:url";
import { createDatabasePool } from "../persistence/database.js";
import { PostgresUserErrorReportRepository } from "../persistence/postgres-user-error-reports.js";
import { pruneRetiredChargingSearchProjections } from "../persistence/projection-retention.js";
import { deploymentRuntime, type RuntimeEnvironment } from "../runtime/deployment-runtime.js";
import { PostgresMonthlyImportBudget, runBudgetedMonthlyImports } from "./cloud-monthly-ingestion.js";
import { PostgresMonthlySchedule } from "./monthly-ingestion.js";
import { refreshStaticProviders } from "./refresh-providers.js";
import { refreshFoodPOIs } from "./refresh-food-pois.js";
import { objectDownloadCacheBucket } from "../providers/object-download-cache.js";

export type MaintenanceJobMode = "monthly-import" | "cleanup" | "report-purge";
export interface MaintenanceJobConfiguration {
  readonly mode: MaintenanceJobMode;
  readonly maximumSeconds: number;
  readonly databaseURL: string;
}
const limits = { "monthly-import": [28_800, 28_800], cleanup: [180, 600], "report-purge": [120, 300] } as const;

export function maintenanceJobConfiguration(environment: RuntimeEnvironment = process.env): MaintenanceJobConfiguration {
  if (deploymentRuntime(environment) !== "cloud-run") throw new Error("Maintenance jobs require staging Cloud Run runtime.");
  const mode = environment.MAINTENANCE_JOB_MODE;
  if (mode !== "monthly-import" && mode !== "cleanup" && mode !== "report-purge") throw new Error("MAINTENANCE_JOB_MODE is invalid.");
  const maximumSeconds = Number(environment.MAINTENANCE_JOB_MAX_SECONDS ?? limits[mode][0]);
  if (!Number.isSafeInteger(maximumSeconds) || maximumSeconds < 1 || maximumSeconds > limits[mode][1]) {
    throw new Error("Maintenance job duration exceeds its mode limit.");
  }
  const databaseURL = mode === "report-purge" ? environment.SUPPORT_DATABASE_URL : environment.DATABASE_URL;
  if (databaseURL === undefined || databaseURL.trim() === "") throw new Error("The maintenance mode requires its dedicated database connection.");
  if (mode === "monthly-import" && environment.DOWNLOAD_CACHE_BACKEND !== "gcs") {
    throw new Error("Cloud monthly imports require the explicit GCS download cache.");
  }
  if (mode === "monthly-import") objectDownloadCacheBucket(environment);
  return { mode, maximumSeconds, databaseURL };
}

export interface MaintenanceActions {
  monthly(): Promise<string>;
  cleanup(): Promise<void>;
  purge(): Promise<void>;
}
export async function executeMaintenanceMode(mode: MaintenanceJobMode, actions: MaintenanceActions): Promise<string> {
  if (mode === "monthly-import") return actions.monthly();
  if (mode === "cleanup") await actions.cleanup();
  else await actions.purge();
  return "completed";
}

async function main(): Promise<void> {
  const configuration = maintenanceJobConfiguration();
  const pool = createDatabasePool(configuration.databaseURL, { applicationName: `nextstop-${configuration.mode}`,
    maxConnections: configuration.mode === "monthly-import" ? 4 : 1,
    statementTimeoutMilliseconds: configuration.mode === "monthly-import" ? 300_000 : 5_000 });
  const timer = setTimeout(() => {
    process.stderr.write('{"event":"maintenance_job_deadline"}\n'); process.exit(1);
  }, configuration.maximumSeconds * 1_000);
  const terminate = (): void => { process.stderr.write('{"event":"maintenance_job_interrupted"}\n'); process.exit(1); };
  process.once("SIGTERM", terminate); process.once("SIGINT", terminate);
  try {
    const outcome = await executeMaintenanceMode(configuration.mode, {
      monthly: () => runBudgetedMonthlyImports({ schedule: new PostgresMonthlySchedule(pool), foodEnabled: true,
        stopped: () => false,
        refresh: async (job) => {
          if (job === "charging-static") {
            const result = await refreshStaticProviders(pool);
            if (result.kind === "retained") throw new Error("Static source unavailable.");
          } else await refreshFoodPOIs(pool);
        },
        report: (job, outcome) => { process.stdout.write(`${JSON.stringify({ event: "monthly_import_result", job, outcome })}\n`); },
      }, new PostgresMonthlyImportBudget(pool)),
      cleanup: async () => {
        const result = await pruneRetiredChargingSearchProjections(pool, undefined, { batchSize: 1_000, maxBatches: 32 });
        if (result.kind === "busy") throw new Error("ProjectionCleanupBusy");
      },
      purge: async () => { await new PostgresUserErrorReportRepository(pool).purge(new Date()); },
    });
    process.stdout.write(`${JSON.stringify({ event: "maintenance_job_finished", mode: configuration.mode, outcome })}\n`);
    if (outcome === "budget_exhausted") process.exitCode = 1;
  } finally {
    await pool.end(); clearTimeout(timer);
    process.removeListener("SIGTERM", terminate); process.removeListener("SIGINT", terminate);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main().catch(() => { process.stderr.write('{"event":"maintenance_job_failed"}\n'); process.exitCode = 1; });
}
