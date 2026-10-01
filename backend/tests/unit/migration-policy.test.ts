import assert from "node:assert/strict";
import test from "node:test";

import { assertExpandOnlySQL, validateMigrationSources } from "../../src/persistence/migration-policy.js";
import { readMigrationSources } from "../../src/persistence/migrate.js";

void test("the manifest covers immutable reviewed SQL and rejects changed or unclassified files", async () => {
  const sources = await readMigrationSources();
  validateMigrationSources(sources);
  const first = sources[0];
  assert.ok(first);
  assert.throws(() => validateMigrationSources([{ ...first, sql: `${first.sql}\nSELECT 1;` }, ...sources.slice(1)]), /reviewed manifest/u);
  assert.throws(() => validateMigrationSources([...sources, { name: "9999_unreviewed.sql", sql: "DROP TABLE live;" }]), /manifest/u);
});

void test("automatic expansion rejects destructive SQL and existing contract replacements", () => {
  for (const sql of [
    "DROP TABLE nextstop.live;", "TRUNCATE nextstop.live;", "DELETE FROM nextstop.live;",
    "UPDATE nextstop.live SET enabled = false;", "ALTER TABLE nextstop.live RENAME TO old;",
    "ALTER TABLE nextstop.live ALTER COLUMN name TYPE integer;",
    "ALTER TABLE nextstop.live ADD COLUMN name text NOT NULL;",
    "ALTER TABLE nextstop.live ADD CONSTRAINT incompatible CHECK (false);",
    "CREATE OR REPLACE FUNCTION nextstop.live() RETURNS integer LANGUAGE sql AS 'SELECT 0';",
  ]) assert.throws(() => assertExpandOnlySQL(sql), /additive/u);
  assert.doesNotThrow(() => assertExpandOnlySQL(
    "CREATE TABLE nextstop.future (id integer NOT NULL); ALTER TABLE nextstop.live ADD COLUMN optional text;",
  ));
});
