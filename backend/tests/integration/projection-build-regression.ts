import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";

import type { Pool, PoolClient } from "pg";

const inputTables = [
  "normalized_charging_locations",
  "normalized_charging_points",
  "projection_conflicts",
  "charging_park_projection",
  "charging_campus_projection",
  "charging_park_location_memberships",
  "charging_campus_park_memberships",
] as const;

/** Run inside the existing integration suite: its database/schema are shared. */
export async function assertProjectionBuildRegression(pool: Pool): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    // A timer gives a failed plan a finite test budget. It is not a latency SLO.
    await client.query("SET LOCAL statement_timeout = '60s'");
    for (const table of inputTables) {
      await client.query(`ALTER TABLE nextstop.${table} SET (autovacuum_enabled = false)`);
    }
    const oldProjectionId = randomUUID();
    const newProjectionId = randomUUID();
    await seedProjection(client, oldProjectionId, 24);
    for (const table of inputTables) {
      await client.query(`ANALYZE nextstop.${table}`);
    }

    // Keep the accepted pre-optimization functions as an independent result oracle.
    // These temporary test definitions and all fixture rows disappear at rollback.
    const previousMigration = await readFile(
      new URL("../../migrations/0008_conditional_charging_campus.sql", import.meta.url),
      "utf8",
    );
    for (const kind of ["park", "campus"] as const) {
      const functionPattern = new RegExp(
        `CREATE (?:OR REPLACE )?FUNCTION nextstop\\.rebuild_charging_${kind}_power_projection\\([\\s\\S]*?\\$function\\$;`,
        "u",
      );
      const definition = previousMigration.match(functionPattern)?.[0];
      assert.ok(definition);
      await client.query(definition.replace(
        `nextstop.rebuild_charging_${kind}_power_projection`,
        `nextstop.baseline_rebuild_charging_${kind}_power_projection`,
      ));
      await client.query(
        `SELECT nextstop.baseline_rebuild_charging_${kind}_power_projection($1)`,
        [oldProjectionId],
      );
      await client.query(`CREATE TEMPORARY TABLE expected_${kind}_power ON COMMIT DROP AS
        SELECT to_jsonb(power) - 'centroid'
          || jsonb_build_object('centroid', ST_AsText(centroid::geometry, 8)) AS row
        FROM nextstop.charging_${kind}_power_projection AS power`);
    }

    for (const kind of ["park", "campus"] as const) {
      await client.query(`SELECT nextstop.rebuild_charging_${kind}_power_projection($1)`, [oldProjectionId]);
      const differences = await client.query<{ count: number }>(`
        WITH actual AS (
          SELECT to_jsonb(power) - 'centroid'
            || jsonb_build_object('centroid', ST_AsText(centroid::geometry, 8)) AS row
          FROM nextstop.charging_${kind}_power_projection AS power
        )
        SELECT count(*)::integer AS count FROM (
          (SELECT row FROM actual EXCEPT ALL SELECT row FROM expected_${kind}_power)
          UNION ALL
          (SELECT row FROM expected_${kind}_power EXCEPT ALL SELECT row FROM actual)
        ) AS differences`);
      assert.equal(differences.rows[0]?.count, 0,
        `${kind}: EVSE identity, conflict resolution, operators, availability and geometry stay unchanged`);
    }

    // Reproduce the incident: statistics know only an older UUID, then an entire
    // unseen version arrives. No ANALYZE of shared inputs runs before the builds.
    const locationCount = 16_000;
    await seedProjection(client, newProjectionId, locationCount);
    const plan = await client.query<{
      "QUERY PLAN": readonly { Plan: { "Plan Rows": number } }[];
    }>(`EXPLAIN (FORMAT JSON) SELECT location_id
        FROM nextstop.normalized_charging_locations WHERE projection_id = $1`, [newProjectionId]);
    const estimatedLocations = plan.rows[0]?.["QUERY PLAN"][0]?.Plan["Plan Rows"];
    assert.ok(estimatedLocations !== undefined && estimatedLocations < locationCount / 10,
      "The fixture must retain a materially wrong estimate for the fresh UUID.");

    for (const kind of ["park", "campus"] as const) {
      await client.query(`SELECT nextstop.rebuild_charging_${kind}_power_projection($1)`, [newProjectionId]);
      const result = await client.query<{ rows: number; valid: boolean }>(`
        SELECT count(*)::integer AS rows,
               bool_and(charging_point_count > 0
                 AND known_available_count + known_unavailable_count + unknown_count = charging_point_count
                 AND maximum_power_kw >= minimum_power_kw
                 AND (SELECT sum((operator->>'chargingPoints')::integer)
                      FROM jsonb_array_elements(operator_charging_point_counts) AS operator)
                     = charging_point_count) AS valid
        FROM nextstop.charging_${kind}_power_projection WHERE projection_id = $1`, [newProjectionId]);
      assert.ok((result.rows[0]?.rows ?? 0) > locationCount);
      assert.equal(result.rows[0]?.valid, true);
      const oldRows = await client.query<{ count: number }>(`
        SELECT count(*)::integer AS count FROM (
          SELECT row FROM expected_${kind}_power
          EXCEPT ALL
          SELECT to_jsonb(power) - 'centroid'
            || jsonb_build_object('centroid', ST_AsText(centroid::geometry, 8))
          FROM nextstop.charging_${kind}_power_projection AS power WHERE projection_id = $1
        ) AS changed`, [oldProjectionId]);
      assert.equal(oldRows.rows[0]?.count, 0, "A new build must not touch the previous version.");
    }
    const statisticsFunction = await client.query<{
      definer: boolean; arguments: number; settings: string[]; publicExecute: boolean;
    }>(`SELECT procedure.prosecdef AS definer, procedure.pronargs AS arguments,
               procedure.proconfig AS settings,
               EXISTS (SELECT 1 FROM aclexplode(procedure.proacl)
                       WHERE grantee = 0 AND privilege_type = 'EXECUTE') AS "publicExecute"
        FROM pg_proc AS procedure
        WHERE procedure.oid = 'nextstop.refresh_charging_projection_statistics()'::regprocedure`);
    assert.deepEqual(statisticsFunction.rows, [{
      definer: true,
      arguments: 0,
      settings: ["search_path=pg_catalog, pg_temp"],
      publicExecute: false,
    }]);
    // The same connection/transaction now rebuilds the smaller UUID under the
    // real worker privilege boundary, then refreshes shared search statistics.
    await assertRestrictedWorkerBuild(client, oldProjectionId);
    const refreshedPlan = await client.query<{
      "QUERY PLAN": readonly { Plan: { "Plan Rows": number } }[];
    }>(`EXPLAIN (FORMAT JSON) SELECT location_id
        FROM nextstop.normalized_charging_locations WHERE projection_id = $1`, [newProjectionId]);
    const refreshedLocations = refreshedPlan.rows[0]?.["QUERY PLAN"][0]?.Plan["Plan Rows"];
    assert.ok(refreshedLocations !== undefined && refreshedLocations >= locationCount * 0.9,
      "The same fresh version must be visible to search plans after statistics publication.");

    const leftovers = await client.query<{ count: number }>(`
      SELECT count(*)::integer AS count FROM pg_class
      WHERE relnamespace = pg_my_temp_schema() AND relname LIKE 'power_build_%'`);
    assert.equal(leftovers.rows[0]?.count, 0);
  } finally {
    await client.query("ROLLBACK");
    client.release();
  }
}

