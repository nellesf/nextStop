import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { PostGISCandidateSearch } from "../../src/application/postgis-candidate-search.js";
import { InvalidPaginationTokenError, SignedPaginationCodec } from "../../src/application/signed-pagination.js";
import {
  buildChargingCampusProjection,
  buildChargingParkProjection,
} from "../../src/domain/charging-park-projection.js";
import type { SearchRequest } from "../../src/domain/candidate-search.js";
import type { NormalizedLocationObservation } from "../../src/domain/normalized-charging.js";
import { FoodPOIProjectionWriter } from "../../src/persistence/food-poi-projection-writer.js";
import { pruneRetiredChargingSearchProjections } from "../../src/persistence/projection-retention.js";
import { ProjectionWriter, type QuarantineInput } from "../../src/persistence/projection-writer.js";
import { readBundesnetzagenturCSV } from "../../src/providers/bundesnetzagentur/csv-provider.js";
import { bundesnetzagenturDescriptor } from "../../src/providers/bundesnetzagentur/descriptor.js";

/** Run against the dedicated empty integration schema, before ordinary fixtures. */
export async function verifyProjectionRetention(pool: Pool): Promise<void> {
  const oldest = randomUUID();
  const recentlyRetired = randomUUID();
  const rollbackFirst = randomUUID();
  const rollbackSecond = randomUUID();
  const active = randomUUID();
  const failed = randomUUID();
  const building = randomUUID();
  const ids = [oldest, recentlyRetired, rollbackFirst, rollbackSecond, active, failed, building];
  const foodId = randomUUID();
  const now = new Date("2030-01-31T00:00:00Z");
  const observations: NormalizedLocationObservation[] = [];
  const quarantines: QuarantineInput[] = [];
  for await (const result of readBundesnetzagenturCSV({
    filePath: fileURLToPath(new URL("../fixtures/bundesnetzagentur/sample.csv", import.meta.url)),
    observedAt: "2026-07-07T00:00:00Z",
    fetchedAt: "2026-08-14T07:00:00Z",
  })) {
    if (result.kind === "observation") observations.push(result.observation);
    else quarantines.push({ providerId: bundesnetzagenturDescriptor.id, summary: result.quarantine, rawPayload: result.rawPayload });
  }
  const locations = observations.map(({ location }) => location);
  const parks = buildChargingParkProjection(locations);
  const campuses = buildChargingCampusProjection(locations, parks);
  const writer = new ProjectionWriter(pool);
  const pagination = new SignedPaginationCodec("retention-regression-key-with-at-least-32-bytes");
  const search = new PostGISCandidateSearch(pool, pagination, () => now);
  const request: SearchRequest = {
    requestId: randomUUID(),
    route: { type: "LineString", coordinates: [[9.99, 53.55], [10.01, 53.55]] },
    criteria: {
      distanceRangeMeters: { minimum: 15_000, maximum: 50_000 },
      minimumChargingPoints: 2,
      minimumPowerKW: 100,
    },
  };
  let snapshotToken: string | undefined;
  let recentlyRetiredSnapshotToken: string | undefined;
  try {
    const food = new FoodPOIProjectionWriter(pool);
    await food.create({
      id: foodId, sourceDatasetHash: "f".repeat(64),
      sourceObservedAt: now.toISOString(), fetchedAt: now.toISOString(),
      builtAt: now.toISOString(), sourceURLs: ["https://example.invalid/retention-fixture"],
    });
    await food.writeRecords(foodId, [{
      osmType: "node", osmId: 99123, chain: "mcdonalds", name: "Retention fixture",
      geometry: { type: "Point", coordinates: [10, 53.55] }, address: {},
      matchMethod: "brand", sourceRecordURL: "https://www.openstreetmap.org/node/99123",
      sourceObservedAt: now.toISOString(), fetchedAt: now.toISOString(),
    }]);
    await food.publish(foodId, 1, 0, now.toISOString());
    for (const [index, id] of ids.entries()) {
      await writer.create({
        id, sourceDatasetHash: (index + 1).toString(16).repeat(64),
        sourceObservedAt: "2026-07-07T00:00:00Z",
        builtAt: `2029-0${index + 1}-01T00:00:00Z`, coverageStatus: "complete",
        activeSources: [bundesnetzagenturDescriptor.id], unavailableSources: [],
      });
      await writer.writeObservations(id, observations);
      await writer.writeQuarantines(id, quarantines);
      await writer.writeParks(id, parks);
      await writer.writeCampuses(id, campuses);
      await writer.writeConflicts(id, [{
        id: randomUUID(), type: "evse_coordinate_disagreement", canonicalEVSEIdentity: "audit-fixture",
        locationIds: [randomUUID(), randomUUID()], chargingPointIds: [randomUUID(), randomUUID()],
        maximumDistanceMeters: 501, resolution: "audit_only",
      }]);
      if (id === failed) await writer.fail(id, "SyntheticFailure");
      else if (id !== building) {
        await writer.publish(id, {
          locationCount: locations.length,
          chargingPointCount: locations.reduce((sum, location) => sum + location.chargingPoints.length, 0),
          parkCount: parks.length, campusCount: campuses.length,
          quarantineCount: quarantines.length, conflictCount: 1,
        }, now.toISOString());
        if (id === oldest || id === recentlyRetired) {
          const response = await search.search(request);
          assert.ok(response.candidates.length > 0);
          if (id === oldest) snapshotToken = response.snapshotToken;
          else recentlyRetiredSnapshotToken = response.snapshotToken;
        }
      }
    }
    assert.ok(snapshotToken);
    assert.ok(recentlyRetiredSnapshotToken);
    const oldestContinuation = continuationRequest(request, snapshotToken, pagination);
    const recentContinuation = continuationRequest(request, recentlyRetiredSnapshotToken, pagination);
    assert.ok((await search.search(oldestContinuation)).candidates.length > 0,
      "The signed snapshot/cursor pair must succeed before cleanup starts.");
    const retirement = await pool.query<{ retired: Date | null }>(
      "SELECT retired_at AS retired FROM nextstop.projection_versions WHERE id = $1", [oldest],
    );
    assert.ok(retirement.rows[0]?.retired instanceof Date);
    await pool.query(
      `UPDATE nextstop.projection_versions SET retired_at = item.retired_at
       FROM (VALUES ($1::uuid, '2030-01-01'::timestamptz),
                    ($2::uuid, '2030-01-25'::timestamptz),
                    ($3::uuid, '2030-01-27'::timestamptz),
                    ($4::uuid, '2030-01-28'::timestamptz)) AS item(id, retired_at)
       WHERE projection_versions.id = item.id`,
      [oldest, recentlyRetired, rollbackFirst, rollbackSecond],
    );

    // A publisher owns the shared lock: cleanup must yield immediately.
    const publisher = await pool.connect();
    try {
      await publisher.query("BEGIN");
      await publisher.query("SELECT pg_advisory_xact_lock(684237155161395695)");
      const blocked = await pruneRetiredChargingSearchProjections(pool, () => now);
      assert.equal(blocked.kind, "busy");
      assert.equal(blocked.deletedRows, 0);
    } finally {
      await publisher.query("ROLLBACK");
      publisher.release();
    }

    const first = await pruneRetiredChargingSearchProjections(pool, () => now, { batchSize: 1, maxBatches: 1 });
    assert.equal(first.kind, "bounded");
    assert.equal(first.batches, 1);
    assert.ok(first.deletedRows <= 1);
    assert.equal(first.completedVersions, 0);
    await assert.rejects(search.search(oldestContinuation), InvalidPaginationTokenError);
    assert.ok((await search.search(request)).candidates.length > 0);
    const marked = await pool.query<{ pruned: Date | null; completed: Date | null }>(
      `SELECT search_pruned_at AS pruned, search_prune_completed_at AS completed
       FROM nextstop.projection_versions WHERE id = $1`, [oldest],
    );
    assert.ok(marked.rows[0]?.pruned instanceof Date);
    assert.equal(marked.rows[0]?.completed, null);

    await finishRetention(pool, now);
    await assertPruned(pool, [oldest, failed]);
    await assertRetained(pool, [recentlyRetired, rollbackFirst, rollbackSecond, active, building]);
    await assertAuditRetained(pool, ids, observations.length, quarantines.length);
    assert.equal((await pool.query<{ count: number }>(
      "SELECT count(*)::int AS count FROM nextstop.food_poi_projection WHERE projection_id = $1", [foodId],
    )).rows[0]?.count, 1);
    // Even an operator cannot accidentally reactivate a partially/fully pruned corpus.
    await assert.rejects(pool.query(
      "UPDATE nextstop.projection_versions SET status = 'active' WHERE id = $1", [oldest],
    ), /pruned_projection_cannot_be_active/u);

    // The oldest publication is recent enough since retirement to survive the
    // first pass. Later it expires, but the two newest rollback versions survive
    // even once they too are older than seven days.
    const later = new Date("2030-02-08T00:00:00Z");
    assert.ok((await search.search(recentContinuation)).candidates.length > 0);
    await assertConcurrentPruningRejected(pool, pagination, recentContinuation, later);
    await assertPruned(pool, [oldest, recentlyRetired, failed]);
    await assertRetained(pool, [rollbackFirst, rollbackSecond, active, building]);
    const repeated = await pruneRetiredChargingSearchProjections(pool, () => later);
    assert.equal(repeated.kind, "idle");
    assert.equal(repeated.deletedRows, 0);
    await assertAuditRetained(pool, ids, observations.length, quarantines.length);
  } finally {
    await pool.query("DELETE FROM nextstop.projection_versions WHERE id = ANY($1::uuid[])", [ids]);
    await pool.query("DELETE FROM nextstop.food_poi_projection_versions WHERE id = $1", [foodId]);
  }
}

