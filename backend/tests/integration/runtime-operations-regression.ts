import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { buildChargingCampusProjection, buildChargingParkProjection } from "../../src/domain/charging-park-projection.js";
import type { NormalizedLocationObservation } from "../../src/domain/normalized-charging.js";
import { FoodPOIProjectionWriter } from "../../src/persistence/food-poi-projection-writer.js";
import { applyMigrations } from "../../src/persistence/migrate.js";
import { ProjectionWriter } from "../../src/persistence/projection-writer.js";
import { AuthenticationReadiness, SearchReadiness } from "../../src/persistence/runtime-readiness.js";
import { readBundesnetzagenturCSV } from "../../src/providers/bundesnetzagentur/csv-provider.js";

export async function verifyRuntimeOperations(pool: Pool): Promise<void> {
  await verifyReadiness(pool);
  await verifyMigrationSerialization(pool);
}

async function verifyReadiness(pool: Pool): Promise<void> {
  const search = new SearchReadiness(pool, true);
  const auth = new AuthenticationReadiness(pool, true);
  assert.equal(await auth.isReady(), true);
  assert.equal(await search.isReady(), false, "An empty corpus must never pass the deployment gate.");
  const id = randomUUID();
  const pendingId = randomUUID();
  const foodId = randomUUID();
  const writer = new ProjectionWriter(pool);
  const observedAt = "2026-07-07T00:00:00Z";
  const observations: NormalizedLocationObservation[] = [];
  for await (const result of readBundesnetzagenturCSV({
    filePath: fileURLToPath(new URL("../fixtures/bundesnetzagentur/sample.csv", import.meta.url)),
    observedAt, fetchedAt: observedAt,
  })) if (result.kind === "observation") observations.push(result.observation);
  const locations = observations.map(({ location }) => location);
  const parks = buildChargingParkProjection(locations);
  const campuses = buildChargingCampusProjection(locations, parks);
  try {
    for (const projectionId of [id, pendingId]) {
      await writer.create({
        id: projectionId, sourceDatasetHash: "a".repeat(64), sourceObservedAt: observedAt,
        builtAt: observedAt, coverageStatus: "stale", activeSources: ["bundesnetzagentur"], unavailableSources: [],
      });
    }
    await writer.writeObservations(id, observations);
    await writer.writeParks(id, parks);
    await writer.writeCampuses(id, campuses);
    await writer.publish(id, {
      locationCount: locations.length,
      chargingPointCount: locations.reduce((sum, location) => sum + location.chargingPoints.length, 0),
      parkCount: parks.length, campusCount: campuses.length, quarantineCount: 0, conflictCount: 0,
    }, observedAt);
    assert.equal(await search.isReady(), false, "Food-filter search needs a published food corpus.");
    const food = new FoodPOIProjectionWriter(pool);
    await food.create({
      id: foodId, sourceDatasetHash: "f".repeat(64), sourceObservedAt: observedAt,
      fetchedAt: observedAt, builtAt: observedAt, sourceURLs: ["https://example.invalid/fixture"],
    });
    await food.writeRecords(foodId, [{
      osmType: "node", osmId: 99001, name: "Fixture", chain: "mcdonalds",
      geometry: { type: "Point", coordinates: [10, 53.55] }, address: {}, matchMethod: "brand",
      sourceRecordURL: "https://www.openstreetmap.org/node/99001", sourceObservedAt: observedAt, fetchedAt: observedAt,
    }]);
    await food.publish(foodId, 1, 0, observedAt);
    assert.equal(await search.isReady(), true, "Stale source dates and an unfinished build cannot remove a usable serving corpus.");
    await pool.query("DELETE FROM nextstop.schema_migrations WHERE name = '0015_runtime_readiness.sql'");
    try {
      assert.equal(await search.isReady(), false);
      assert.equal(await auth.isReady(), false);
    } finally {
      await pool.query("INSERT INTO nextstop.schema_migrations (name) VALUES ('0015_runtime_readiness.sql')");
    }

    const restricted = await pool.connect();
    const role = `readiness_test_${randomUUID().replaceAll("-", "")}`;
    try {
      await restricted.query("BEGIN");
      await restricted.query(`CREATE ROLE ${role} NOLOGIN`);
      await restricted.query(`GRANT USAGE ON SCHEMA nextstop TO ${role}`);
      await restricted.query(`GRANT SELECT ON nextstop.app_attest_keys, nextstop.app_attest_challenges TO ${role}`);
      await restricted.query(`GRANT EXECUTE ON FUNCTION nextstop.required_migrations_applied(text[]) TO ${role}`);
      await restricted.query(`SET LOCAL ROLE ${role}`);
      assert.equal(await new AuthenticationReadiness(restricted, true).isReady(), true);
      assert.equal((await restricted.query<{ allowed: boolean }>(
        "SELECT has_table_privilege(current_user, 'nextstop.schema_migrations', 'SELECT') AS allowed",
      )).rows[0]?.allowed, false);
    } finally {
      await restricted.query("ROLLBACK");
      restricted.release();
    }
  } finally {
    await pool.query("DELETE FROM nextstop.projection_versions WHERE id = ANY($1::uuid[])", [[id, pendingId]]);
    await pool.query("DELETE FROM nextstop.food_poi_projection_versions WHERE id = $1", [foodId]);
  }
}

async function verifyMigrationSerialization(pool: Pool): Promise<void> {
  await applyMigrations(pool, { expandOnly: true });
  const owner = await pool.connect();
  try {
    await owner.query("SELECT pg_advisory_lock(684237155161395698)");
    await assert.rejects(applyMigrations(pool, { expandOnly: true }), /Another schema migrator/u);
  } finally {
    await owner.query("SELECT pg_advisory_unlock(684237155161395698)");
    owner.release();
  }
  await pool.query("DELETE FROM nextstop.schema_migrations WHERE name = '0001_initial_postgis_projection.sql'");
  try {
    await assert.rejects(applyMigrations(pool, { expandOnly: true }), /isolated bootstrap/u);
  } finally {
    await pool.query("INSERT INTO nextstop.schema_migrations (name) VALUES ('0001_initial_postgis_projection.sql')");
  }
  await applyMigrations(pool, { expandOnly: true });
}
