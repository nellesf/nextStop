import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { createDatabasePool } from "./database.js";

const migrationsDirectory = fileURLToPath(new URL("../../migrations/", import.meta.url));

export async function applyMigrations(pool: Pool): Promise<void> {
  const files = (await readdir(migrationsDirectory))
    .filter((name) => /^\d+_[a-z0-9_]+\.sql$/u.test(name))
    .toSorted();

  for (const file of files) {
    const alreadyApplied = await pool.query<{ readonly exists: boolean }>(
      `SELECT EXISTS (
         SELECT 1
         FROM information_schema.tables
         WHERE table_schema = 'nextstop' AND table_name = 'schema_migrations'
       ) AND EXISTS (
         SELECT 1 FROM nextstop.schema_migrations WHERE name = $1
       ) AS exists`,
      [file],
    ).catch(() => ({ rows: [{ exists: false }] }));
    if (alreadyApplied.rows[0]?.exists === true) {
      continue;
    }
    await pool.query(await readFile(`${migrationsDirectory}/${file}`, "utf8"));
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
    await applyMigrations(pool);
  } finally {
    await pool.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