function continuationRequest(
  request: SearchRequest, snapshotToken: string, pagination: SignedPaginationCodec,
): SearchRequest {
  // A valid cursor before every fixture candidate keeps this small fixture's
  // continuation nonempty without needing 51 unrelated charging parks.
  const cursor = pagination.encode({
    ...pagination.decodeSnapshot(snapshotToken),
    kind: "cursor",
    lowerBoundMeters: 0,
    parkId: "00000000-0000-4000-8000-000000000000",
  });
  return { ...request, page: { snapshotToken, cursor } };
}

async function assertConcurrentPruningRejected(
  pool: Pool, pagination: SignedPaginationCodec, request: SearchRequest, now: Date,
): Promise<void> {
  let intercepted = false;
  let candidateRowsAfterPruning: number | undefined;
  const racingPool = new Proxy(pool, {
    get(target, property, receiver): unknown {
      if (property !== "query") return Reflect.get(target, property, receiver) as unknown;
      return async (statement: string, values?: unknown[]) => {
        const candidateStatement = statement.includes("eligible_base AS MATERIALIZED");
        if (candidateStatement) {
          assert.equal(intercepted, false);
          intercepted = true;
          // Initial snapshot validation has already succeeded. Commit the
          // pruning before the candidate SELECT starts, making it return zero
          // rows. Only the post-read retention check can reject this race.
          await finishRetention(pool, now);
        }
        const result = await target.query<Record<string, unknown>>(statement, values);
        if (candidateStatement) candidateRowsAfterPruning = result.rows.length;
        return result;
      };
    },
  });
  const search = new PostGISCandidateSearch(racingPool, pagination, () => now);
  await assert.rejects(search.search(request), InvalidPaginationTokenError);
  assert.equal(intercepted, true, "Initial token validation must precede pruning.");
  assert.equal(candidateRowsAfterPruning, 0, "Deleted candidates must not produce a false empty success.");
}

