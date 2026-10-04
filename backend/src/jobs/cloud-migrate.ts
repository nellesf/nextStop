import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { databasePoolConfiguration } from "../persistence/database.js";
import { deploymentRuntime } from "../runtime/deployment-runtime.js";

type MigrationPhase = "schema" | "grants";
export interface CloudMigrationCommand {
  readonly phase: MigrationPhase;
  readonly executable: string;
  readonly arguments: readonly string[];
  readonly environment: NodeJS.ProcessEnv;
  readonly timeoutMilliseconds: number;
}

class MigrationFailure extends Error {
  constructor(readonly phase: MigrationPhase) { super("Cloud migration phase failed."); }
}

/** Child output is never inherited: PostgreSQL errors can contain SQL or secrets. */
function executeCommand(command: CloudMigrationCommand): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command.executable, [...command.arguments], {
      env: command.environment, stdio: "ignore", timeout: command.timeoutMilliseconds, killSignal: "SIGKILL",
    });
    child.once("error", () => reject(new MigrationFailure(command.phase)));
    child.once("close", (code) => code === 0 ? resolve() : reject(new MigrationFailure(command.phase)));
  });
}

/** Restricted owner runs additive migrations first, then atomic object grants/verification. */
export async function runCloudMigrations(
  environment: NodeJS.ProcessEnv = process.env,
  execute: (command: CloudMigrationCommand) => Promise<void> = executeCommand,
): Promise<void> {
  if (deploymentRuntime(environment) !== "cloud-run" || environment.DATABASE_TRANSPORT !== "cloud-sql-socket") {
    throw new Error("Cloud migrations require the staging Cloud SQL socket runtime.");
  }
  const url = environment.DATABASE_URL ?? "";
  const config = databasePoolConfiguration(url, {}, environment);
  if (config.user !== "nextstop_app" || typeof config.password !== "string" ||
      typeof config.host !== "string" || config.database !== "nextstop") {
    throw new Error("Cloud migrations require the restricted migration owner.");
  }
  const commands: readonly CloudMigrationCommand[] = [{
    phase: "schema", executable: process.execPath,
    arguments: [fileURLToPath(new URL("../persistence/migrate.js", import.meta.url)), "--expand-only"],
    environment: {
      NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging",
      DATABASE_TRANSPORT: "cloud-sql-socket", CLOUD_SQL_CONNECTION_NAME: environment.CLOUD_SQL_CONNECTION_NAME,
      DATABASE_URL: url,
    }, timeoutMilliseconds: 780_000,
  }, {
    phase: "grants", executable: "/usr/lib/postgresql/17/bin/psql",
    arguments: ["-Xq", "--no-password", "-v", "ON_ERROR_STOP=1",
      "--file=" + fileURLToPath(new URL("../../operations/database-roles.sql", import.meta.url))],
    environment: {
      PGHOST: config.host, PGPORT: "5432", PGDATABASE: "nextstop", PGUSER: "nextstop_app",
      PGPASSWORD: config.password, PGCONNECT_TIMEOUT: "15", PGAPPNAME: "nextstop-cloud-grants",
      PGOPTIONS: "-c statement_timeout=60000 -c lock_timeout=500",
    }, timeoutMilliseconds: 75_000,
  }];
  for (const command of commands) {
    try { await execute(command); }
    catch { throw new MigrationFailure(command.phase); }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 2) throw new Error("Unexpected migration argument.");
    await runCloudMigrations();
    console.info(JSON.stringify({ event: "cloud_migration_completed" }));
  } catch (error) {
    console.error(JSON.stringify({ event: "cloud_migration_failed", phase: error instanceof MigrationFailure ? error.phase : "configuration" }));
    process.exitCode = 1;
  }
}
