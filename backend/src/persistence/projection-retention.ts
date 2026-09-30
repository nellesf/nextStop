import type { Pool, PoolClient } from "pg";

const retentionGraceMilliseconds = 7 * 24 * 60 * 60 * 1_000;
const publicationLock = "684237155161395695";
const defaultBatchSize = 250;
const maximumBatchSize = 1_000;
const defaultMaxBatches = 8;
const maximumBatches = 32;

// Children precede parents so foreign-key cascades cannot turn one bounded
// parent deletion into an unbounded cleanup. Audit/source tables are absent.
const searchTables = [
  ["charging_park_food_poi_matches", "charging_projection_id"],
  ["charging_campus_power_projection", "projection_id"],
  ["charging_campus_park_memberships", "projection_id"],
  ["charging_campus_projection", "projection_id"],
  ["charging_park_power_projection", "projection_id"],
  ["charging_park_location_memberships", "projection_id"],
  ["charging_park_projection", "projection_id"],
] as const;

export interface ProjectionRetentionOptions {
  readonly batchSize?: number;
  readonly maxBatches?: number;
}

export interface ProjectionRetentionResult {
  readonly kind: "idle" | "bounded" | "busy";
  readonly deletedRows: number;
  readonly completedVersions: number;
  readonly batches: number;
}

interface RetentionTarget {
  readonly id: string;
  readonly stage: number;
}

type BatchResult =
  | Readonly<{ kind: "idle" | "busy" }>
  | Readonly<{ kind: "deleted"; deletedRows: number; completed: boolean }>;

/** Retire generated charging search rows without removing their audit evidence. */
export async function pruneRetiredChargingSearchProjections(
  pool: Pool,
  now: () => Date = () => new Date(),
  options: ProjectionRetentionOptions = {},
): Promise<ProjectionRetentionResult> {
  const batchSize = boundedInteger(options.batchSize ?? defaultBatchSize, maximumBatchSize);
  const maxBatches = boundedInteger(options.maxBatches ?? defaultMaxBatches, maximumBatches);
  const timestamp = now();
  const cutoff = new Date(timestamp.getTime() - retentionGraceMilliseconds);
  let deletedRows = 0;
  let completedVersions = 0;
  let batches = 0;

  for (; batches < maxBatches; batches += 1) {
    const result = await pruneBatch(pool, timestamp, cutoff, batchSize);
    if (result.kind !== "deleted") {
      return { kind: result.kind, deletedRows, completedVersions, batches };
    }
    deletedRows += result.deletedRows;
    completedVersions += Number(result.completed);
  }
  return { kind: "bounded", deletedRows, completedVersions, batches };
}

async function pruneBatch(
  pool: Pool,
  timestamp: Date,
  cutoff: Date,
  batchSize: number,
): Promise<BatchResult> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SET LOCAL lock_timeout = '500ms'");
    await client.query("SET LOCAL statement_timeout = '2s'");
    const lock = await client.query<{ readonly acquired: boolean }>(
      "SELECT pg_try_advisory_xact_lock($1) AS acquired", [publicationLock],
    );
    if (lock.rows[0]?.acquired !== true) {
      await client.query("ROLLBACK");
      return { kind: "busy" };
    }
    const target = await selectTarget(client, cutoff);
    if (target === undefined) {
      await client.query("COMMIT");
      return { kind: "idle" };
    }
    const table = searchTables[target.stage];
    if (table === undefined) throw new Error("Invalid search projection retention stage.");

    // Published before any deletion becomes visible, including after an
    // interrupted multi-batch run. Search rejects tokens for this version.
    await client.query(
      `UPDATE nextstop.projection_versions
       SET search_pruned_at = COALESCE(search_pruned_at, $2)
       WHERE id = $1`,
      [target.id, timestamp],
    );
    const [tableName, projectionColumn] = table;
    const deleted = await client.query(
      `DELETE FROM nextstop.${tableName}
       WHERE ctid IN (
         SELECT ctid FROM nextstop.${tableName}
         WHERE ${projectionColumn} = $1
         LIMIT $2
       )`,
      [target.id, batchSize],
    );
    const deletedRows = deleted.rowCount ?? 0;
    const stageComplete = deletedRows < batchSize;
    const completed = stageComplete && target.stage === searchTables.length - 1;
    if (stageComplete) {
      await client.query(
        `UPDATE nextstop.projection_versions
         SET search_prune_stage = search_prune_stage + 1,
             search_prune_completed_at = CASE WHEN $3 THEN $2 ELSE NULL END
         WHERE id = $1`,
        [target.id, timestamp, completed],
      );
    }
    await client.query("COMMIT");
    return { kind: "deleted", deletedRows, completed };
  } catch (error) {
    await client.query("ROLLBACK");
    if (isContention(error)) return { kind: "busy" };
    throw error;
  } finally {
    client.release();
  }
}

async function selectTarget(client: PoolClient, cutoff: Date): Promise<RetentionTarget | undefined> {
  const result = await client.query<RetentionTarget>(
    `WITH rollback_versions AS MATERIALIZED (
       SELECT id FROM nextstop.projection_versions
       WHERE status = 'retired' AND search_pruned_at IS NULL
         AND park_count > 0 AND campus_count > 0
       ORDER BY retired_at DESC NULLS FIRST, published_at DESC, id DESC
       LIMIT 2
     )
     SELECT version.id, version.search_prune_stage AS stage
     FROM nextstop.projection_versions AS version
     WHERE version.status IN ('retired', 'failed')
       AND version.search_prune_completed_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM rollback_versions WHERE id = version.id)
       AND (
         version.search_pruned_at IS NOT NULL
         OR (version.status = 'retired' AND version.retired_at <= $1)
         OR (version.status = 'failed' AND version.built_at <= $1)
       )
     ORDER BY version.search_pruned_at NULLS LAST, version.built_at, version.id
     LIMIT 1
     FOR UPDATE OF version`,
    [cutoff],
  );
  return result.rows[0];
}

function boundedInteger(value: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw new Error(`Projection retention limit must be between 1 and ${maximum}.`);
  }
  return value;
}

function isContention(error: unknown): boolean {
  return error instanceof Error && "code" in error &&
    (error.code === "55P03" || error.code === "57014");
}