async function finishRetention(pool: Pool, now: Date): Promise<void> {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const result = await pruneRetiredChargingSearchProjections(pool, () => now, { batchSize: 2, maxBatches: 32 });
    assert.notEqual(result.kind, "busy");
    if (result.kind === "idle") return;
  }
  assert.fail("Bounded retention did not finish the small fixture.");
}

async function assertPruned(pool: Pool, ids: readonly string[]): Promise<void> {
  const versions = await pool.query<{ id: string }>(
    `SELECT id FROM nextstop.projection_versions
     WHERE id = ANY($1::uuid[]) AND search_prune_completed_at IS NOT NULL`, [ids],
  );
  assert.equal(versions.rows.length, ids.length);
  for (const table of [
    "charging_park_projection", "charging_campus_projection", "charging_park_power_projection",
    "charging_campus_power_projection", "charging_park_location_memberships", "charging_campus_park_memberships",
  ]) {
    assert.equal((await pool.query<{ count: number }>(
      `SELECT count(*)::int AS count FROM nextstop.${table} WHERE projection_id = ANY($1::uuid[])`, [ids],
    )).rows[0]?.count, 0);
  }
  assert.equal((await pool.query<{ count: number }>(
    `SELECT count(*)::int AS count FROM nextstop.charging_park_food_poi_matches
     WHERE charging_projection_id = ANY($1::uuid[])`, [ids],
  )).rows[0]?.count, 0);
}

async function assertRetained(pool: Pool, ids: readonly string[]): Promise<void> {
  const versions = await pool.query<{ id: string }>(
    `SELECT id FROM nextstop.projection_versions
     WHERE id = ANY($1::uuid[]) AND search_pruned_at IS NULL`, [ids],
  );
  assert.equal(versions.rows.length, ids.length);
  assert.equal((await pool.query<{ count: number }>(
    `SELECT count(DISTINCT projection_id)::int AS count FROM nextstop.charging_park_projection
     WHERE projection_id = ANY($1::uuid[])`, [ids],
  )).rows[0]?.count, ids.length);
}

async function assertAuditRetained(
  pool: Pool, ids: readonly string[], locations: number, quarantines: number,
): Promise<void> {
  for (const [table, expected] of [
    ["normalized_charging_locations", locations], ["normalized_charging_points", 5],
    ["provider_quarantine", quarantines], ["projection_conflicts", 1],
  ] as const) {
    assert.equal((await pool.query<{ count: number }>(
      `SELECT count(*)::int AS count FROM nextstop.${table} WHERE projection_id = ANY($1::uuid[])`, [ids],
    )).rows[0]?.count, ids.length * expected);
  }
  assert.ok((await pool.query<{ count: number }>(
    "SELECT count(*)::int AS count FROM nextstop.provider_records",
  )).rows[0]?.count);
}
