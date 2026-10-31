import { execFile, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { Transform, type TransformCallback } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { Storage, type File } from "@google-cloud/storage";
import { databasePoolConfiguration } from "../persistence/database.js";
import { deploymentRuntime } from "../runtime/deployment-runtime.js";

export const backupArguments = ["--format=custom", "--schema=nextstop", "--no-owner", "--no-privileges",
  "--lock-wait-timeout=500ms", "--exclude-table=nextstop.user_error_reports"] as const;

/** Re-read the exact GCS generation before a production migration trusts its receipt. */
export async function verifyBackupBytes(source: AsyncIterable<unknown>, bytes: number, sha256: string): Promise<void> {
  const hash = createHash("sha256");
  let seen = 0;
  for await (const chunk of source) {
    if (!Buffer.isBuffer(chunk)) throw new Error("Backup verification failed.");
    seen += chunk.length;
    if (seen > bytes) throw new Error("Backup verification failed.");
    hash.update(chunk);
  }
  if (seen !== bytes || hash.digest("hex") !== sha256) throw new Error("Backup verification failed.");
}

async function verifyGeneration(file: File, generation: string | number, bytes: number, sha256: string): Promise<void> {
  const exact = file.bucket.file(file.name, { generation });
  await verifyBackupBytes(exact.createReadStream({ validation: "crc32c", decompress: false }), bytes, sha256);
}

export function backupConfiguration(environment: NodeJS.ProcessEnv): { bucket: string; pg: NodeJS.ProcessEnv } {
  if (deploymentRuntime(environment) !== "cloud-run") {
    throw new Error("Backups require an isolated Cloud Run runtime.");
  }
  const bucket = environment.BACKUP_BUCKET ?? "";
  const validBucket = environment.NEXTSTOP_ENVIRONMENT === "production"
    ? bucket === "nextstop-tech-staging-database-backups"
    : /^nextstop-tech-testing-[a-z0-9-]{2,50}$/u.test(bucket);
  if (!validBucket) throw new Error("Invalid backup bucket for this environment.");
  const config = databasePoolConfiguration(environment.BACKUP_DATABASE_URL ?? "", {}, environment);
  if (config.user !== "nextstop_backup" || typeof config.password !== "string" ||
      typeof config.host !== "string" || config.database !== "nextstop") throw new Error("Restricted backup credentials required.");
  return { bucket, pg: { PGHOST: config.host, PGPORT: "5432", PGDATABASE: "nextstop", PGUSER: config.user,
    PGPASSWORD: config.password, PGCONNECT_TIMEOUT: "15", PGAPPNAME: `nextstop-${environment.NEXTSTOP_ENVIRONMENT}-backup`,
    PGOPTIONS: "-c default_transaction_read_only=on -c statement_timeout=1800000 -c lock_timeout=500" } };
}

/** Streams directly to GCS. Only a successful pg_dump publishes a completion receipt. */
export async function runDatabaseBackup(environment: NodeJS.ProcessEnv = process.env): Promise<void> {
  const config = backupConfiguration(environment);
  const production = environment.NEXTSTOP_ENVIRONMENT === "production";
  const execution = environment.CLOUD_RUN_EXECUTION;
  if (production && (!execution || !/^nextstop-backup-[a-z0-9]+$/u.test(execution))) {
    throw new Error("Production backup requires its Cloud Run execution identity.");
  }
  const bucket = new Storage({ retryOptions: { maxRetries: 2 } }).bucket(config.bucket);
  const now = new Date();
  const name = `${environment.NEXTSTOP_ENVIRONMENT}/${now.toISOString().slice(0,10)}/${randomUUID()}`;
  // Catalog-only export preserves report DDL without granting SELECT on report values.
  const { stdout: schema } = await promisify(execFile)("/usr/lib/postgresql/17/bin/psql", ["-XqAt", "-v", "ON_ERROR_STOP=1",
    "--file=" + fileURLToPath(new URL("../../operations/export-report-schema.sql", import.meta.url))],
  { env: config.pg, timeout: 30_000, maxBuffer: 128 * 1024, encoding: "utf8" });
  if (!schema.includes("CREATE TABLE nextstop.user_error_reports")) throw new Error("Report schema export failed.");
  const schemaFile = bucket.file(`${name}.report-schema.sql`);
  await schemaFile.save(schema, { resumable: false, validation: "crc32c", preconditionOpts: { ifGenerationMatch: 0 },
    metadata: { contentType: "application/sql", cacheControl: "no-store" } });
  const [schemaMetadata] = await schemaFile.getMetadata();
  if (schemaMetadata.generation === undefined) throw new Error("Report schema verification failed.");
  const dump = spawn("/usr/lib/postgresql/17/bin/pg_dump", [...backupArguments], {
    env: config.pg, stdio: ["ignore", "pipe", "pipe"], timeout: 3_500_000, killSignal: "SIGKILL",
  });
  // PostgreSQL diagnostics can contain row contents or connection credentials.
  dump.stderr.resume();
  const completed = new Promise<void>((resolve,reject) => {
    dump.once("error", () => reject(new Error("Database backup process failed.")));
    dump.once("close", (code) => code === 0 ? resolve() : reject(new Error("Database backup process failed.")));
  });
  const hash = createHash("sha256"); let bytes = 0;
  const accounting = new Transform({ transform(chunk: Buffer, _encoding: BufferEncoding, done: TransformCallback) {
    bytes += chunk.length;
    if(bytes > 50*1024*1024*1024) { done(new Error("Backup size limit exceeded.")); return; }
    hash.update(chunk); done(null,chunk);
  } });
  try {
    await Promise.all([completed, pipeline(dump.stdout, accounting, bucket.file(`${name}.dump`).createWriteStream({
      resumable: true, validation: "crc32c", preconditionOpts: { ifGenerationMatch: 0 },
      metadata: { contentType: "application/octet-stream", cacheControl: "no-store" },
    }))]);
    const [metadata] = await bucket.file(`${name}.dump`).getMetadata();
    if (bytes < 5 || Number(metadata.size) !== bytes || metadata.generation === undefined) throw new Error("Backup verification failed.");
    const archiveHash = hash.digest("hex");
    const schemaHash = createHash("sha256").update(schema).digest("hex");
    if (production) {
      await verifyGeneration(schemaFile, schemaMetadata.generation, Buffer.byteLength(schema), schemaHash);
      await verifyGeneration(bucket.file(`${name}.dump`), metadata.generation, bytes, archiveHash);
    }
    const receiptFile = bucket.file(`${name}.json`);
    await receiptFile.save(JSON.stringify({ version: 1, createdAt: now.toISOString(), ...(production && { execution }),
      archive: `${name}.dump`, generation: metadata.generation, bytes, sha256: archiveHash,
      excludedTables: ["nextstop.user_error_reports"],
      reportSchema: { object: `${name}.report-schema.sql`, generation: schemaMetadata.generation,
        sha256: schemaHash },
    }), { resumable: false, validation: "crc32c", preconditionOpts: { ifGenerationMatch: 0 },
      metadata: { contentType: "application/json", cacheControl: "no-store" } });
    if (production) {
      const [receipt] = await receiptFile.getMetadata();
      if (!receipt.generation) throw new Error("Missing production backup receipt generation.");
      console.info(JSON.stringify({ event: "production_backup_completed", bytes, reportsExcluded: true, execution,
        receiptObject: receiptFile.name, receiptGeneration: String(receipt.generation), integrityVerified: true }));
    } else {
      console.info(JSON.stringify({ event: "staging_backup_completed", bytes, reportsExcluded: true }));
    }
  } finally { if (dump.exitCode === null) dump.kill("SIGKILL"); }
}

if (process.argv[1]?.endsWith("/database-backup.js")) {
  try { await runDatabaseBackup(); }
  catch { console.error(JSON.stringify({ event: process.env.NEXTSTOP_ENVIRONMENT === "production" ? "production_backup_failed" : "staging_backup_failed" })); process.exitCode = 1; }
}
