import type { Pool, PoolClient } from "pg";

import type { NormalizedAvailabilityObservation } from "../providers/ich-tanke-strom/live-provider.js";

export interface AvailabilitySnapshotMetadata {
  readonly id: string;
  readonly providerId: string;
  readonly sourceHash: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
}

export interface AvailabilitySnapshotRow {
  readonly id: string;
  readonly providerId: string;
  readonly observedAt: Date;
  readonly publishedAt: Date;
}

export class AvailabilitySnapshotWriter {
  constructor(private readonly pool: Pool) {}

  async activeSnapshotIdForHash(
    providerId: string,
    sourceHash: string,
  ): Promise<string | undefined> {
    const result = await this.pool.query<{ readonly id: string }>(
      `SELECT id
       FROM nextstop.availability_snapshots
       WHERE provider_id = $1 AND source_hash = $2 AND status = 'active'`,
      [providerId, sourceHash],
    );
    return result.rows[0]?.id;
  }

  async create(metadata: AvailabilitySnapshotMetadata): Promise<void> {
    await this.pool.query(
      `INSERT INTO nextstop.availability_snapshots (
         id, provider_id, source_hash, observed_at, fetched_at, status
       ) VALUES ($1, $2, $3, $4, $5, 'building')`,
      [
        metadata.id,
        metadata.providerId,
        metadata.sourceHash,
        metadata.observedAt,
        metadata.fetchedAt,
      ],
    );
  }

  async write(
    snapshotId: string,
    observations: readonly NormalizedAvailabilityObservation[],
  ): Promise<void> {
    if (observations.length === 0) {
      return;
    }
    await this.pool.query(
      `INSERT INTO nextstop.availability_observations (
         snapshot_id, provider_id, provider_evse_key, native_identity,
         availability_state, observed_at, source_reference
       )
       SELECT $1,
              provider_id,
              provider_evse_key,
              native_identity,
              availability_state,
              observed_at,
              source_reference
       FROM jsonb_to_recordset($2::jsonb) AS item(
         provider_id text,
         provider_evse_key text,
         native_identity text,
         availability_state text,
         observed_at timestamptz,
         source_reference jsonb
       )`,
      [
        snapshotId,
        JSON.stringify(
          observations.map((observation) => ({
            provider_id: observation.sourceReference.providerId,
            provider_evse_key: observation.providerEVSEKey,
            native_identity: observation.nativeIdentity,
            availability_state: observation.state,
            observed_at: observation.observedAt,
            source_reference: observation.sourceReference,
          })),
        ),
      ],
    );
  }

  async publish(
    snapshotId: string,
    recordCount: number,
    quarantineCount: number,
    publishedAt: string,
  ): Promise<void> {
    if (recordCount <= 0) {
      throw new Error("An availability snapshot must contain observations.");
    }
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SELECT pg_advisory_xact_lock(684237155161395696)");
      const snapshot = await client.query<{ readonly providerId: string }>(
        `SELECT provider_id AS "providerId"
         FROM nextstop.availability_snapshots
         WHERE id = $1 AND status = 'building'
         FOR UPDATE`,
        [snapshotId],
      );
      const providerId = snapshot.rows[0]?.providerId;
      if (providerId === undefined) {
        throw new Error("Availability snapshot is not in the building state.");
      }
      const actual = await client.query<{ readonly count: number }>(
        `SELECT count(*)::integer AS count
         FROM nextstop.availability_observations
         WHERE snapshot_id = $1`,
        [snapshotId],
      );
      if (actual.rows[0]?.count !== recordCount) {
        throw new Error("Availability snapshot row count does not match the import.");
      }
      await retireActiveSnapshot(client, providerId);
      const published = await client.query(
        `UPDATE nextstop.availability_snapshots
         SET status = 'active',
             published_at = $2,
             record_count = $3,
             quarantine_count = $4
         WHERE id = $1 AND status = 'building'`,
        [snapshotId, publishedAt, recordCount, quarantineCount],
      );
      if (published.rowCount !== 1) {
        throw new Error("Availability snapshot could not be published.");
      }
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async fail(snapshotId: string, failureCode: string): Promise<void> {
    await this.pool.query(
      `UPDATE nextstop.availability_snapshots
       SET status = 'failed', failure_code = $2
       WHERE id = $1 AND status = 'building'`,
      [snapshotId, failureCode],
    );
  }

  async activeFresh(
    providerIds: readonly string[],
    notBefore: string,
  ): Promise<readonly AvailabilitySnapshotRow[]> {
    if (providerIds.length === 0) {
      return [];
    }
    const result = await this.pool.query<AvailabilitySnapshotRow>(
      `SELECT id,
              provider_id AS "providerId",
              observed_at AS "observedAt",
              published_at AS "publishedAt"
       FROM nextstop.availability_snapshots
       WHERE status = 'active'
         AND provider_id = ANY($1::text[])
         AND observed_at >= $2
       ORDER BY provider_id`,
      [providerIds, notBefore],
    );
    return result.rows;
  }

  async retained(ids: readonly string[]): Promise<readonly AvailabilitySnapshotRow[]> {
    if (ids.length === 0) {
      return [];
    }
    const result = await this.pool.query<AvailabilitySnapshotRow>(
      `SELECT id,
              provider_id AS "providerId",
              observed_at AS "observedAt",
              published_at AS "publishedAt"
       FROM nextstop.availability_snapshots
       WHERE id = ANY($1::uuid[])
         AND status IN ('active', 'retired')
       ORDER BY provider_id`,
      [ids],
    );
    return result.rows;
  }

  async pruneBefore(before: string): Promise<number> {
    const result = await this.pool.query(
      `DELETE FROM nextstop.availability_snapshots
       WHERE (
           status = 'retired'
           AND published_at < $1
         ) OR (
           status = 'failed'
           AND fetched_at < $1
         )`,
      [before],
    );
    return result.rowCount ?? 0;
  }
}

async function retireActiveSnapshot(client: PoolClient, providerId: string): Promise<void> {
  await client.query(
    `UPDATE nextstop.availability_snapshots
     SET status = 'retired'
     WHERE provider_id = $1 AND status = 'active'`,
    [providerId],
  );
}
