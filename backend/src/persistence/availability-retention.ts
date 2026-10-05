import type { Pool } from "pg";
import { ichTankeStromDescriptor } from "../providers/ich-tanke-strom/descriptor.js";

export const availabilityRetentionLimits = {
  snapshots: 64,
  rowsPerBatch: 1_000,
  batchesPerSnapshot: 32,
  milliseconds: 120_000,
} as const;

export interface AvailabilityRetentionOptions {
  readonly maxSnapshots?: number;
  readonly batchSize?: number;
  readonly maxBatchesPerSnapshot?: number;
  readonly maximumMilliseconds?: number;
  readonly monotonicNow?: () => number;
}
export interface AvailabilityRetentionResult {
  readonly kind: "idle" | "bounded" | "busy";
  readonly deletedObservations: number;
  readonly deletedSnapshots: number;
  readonly batches: number;
}
type BatchResult =
  | { readonly kind: "idle" | "busy" }
  | { readonly kind: "deleted"; readonly id: string; readonly observations: number; readonly snapshot: boolean };

/** Retention runs independently of live publication, with bounded child deletes before parents. */
export async function pruneExpiredAvailabilitySnapshots(
  pool: Pool,
  now: () => Date = () => new Date(),
  options: AvailabilityRetentionOptions = {},
): Promise<AvailabilityRetentionResult> {
  const snapshots = bound(options.maxSnapshots ?? availabilityRetentionLimits.snapshots, availabilityRetentionLimits.snapshots);
  const batchSize = bound(options.batchSize ?? availabilityRetentionLimits.rowsPerBatch, availabilityRetentionLimits.rowsPerBatch);
  const perSnapshot = bound(options.maxBatchesPerSnapshot ?? availabilityRetentionLimits.batchesPerSnapshot, availabilityRetentionLimits.batchesPerSnapshot);
  const milliseconds = bound(options.maximumMilliseconds ?? availabilityRetentionLimits.milliseconds, availabilityRetentionLimits.milliseconds);
  const monotonicNow = options.monotonicNow ?? (() => performance.now());
  const deadline = monotonicNow() + milliseconds;
  const cutoff = new Date(now().getTime() - ichTankeStromDescriptor.liveSnapshotRetentionHours * 60 * 60 * 1_000);
  const attempts = new Map<string, number>(), excluded: string[] = [];
  let deferred = false;
  let deletedObservations = 0, deletedSnapshots = 0, batches = 0;
  const result = (kind: AvailabilityRetentionResult["kind"]): AvailabilityRetentionResult =>
    ({ kind, deletedObservations, deletedSnapshots, batches });
  while (monotonicNow() < deadline) {
    // Already selected targets may finish after the distinct-snapshot cap is
    // reached, but no sixty-fifth snapshot can enter this execution.
    const allowed = attempts.size >= snapshots ? [...attempts.keys()] : undefined;
    const batch = await pruneBatch(pool, cutoff, batchSize, excluded, allowed);
    if (batch.kind !== "deleted") return result(batch.kind === "idle" && deferred ? "bounded" : batch.kind);
    batches += 1;
    deletedObservations += batch.observations;
    deletedSnapshots += Number(batch.snapshot);
    const count = (attempts.get(batch.id) ?? 0) + 1;
    attempts.set(batch.id, count);
    if (batch.snapshot || count >= perSnapshot) excluded.push(batch.id);
    if (!batch.snapshot && count >= perSnapshot) deferred = true;
    if (attempts.size >= snapshots && excluded.length >= snapshots) return result("bounded");
  }
  return result("bounded");
}

async function pruneBatch(pool: Pool, cutoff: Date, batchSize: number, excluded: readonly string[],
  allowed: readonly string[] | undefined): Promise<BatchResult> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SET LOCAL lock_timeout = '500ms'");
    await client.query("SET LOCAL statement_timeout = '2s'");
    const target = await client.query<{ id: string }>(`SELECT id FROM nextstop.availability_snapshots
      WHERE ((status = 'retired' AND published_at < $1) OR (status = 'failed' AND fetched_at < $1))
        AND NOT (id = ANY($2::uuid[])) AND ($3::uuid[] IS NULL OR id = ANY($3::uuid[]))
      ORDER BY COALESCE(published_at, fetched_at), id
      LIMIT 1 FOR UPDATE SKIP LOCKED`, [cutoff, excluded, allowed ?? null]);
    const id = target.rows[0]?.id;
    if (id === undefined) { await client.query("COMMIT"); return { kind: "idle" }; }
    const observations = await client.query(`DELETE FROM nextstop.availability_observations
      WHERE (snapshot_id, provider_evse_key) IN (
        SELECT snapshot_id, provider_evse_key FROM nextstop.availability_observations
        WHERE snapshot_id = $1 ORDER BY provider_evse_key LIMIT $2 FOR UPDATE SKIP LOCKED
      )`, [id, batchSize]);
    // The parent FOR UPDATE excludes concurrent FK inserts; the NOT EXISTS check
    // prevents an unexpectedly large cascade, including locked child rows.
    const snapshot = await client.query(`DELETE FROM nextstop.availability_snapshots AS snapshot
      WHERE id = $1 AND NOT EXISTS (
        SELECT 1 FROM nextstop.availability_observations WHERE snapshot_id = snapshot.id
      )`, [id]);
    await client.query("COMMIT");
    const count = observations.rowCount ?? 0;
    if (count === 0 && snapshot.rowCount !== 1) return { kind: "busy" };
    return { kind: "deleted", id, observations: count, snapshot: snapshot.rowCount === 1 };
  } catch (error) {
    await client.query("ROLLBACK");
    if (error instanceof Error && "code" in error && (error.code === "55P03" || error.code === "57014")) {
      return { kind: "busy" };
    }
    throw error;
  } finally { client.release(); }
}

function bound(value: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) throw new Error("Invalid availability retention limit.");
  return value;
}
