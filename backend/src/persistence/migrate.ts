import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { createDatabasePool } from "./database.js";
import { migrationManifest, validateMigrationSources, type MigrationSource } from "./migration-policy.js";

const migrationsDirectory = fileURLToPath(new URL("../../migrations/", import.meta.url));

export async function readMigrationSources(): Promise<readonly MigrationSource[]> {
  const files = (await readdir(migrationsDirectory))
    .filter((name) => /^\d+_[a-z0-9_]+\.sql$/u.test(name))
    .toSorted();

  return Promise.all(files.map(async (name) => ({ name, sql: await readFile(`${migrationsDirectory}/${name}`, "utf8") })));
}

export async function applyMigrations(pool: Pool, options: { readonly expandOnly?: boolean } = {}): Promise<void> {
  const sources = await readMigrationSources();
  validateMigrationSources(sources);
  const client = await pool.connect();
  let locked = false;
  try {
    await client.query("SET lock_timeout = '500ms'");
    await client.query("SET statement_timeout = '5min'");
    const lock = await client.query<{ acquired: boolean }>(
      "SELECT pg_try_advisory_lock(684237155161395698) AS acquired",
    );
    locked = lock.rows[0]?.acquired === true;
    if (!locked) throw new Error("Another schema migrator is running; retry after it finishes.");
    const registry = await client.query<{ exists: boolean }>(
      "SELECT to_regclass('nextstop.schema_migrations') IS NOT NULL AS exists",
    );
    const applied = registry.rows[0]?.exists === true
      ? new Set((await client.query<{ name: string }>("SELECT name FROM nextstop.schema_migrations")).rows.map(({ name }) => name))
      : new Set<string>();
    const pending = sources.filter(({ name }) => !applied.has(name));
    if (options.expandOnly === true && pending.some(({ name }) =>
      migrationManifest.find((entry) => entry.name === name)?.compatibility !== "expand",
    )) {
      throw new Error("Unapplied historical migrations require an isolated bootstrap before rolling deployment.");
    }
    if (options.expandOnly === true) await client.query("SET statement_timeout = '60s'");
    for (const source of pending) {
      await client.query(source.sql);
    }
  } catch (error) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    if (locked) await client.query("SELECT pg_advisory_unlock(684237155161395698)").catch(() => undefined);
    await client.query("RESET lock_timeout; RESET statement_timeout").catch(() => undefined);
    client.release();
  }
}

async function main(): Promise<void> {
  const connectionString = process.env.DATABASE_URL;
  if (connectionString === undefined) {
    throw new Error("DATABASE_URL is required.");
  }
  const pool = createDatabasePool(connectionString, {
    applicationName: "nextstop-migrator",
    maxConnections: 1,
  });
  try {
    const arguments_ = process.argv.slice(2);
    if (arguments_.some((argument) => argument !== "--expand-only")) throw new Error("Unknown migration option.");
    await applyMigrations(pool, { expandOnly: arguments_.includes("--expand-only") });
  } finally {
    await pool.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
