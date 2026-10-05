import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Pool } from "pg";

import {
  FoodPOIProjectionWriter,
  rebuildFoodMatchesForChargingProjection,
} from "../../src/persistence/food-poi-projection-writer.js";

const foodTables = ["food_poi_projection", "charging_park_food_poi_matches"] as const;
const fixtureRows = 1_000;

/** Real permissions and stale UUID estimates, independent of any particular index plan. */
export async function verifyFoodProjectionStatistics(pool: Pool): Promise<void> {
  const role = `food_statistics_${randomUUID().replaceAll("-", "")}`;
  const chargingIds = [randomUUID(), randomUUID()];
  const foodIds = [randomUUID(), randomUUID(), randomUUID()];
  const oldCharging = chargingIds[0]!;
  const newCharging = chargingIds[1]!;
  const oldFood = foodIds[0]!;
  const newFood = foodIds[1]!;
  const failedFood = foodIds[2]!;
  // Authenticate using the existing test connection, then enter a role with no
  // inherited privileges. The writer still uses real independent transactions.
  await pool.query(`CREATE ROLE ${role} NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE`);
  const worker = new Pool({ ...pool.options, max: 1, options: `-c role=${role}` });
  try {
    for (const table of foodTables) {
      await pool.query(`ALTER TABLE nextstop.${table} SET (autovacuum_enabled = false)`);
    }
    await pool.query(`GRANT USAGE ON SCHEMA nextstop TO ${role}`);
    await pool.query(`GRANT SELECT ON nextstop.projection_versions, nextstop.charging_park_projection TO ${role}`);
    await pool.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON
      nextstop.food_poi_projection_versions, nextstop.food_poi_projection,
      nextstop.food_poi_quarantine, nextstop.charging_park_food_poi_matches TO ${role}`);
    await pool.query(`GRANT EXECUTE ON FUNCTION nextstop.refresh_food_projection_statistics() TO ${role}`);
    const permissions = await worker.query<{ role: string; maintain: boolean; owns: boolean }>(`
      SELECT current_user AS role,
        has_table_privilege(current_user, 'nextstop.food_poi_projection', 'MAINTAIN')
          OR has_table_privilege(current_user, 'nextstop.charging_park_food_poi_matches', 'MAINTAIN') AS maintain,
        EXISTS (SELECT 1 FROM pg_class WHERE oid IN ('nextstop.food_poi_projection'::regclass,
          'nextstop.charging_park_food_poi_matches'::regclass) AND relowner=current_user::regrole) AS owns`);
    assert.deepEqual(permissions.rows, [{ role, maintain: false, owns: false }]);
    const security = await pool.query(`SELECT prosecdef AS definer, pronargs AS arguments, proconfig AS settings,
      EXISTS (SELECT 1 FROM aclexplode(proacl) WHERE grantee=0 AND privilege_type='EXECUTE') AS "publicExecute"
      FROM pg_proc WHERE oid='nextstop.refresh_food_projection_statistics()'::regprocedure`);
    assert.deepEqual(security.rows, [{ definer: true, arguments: 0,
      settings: ["search_path=pg_catalog, pg_temp"], publicExecute: false }]);

    await seedCharging(pool, oldCharging, "active");
    await seedFood(pool, oldFood);
    const writer = new FoodPOIProjectionWriter(worker);
    await writer.publish(oldFood, fixtureRows, 0, new Date().toISOString());
    await seedFood(pool, newFood);
    assert.ok(await estimateFood(pool, newFood) < fixtureRows / 10,
      "The new food UUID must be absent from the old statistics before publication.");
    await writer.publish(newFood, fixtureRows, 0, new Date().toISOString());
    assert.ok(await estimateFood(pool, newFood) >= fixtureRows * 0.9,
      "Food publication must expose the new UUID to the planner before committing.");
    assert.ok(await estimateMatches(pool, oldCharging, newFood) >= fixtureRows * 0.9,
      "Food publication must analyze its newly inserted matches, not just the food rows.");
    await assertMatchCount(pool, oldCharging, newFood, fixtureRows);
    await assertMatchCount(pool, oldCharging, oldFood, fixtureRows);

    // The charging publisher calls this same helper inside its own transaction.
    await seedCharging(pool, newCharging, "building");
    assert.ok(await estimateMatches(pool, newCharging, newFood) < fixtureRows / 10);
    const client = await worker.connect();
    try {
      await client.query("BEGIN");
      await rebuildFoodMatchesForChargingProjection(client, newCharging);
      await client.query("COMMIT");
    } finally { await client.query("ROLLBACK"); client.release(); }
    assert.ok(await estimateMatches(pool, newCharging, newFood) >= fixtureRows / 2,
      "A fresh charging UUID also requires statistics after inserting matches.");
    await assertMatchCount(pool, newCharging, newFood, fixtureRows);

    // A missing statistics privilege must fail atomically after the match insert.
    await seedFood(pool, failedFood);
    await pool.query(`REVOKE EXECUTE ON FUNCTION nextstop.refresh_food_projection_statistics() FROM ${role}`);
    await assert.rejects(writer.publish(failedFood, fixtureRows, 0, new Date().toISOString()),
      (error: unknown) => error instanceof Error && "code" in error && error.code === "42501");
    const states = await pool.query<{ id: string; status: string }>(
      "SELECT id, status FROM nextstop.food_poi_projection_versions WHERE id=ANY($1::uuid[])", [foodIds]);
    assert.equal(states.rows.find(({ id }) => id === newFood)?.status, "active");
    assert.equal(states.rows.find(({ id }) => id === failedFood)?.status, "building");
    await assertMatchCount(pool, oldCharging, failedFood, 0);
    await assertMatchCount(pool, oldCharging, newFood, fixtureRows);
  } finally {
    await worker.end();
    await pool.query("DELETE FROM nextstop.projection_versions WHERE id=ANY($1::uuid[])", [chargingIds]);
    await pool.query("DELETE FROM nextstop.food_poi_projection_versions WHERE id=ANY($1::uuid[])", [foodIds]);
    for (const table of foodTables) await pool.query(`ALTER TABLE nextstop.${table} RESET (autovacuum_enabled)`);
    await pool.query(`DROP OWNED BY ${role}`);
    await pool.query(`DROP ROLE ${role}`);
  }
}

async function estimateFood(pool: Pool, foodId: string): Promise<number> {
  const result = await pool.query<{ "QUERY PLAN": { Plan: { "Plan Rows": number } }[] }>(
    "EXPLAIN (FORMAT JSON) SELECT osm_id FROM nextstop.food_poi_projection WHERE projection_id=$1", [foodId]);
  return result.rows[0]!["QUERY PLAN"][0]!.Plan["Plan Rows"];
}

async function estimateMatches(pool: Pool, chargingId: string, foodId: string): Promise<number> {
  const result = await pool.query<{ "QUERY PLAN": { Plan: { "Plan Rows": number } }[] }>(
    `EXPLAIN (FORMAT JSON) SELECT park_id FROM nextstop.charging_park_food_poi_matches
     WHERE charging_projection_id=$1 AND food_projection_id=$2`, [chargingId, foodId]);
  return result.rows[0]!["QUERY PLAN"][0]!.Plan["Plan Rows"];
}

async function assertMatchCount(pool: Pool, chargingId: string, foodId: string, expected: number): Promise<void> {
  const result = await pool.query<{ count: number }>(`SELECT count(*)::integer AS count
    FROM nextstop.charging_park_food_poi_matches WHERE charging_projection_id=$1 AND food_projection_id=$2`, [chargingId, foodId]);
  assert.equal(result.rows[0]?.count, expected);
}

async function seedFood(pool: Pool, id: string): Promise<void> {
  await pool.query(`INSERT INTO nextstop.food_poi_projection_versions
    (id, source_dataset_hash, source_observed_at, fetched_at, built_at, status, source_urls)
    VALUES ($1, repeat('f',64), now(), now(), now(), 'building', ARRAY['https://example.invalid/statistics'])`, [id]);
  await pool.query(`INSERT INTO nextstop.food_poi_projection
    (projection_id, osm_type, osm_id, chain, name, coordinate, address, match_method,
     source_record_url, source_observed_at, fetched_at)
    SELECT $1, 'node', n, 'mcdonalds', 'Statistics fixture', ST_SetSRID(ST_MakePoint(10,52),4326)::geography,
      '{}', 'brand', 'https://example.invalid/statistics/' || n, now(), now()
    FROM generate_series(1,$2::integer) n`, [id, fixtureRows]);
}

async function seedCharging(pool: Pool, id: string, status: "active" | "building"): Promise<void> {
  await pool.query(`INSERT INTO nextstop.projection_versions
    (id, source_dataset_hash, source_observed_at, built_at, published_at, status, coverage_status, active_sources, unavailable_sources)
    VALUES ($1, repeat('a',64), now(), now(), now(), $2, 'complete', ARRAY['fixture'], '{}')`, [id, status]);
  await pool.query(`INSERT INTO nextstop.charging_park_projection
    (projection_id, park_id, name, centroid, navigation_coordinate, member_location_ids, operators,
     operator_charging_point_counts, charging_point_count, known_available_count, known_unavailable_count,
     unknown_count, availability_complete, maximum_power_kw, source_summaries, data_updated_at)
    VALUES ($1, $2, 'Statistics fixture', ST_SetSRID(ST_MakePoint(10,52),4326)::geography,
      ST_SetSRID(ST_MakePoint(10,52),4326)::geography, ARRAY[$2::uuid], ARRAY['Fixture'],
      '[{"name":"Fixture","chargingPoints":2}]', 2, 0, 0, 2, false, 150, '[]', now())`, [id, randomUUID()]);
}
