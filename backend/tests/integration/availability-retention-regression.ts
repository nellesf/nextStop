import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Pool } from "pg";
import { pruneExpiredAvailabilitySnapshots } from "../../src/persistence/availability-retention.js";
import { PostgresLiveRefreshControl } from "../../src/persistence/live-refresh-control.js";
import { CloudLiveRefresh, createCloudLiveRefreshApp } from "../../src/jobs/cloud-live-refresh.js";
import { refreshSwissLiveAvailability } from "../../src/jobs/refresh-providers.js";

/** Real PostgreSQL locks, cascades and publication in the dedicated integration database. */
export async function verifyAvailabilityRetention(pool: Pool): Promise<void> {
  const now = new Date(), hour = 3_600_000, ids: string[] = [];
  async function seed(status: string, ageHours: number, rows: number): Promise<string> {
    const id = randomUUID(); ids.push(id);
    const instant = new Date(now.getTime() - ageHours * hour);
    await pool.query(`INSERT INTO nextstop.availability_snapshots
      (id, provider_id, source_hash, observed_at, fetched_at, published_at, status, record_count)
      VALUES ($1, $2, $3, $4, $4, $4, $5, $6)`, [id, `retention-fixture-${id}`, "1".repeat(64), instant, status, rows]);
    await pool.query(`INSERT INTO nextstop.availability_observations
      (snapshot_id, provider_id, provider_evse_key, native_identity, availability_state, observed_at, source_reference)
      SELECT $1, 'retention-fixture', 'evse-' || n, 'native-' || n, 'unknown', $2, '{}'::jsonb
      FROM generate_series(1, $3::int) AS n`, [id, instant, rows]);
    return id;
  }
  async function counts(id: string): Promise<{ snapshots: number; observations: number }> {
    const result = await pool.query<{ snapshots: number; observations: number }>(`SELECT
      (SELECT count(*)::int FROM nextstop.availability_snapshots WHERE id=$1) AS snapshots,
      (SELECT count(*)::int FROM nextstop.availability_observations WHERE snapshot_id=$1) AS observations`, [id]);
    assert.ok(result.rows[0]); return result.rows[0];
  }
  const held = await pool.connect();
  try {
    const protectedIds = await Promise.all([seed("active", 5, 3), seed("building", 5, 3), seed("retired", 1, 3),
      seed("retired", 2, 3), seed("failed", 1, 3), seed("failed", 2, 3)]);
    const large = await seed("retired", 5, 2_501), locked = await seed("retired", 4, 2), failed = await seed("failed", 3, 3);
    const partial = await pruneExpiredAvailabilitySnapshots(pool, () => now,
      { maxSnapshots: 1, batchSize: 1_000, maxBatchesPerSnapshot: 1 });
    assert.deepEqual(partial, { kind: "bounded", deletedObservations: 1_000, deletedSnapshots: 0, batches: 1 });
    assert.deepEqual(await counts(large), { snapshots: 1, observations: 1_501 });
    const continued = await pruneExpiredAvailabilitySnapshots(pool, () => now,
      { maxSnapshots: 1, batchSize: 1_000, maxBatchesPerSnapshot: 2 });
    assert.deepEqual(continued, { kind: "bounded", deletedObservations: 1_501, deletedSnapshots: 1, batches: 2 });
    assert.deepEqual(await counts(large), { snapshots: 0, observations: 0 });
    assert.deepEqual(await counts(locked), { snapshots: 1, observations: 2 });

    await held.query("BEGIN");
    await held.query("SELECT id FROM nextstop.availability_snapshots WHERE id=$1 FOR UPDATE", [locked]);
    // Parent SKIP LOCKED moves to the next expired snapshot without waiting.
    const skipped = await pruneExpiredAvailabilitySnapshots(pool, () => now, { maxSnapshots: 1 });
    assert.equal(skipped.deletedSnapshots, 1); assert.equal(skipped.deletedObservations, 3);
    assert.deepEqual(await counts(failed), { snapshots: 0, observations: 0 });
    await held.query("ROLLBACK");

    await held.query("BEGIN");
    await held.query("SELECT provider_evse_key FROM nextstop.availability_observations WHERE snapshot_id=$1 ORDER BY provider_evse_key LIMIT 1 FOR UPDATE", [locked]);
    const childLocked = await pruneExpiredAvailabilitySnapshots(pool, () => now);
    assert.equal(childLocked.kind, "busy"); assert.equal(childLocked.deletedObservations, 1);
    assert.deepEqual(await counts(locked), { snapshots: 1, observations: 1 });
    await held.query("ROLLBACK");
    const completed = await pruneExpiredAvailabilitySnapshots(pool, () => now);
    assert.equal(completed.deletedSnapshots, 1); assert.equal(completed.deletedObservations, 1);
    for (const id of protectedIds) assert.deepEqual(await counts(id), { snapshots: 1, observations: 3 });

    const blocked = await seed("retired", 6, 2);
    await held.query("BEGIN");
    await held.query("LOCK nextstop.availability_observations IN ACCESS EXCLUSIVE MODE");
    const timeout = await pruneExpiredAvailabilitySnapshots(pool, () => now);
    assert.equal(timeout.kind, "busy"); assert.equal(timeout.deletedSnapshots, 0);
    await held.query("ROLLBACK");
    assert.deepEqual(await counts(blocked), { snapshots: 1, observations: 2 });

    // A blocked expired snapshot used to make publication succeed but the task
    // fail thirty seconds later. On the cloud path, it cannot delay the task.
    await held.query("BEGIN");
    await held.query("SELECT id FROM nextstop.availability_snapshots WHERE id=$1 FOR UPDATE", [blocked]);
    await pool.query("DELETE FROM nextstop.live_refresh_control");
    const client = await pool.connect();
    const query = client.query.bind(client);
    const isolated = { query, connect: () => Promise.resolve({ query, release: () => {} }) } as unknown as Pool;
    await client.query("SET statement_timeout = '200ms'");
    const downloadSwissFeed = () => Promise.resolve({ kind: "live" as const,
      payload: { EVSEStatuses: [{ EVSEStatusRecord: [{ EvseID: "CH*ABC*E1", EVSEStatus: "Available" }] }] },
      sha256: "e".repeat(64), observedAt: now.toISOString(), fetchedAt: now.toISOString(), lastModified: now.toUTCString() });
    const app = createCloudLiveRefreshApp(new CloudLiveRefresh(new PostgresLiveRefreshControl(pool),
      (lease) => refreshSwissLiveAvailability(isolated, { now: () => now, downloadSwissFeed,
        liveRefreshLease: lease, inlineLiveRetention: false })), { isAuthorized: () => Promise.resolve(true) });
    try {
      const response = await app.inject({ method: "POST", url: "/refresh", payload: { providerId: "ich_tanke_strom" } });
      assert.equal(response.statusCode, 204);
      const control = await pool.query<{ success: boolean; released: boolean }>(`SELECT
        last_success_at >= last_attempt_at AS success, lease_until IS NULL AS released
        FROM nextstop.live_refresh_control WHERE provider_id='ich_tanke_strom'`);
      assert.deepEqual(control.rows[0], { success: true, released: true });
      assert.deepEqual(await counts(blocked), { snapshots: 1, observations: 2 });
      // Omitted option preserves the previous VM cleanup behavior, including its
      // error semantics. A different feed avoids the unchanged-content shortcut.
      await assert.rejects(refreshSwissLiveAvailability(isolated, { now: () => now,
        downloadSwissFeed: async () => ({ ...await downloadSwissFeed(), sha256: "f".repeat(64) }) }),
      (error: unknown) => error instanceof Error && "code" in error && error.code === "57014");
    } finally {
      await app.close();
      await client.query("RESET statement_timeout"); client.release();
      await held.query("ROLLBACK");
    }
    await pool.query("DELETE FROM nextstop.availability_snapshots WHERE provider_id='ich_tanke_strom' AND source_hash=ANY($1::text[])", [["e".repeat(64), "f".repeat(64)]]);
    await pool.query("DELETE FROM nextstop.live_refresh_control");
  } finally {
    await held.query("ROLLBACK"); held.release();
    await pool.query("DELETE FROM nextstop.availability_snapshots WHERE id=ANY($1::uuid[])", [ids]);
  }
}