async function assertRestrictedWorkerBuild(client: PoolClient, projectionId: string): Promise<void> {
  // The test connection is the dedicated database owner. The random role and its
  // grants exist only in this transaction and are removed by the outer rollback.
  const role = `nextstop_build_test_${randomUUID().replaceAll("-", "")}`;
  assert.match(role, /^[a-z0-9_]+$/u);
  await client.query(`CREATE ROLE ${role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOINHERIT NOREPLICATION NOBYPASSRLS`);
  const databaseGrant = await client.query<{ statement: string }>(
    "SELECT format('GRANT TEMPORARY ON DATABASE %I TO %I', current_database(), $1::text) AS statement",
    [role],
  );
  const statement = databaseGrant.rows[0]?.statement;
  assert.ok(statement);
  await client.query(statement);
  await client.query(`GRANT USAGE ON SCHEMA nextstop, public TO ${role}`);
  const tables = [
    ...inputTables,
    "projection_versions",
    "charging_park_power_projection",
    "charging_campus_power_projection",
    "charging_park_food_poi_matches",
  ].map((table) => `nextstop.${table}`).join(", ");
  await client.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE ${tables} TO ${role}`);
  await client.query("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA nextstop FROM PUBLIC");
  await client.query(`GRANT EXECUTE ON FUNCTION
    nextstop.rebuild_charging_park_power_projection(uuid),
    nextstop.rebuild_charging_campus_power_projection(uuid),
    nextstop.refresh_charging_projection_statistics() TO ${role}`);

  await client.query(`SET LOCAL ROLE ${role}`);
  const permissions = await client.query<{
    role: string; superuser: boolean; createSchemaObjects: boolean; maintain: boolean;
    readMigrations: boolean; temporary: boolean; ownSourceTable: boolean;
  }>(`SELECT current_user AS role,
      (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS superuser,
      has_schema_privilege(current_user, 'nextstop', 'CREATE') AS "createSchemaObjects",
      has_table_privilege(current_user, 'nextstop.normalized_charging_locations', 'MAINTAIN') AS maintain,
      has_table_privilege(current_user, 'nextstop.schema_migrations', 'SELECT') AS "readMigrations",
      has_database_privilege(current_user, current_database(), 'TEMPORARY') AS temporary,
      (SELECT relowner = current_user::regrole FROM pg_class
       WHERE oid = 'nextstop.normalized_charging_locations'::regclass) AS "ownSourceTable"`);
  assert.deepEqual(permissions.rows, [{
    role, superuser: false, createSchemaObjects: false, maintain: false,
    readMigrations: false, temporary: true, ownSourceTable: false,
  }]);
  await client.query("SELECT nextstop.rebuild_charging_park_power_projection($1)", [projectionId]);
  await client.query("SELECT nextstop.rebuild_charging_campus_power_projection($1)", [projectionId]);
  await client.query("SELECT nextstop.refresh_charging_projection_statistics()");
  await client.query("RESET ROLE");
}

async function seedProjection(client: PoolClient, projectionId: string, locations: number): Promise<void> {
  assert.equal(locations % 4, 0);
  await client.query(`INSERT INTO nextstop.projection_versions (
    id, source_dataset_hash, source_observed_at, built_at, status,
    coverage_status, active_sources, unavailable_sources
  ) VALUES ($1, repeat('a', 64), now(), now(), 'building', 'complete', ARRAY['fixture'], '{}')`, [projectionId]);
  await client.query(`INSERT INTO nextstop.normalized_charging_locations (
    projection_id, location_id, name, operator_name, coordinate, address, active, source_reference
  ) SELECT $1, md5('location:' || n)::uuid, 'Fixture',
      CASE WHEN n % 2 = 0 THEN 'Alpha' ELSE 'Beta' END,
      ST_SetSRID(ST_MakePoint(10 + ((n - 1) / 4) * 0.001, 52 + ((n - 1) % 4) * 0.0005), 4326)::geography,
      '{}', true, '{}'
    FROM generate_series(1, $2::integer) AS n`, [projectionId, locations]);
  await client.query(`INSERT INTO nextstop.normalized_charging_points (
    projection_id, charging_point_id, location_id, canonical_evse_identity,
    identity_decision, connectors, maximum_power_kw, availability_state,
    availability_is_live, availability_observed_at, source_reference, provider_id
  ) SELECT $1, md5('point:' || n || ':' || p)::uuid, md5('location:' || n)::uuid,
      CASE WHEN p = 2 THEN NULL ELSE 'identity:' || ((n - 1) / 4) || ':' || p END,
      'exact', '[]', (ARRAY[11,22,50,100,150,200,250,300,350,400])[((n + p) % 10) + 1],
      (ARRAY['available','occupied','out_of_service','reserved','unknown'])[((n + p) % 5) + 1],
      n % 3 <> 0, '2026-09-30T01:00:00Z', '{}', 'fixture'
    FROM generate_series(1, $2::integer) AS n CROSS JOIN generate_series(1, 4) AS p`, [projectionId, locations]);
  await client.query(`INSERT INTO nextstop.projection_conflicts (
    projection_id, conflict_id, conflict_type, canonical_evse_identity,
    location_ids, charging_point_ids, maximum_distance_meters, resolution
  ) SELECT $1, md5('conflict:' || n || ':' || p)::uuid, 'evse_coordinate_disagreement',
      'identity:' || n || ':' || p,
      ARRAY[md5('location:' || (n * 4 + 1))::uuid, md5('location:' || (n * 4 + 4))::uuid],
      ARRAY[md5('point:' || (n * 4 + 1) || ':' || p)::uuid, md5('point:' || (n * 4 + 4) || ':' || p)::uuid],
      201, CASE WHEN p = 3 THEN 'kept_distinct' ELSE 'audit_only' END
    FROM generate_series(0, ($2::integer / 4) - 1) AS n CROSS JOIN generate_series(3, 4) AS p`, [projectionId, locations]);
  await client.query(`INSERT INTO nextstop.charging_park_projection (
    projection_id, park_id, name, centroid, navigation_coordinate, member_location_ids,
    operators, operator_charging_point_counts, charging_point_count,
    known_available_count, known_unavailable_count, unknown_count,
    availability_complete, maximum_power_kw, source_summaries, data_updated_at
  ) SELECT $1, md5('park:' || n)::uuid, 'Fixture',
      ST_SetSRID(ST_MakePoint(10 + ((n * 2 - 2) / 4) * 0.001, 52 + ((n * 2 - 2) % 4) * 0.0005), 4326)::geography,
      ST_SetSRID(ST_MakePoint(10 + ((n * 2 - 2) / 4) * 0.001, 52 + ((n * 2 - 2) % 4) * 0.0005), 4326)::geography,
      ARRAY[md5('location:' || (n * 2 - 1))::uuid, md5('location:' || (n * 2))::uuid],
      ARRAY['Alpha','Beta'], '[{"name":"Alpha","chargingPoints":4},{"name":"Beta","chargingPoints":4}]',
      8, 0, 0, 8, false, 400, '[]', now()
    FROM generate_series(1, $2::integer / 2) AS n`, [projectionId, locations]);
  await client.query(`INSERT INTO nextstop.charging_campus_projection (
    projection_id, campus_id, name, centroid, navigation_coordinate, member_park_ids,
    member_location_ids, operators, operator_charging_point_counts, charging_point_count,
    known_available_count, known_unavailable_count, unknown_count,
    availability_complete, maximum_power_kw, source_summaries, data_updated_at
  ) SELECT $1, md5('campus:' || n)::uuid, 'Fixture',
      ST_SetSRID(ST_MakePoint(10 + (n - 1) * 0.001, 52), 4326)::geography,
      ST_SetSRID(ST_MakePoint(10 + (n - 1) * 0.001, 52), 4326)::geography,
      ARRAY[md5('park:' || (n * 2 - 1))::uuid, md5('park:' || (n * 2))::uuid],
      ARRAY[md5('location:' || (n * 4 - 3))::uuid, md5('location:' || (n * 4 - 2))::uuid,
            md5('location:' || (n * 4 - 1))::uuid, md5('location:' || (n * 4))::uuid],
      ARRAY['Alpha','Beta'], '[{"name":"Alpha","chargingPoints":8},{"name":"Beta","chargingPoints":8}]',
      16, 0, 0, 16, false, 400, '[]', now()
    FROM generate_series(1, $2::integer / 4) AS n`, [projectionId, locations]);
}
