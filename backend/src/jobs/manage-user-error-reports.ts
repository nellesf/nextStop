import { fileURLToPath } from "node:url";
import type { Pool } from "pg";
import { createDatabasePool } from "../persistence/database.js";
import { PostgresUserErrorReportRepository } from "../persistence/postgres-user-error-reports.js";

/** Local administrator tool. There is intentionally no public report-reading API. */
export async function manageUserErrorReports(pool: Pool, args: readonly string[], now: Date): Promise<unknown> {
  await new PostgresUserErrorReportRepository(pool).purge(now);
  const [command, reportId] = args;
  if (command === "list" && args.length === 1) {
    return (await pool.query(
      `SELECT report_id AS "reportId", received_at AS "receivedAt", expires_at AS "expiresAt",
              payload->'includeDiagnostics' AS "includeDiagnostics"
       FROM nextstop.user_error_reports WHERE payload IS NOT NULL AND expires_at > $1
       ORDER BY received_at DESC LIMIT 50`, [now],
    )).rows;
  }
  if ((command === "show" || command === "delete") && args.length === 2 && reportId !== undefined && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(reportId)) {
    if (command === "show") {
      return (await pool.query(
        `SELECT report_id AS "reportId", received_at AS "receivedAt", expires_at AS "expiresAt", payload
         FROM nextstop.user_error_reports WHERE report_id = $1 AND payload IS NOT NULL AND expires_at > $2`, [reportId, now],
      )).rows[0] ?? null;
    }
    await new PostgresUserErrorReportRepository(pool).deleteAsAdministrator(reportId, now);
    return { deleted: true };
  }
  if (command === "purge" && args.length === 1) return { purged: true };
  throw new Error("Usage: manage-user-error-reports list | show REPORT_UUID | delete REPORT_UUID | purge");
}

async function main(): Promise<void> {
  const connectionString = process.env.SUPPORT_DATABASE_URL;
  if (connectionString === undefined) throw new Error("SUPPORT_DATABASE_URL is required.");
  const pool = createDatabasePool(connectionString, { applicationName: "nextstop-support-operations", maxConnections: 1, queryTimeoutMilliseconds: 5_000, statementTimeoutMilliseconds: 5_000 });
  try {
    // JSON escaping keeps untrusted report text from emitting terminal control sequences.
    process.stdout.write(`${JSON.stringify(await manageUserErrorReports(pool, process.argv.slice(2), new Date()), null, 2)}\n`);
  } finally { await pool.end(); }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main().catch(() => {
    process.stderr.write("Error-report operation failed. Check the command and support database configuration.\n");
    process.exitCode = 1;
  });
}
