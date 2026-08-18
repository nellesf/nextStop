import type { Pool, PoolClient } from "pg";

import type {
  OpenStreetMapFoodPOIQuarantine,
  OpenStreetMapFoodPOIRecord,
} from "../providers/openstreetmap/pbf-provider.js";
import { openStreetMapFoodPOIDescriptor } from "../providers/openstreetmap/descriptor.js";

const projectionLock = 684237155161395695n;

export interface FoodPOIProjectionMetadata {
  readonly id: string;
  readonly sourceDatasetHash: string;
  readonly sourceObservedAt: string;
  readonly fetchedAt: string;
  readonly builtAt: string;
  readonly sourceURLs: readonly string[];
}

export class FoodPOIProjectionWriter {
  constructor(private readonly pool: Pool) {}

  async activeProjectionId(): Promise<string | undefined> {
    const result = await this.pool.query<{ readonly id: string }>(
      "SELECT id FROM nextstop.food_poi_projection_versions WHERE status = 'active'",
    );
    return result.rows[0]?.id;
  }

  async activeProjectionIdForHash(hash: string): Promise<string | undefined> {
    const result = await this.pool.query<{ readonly id: string }>(
      `SELECT id FROM nextstop.food_poi_projection_versions
       WHERE status = 'active' AND source_dataset_hash = $1`,
      [hash],
    );
    return result.rows[0]?.id;
  }

  async create(metadata: FoodPOIProjectionMetadata): Promise<void> {
    await this.pool.query(
      `INSERT INTO nextstop.food_poi_projection_versions (
         id, source_dataset_hash, source_observed_at, fetched_at, built_at,
         status, source_urls
       ) VALUES ($1, $2, $3, $4, $5, 'building', $6)`,
      [
        metadata.id,
        metadata.sourceDatasetHash,
        metadata.sourceObservedAt,
        metadata.fetchedAt,
        metadata.builtAt,
        metadata.sourceURLs,
      ],
    );
  }

  async writeRecords(
    projectionId: string,
    records: readonly OpenStreetMapFoodPOIRecord[],
  ): Promise<void> {
    if (records.length === 0) return;
    await this.pool.query(
      `INSERT INTO nextstop.food_poi_projection (
         projection_id, osm_type, osm_id, chain, name, coordinate,
         opening_hours, address, match_method, source_record_url,
         source_observed_at, fetched_at
       )
       SELECT $1, osm_type, osm_id, chain, name,
              ST_PointOnSurface(ST_SetSRID(ST_GeomFromGeoJSON(geometry), 4326))::geography,
              opening_hours, address, match_method, source_record_url,
              source_observed_at, fetched_at
       FROM jsonb_to_recordset($2::jsonb) AS item(
         osm_type text, osm_id bigint, chain text, name text, geometry jsonb,
         opening_hours text, address jsonb, match_method text,
         source_record_url text, source_observed_at timestamptz, fetched_at timestamptz
       )`,
      [
        projectionId,
        JSON.stringify(records.map((record) => ({
          osm_type: record.osmType,
          osm_id: record.osmId,
          chain: record.chain,
          name: record.name,
          geometry: record.geometry,
          opening_hours: record.openingHours ?? null,
          address: record.address,
          match_method: record.matchMethod,
          source_record_url: record.sourceRecordURL,
          source_observed_at: record.sourceObservedAt,
          fetched_at: record.fetchedAt,
        }))),
      ],
    );
  }

  async writeQuarantines(
    projectionId: string,
    quarantines: readonly OpenStreetMapFoodPOIQuarantine[],
  ): Promise<void> {
    if (quarantines.length === 0) return;
    await this.pool.query(
      `INSERT INTO nextstop.food_poi_quarantine (
         projection_id, sequence_number, osm_type, osm_id, issue_codes
       )
       SELECT $1, sequence_number, osm_type, osm_id, issue_codes
       FROM jsonb_to_recordset($2::jsonb) AS item(
         sequence_number integer, osm_type text, osm_id bigint, issue_codes text[]
       )`,
      [
        projectionId,
        JSON.stringify(quarantines.map((item) => ({
          sequence_number: item.sequenceNumber,
          osm_type: item.osmType ?? null,
          osm_id: item.osmId ?? null,
          issue_codes: item.issueCodes,
        }))),
      ],
    );
  }

  async publish(
    projectionId: string,
    poiCount: number,
    quarantineCount: number,
    publishedAt: string,
  ): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SELECT pg_advisory_xact_lock($1)", [projectionLock.toString()]);
      const actual = await client.query<{ readonly pois: number; readonly quarantines: number }>(
        `SELECT
           (SELECT count(*)::integer FROM nextstop.food_poi_projection WHERE projection_id = $1) AS pois,
           (SELECT count(*)::integer FROM nextstop.food_poi_quarantine WHERE projection_id = $1) AS quarantines`,
        [projectionId],
      );
      if (
        actual.rows[0]?.pois !== poiCount ||
        actual.rows[0]?.quarantines !== quarantineCount ||
        poiCount === 0
      ) {
        throw new Error("Food POI projection row counts do not match the validated import.");
      }
      const charging = await client.query<{ readonly id: string }>(
        "SELECT id FROM nextstop.projection_versions WHERE status = 'active'",
      );
      const chargingProjectionId = charging.rows[0]?.id;
      if (chargingProjectionId !== undefined) {
        await rebuildFoodMatches(client, chargingProjectionId, projectionId);
      }
      await client.query(
        "UPDATE nextstop.food_poi_projection_versions SET status = 'retired' WHERE status = 'active'",
      );
      const published = await client.query(
        `UPDATE nextstop.food_poi_projection_versions
         SET status = 'active', published_at = $2, poi_count = $3, quarantine_count = $4
         WHERE id = $1 AND status = 'building'`,
        [projectionId, publishedAt, poiCount, quarantineCount],
      );
      if (published.rowCount !== 1) {
        throw new Error("Food POI projection is not in the building state.");
      }
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async fail(projectionId: string, failureCode: string): Promise<void> {
    await this.pool.query(
      `UPDATE nextstop.food_poi_projection_versions
       SET status = 'failed', failure_code = $2
       WHERE id = $1 AND status = 'building'`,
      [projectionId, failureCode],
    );
  }
}

export async function rebuildFoodMatchesForChargingProjection(
  client: PoolClient,
  chargingProjectionId: string,
): Promise<void> {
  const food = await client.query<{ readonly id: string }>(
    "SELECT id FROM nextstop.food_poi_projection_versions WHERE status = 'active'",
  );
  const foodProjectionId = food.rows[0]?.id;
  if (foodProjectionId !== undefined) {
    await rebuildFoodMatches(client, chargingProjectionId, foodProjectionId);
  }
}

async function rebuildFoodMatches(
  client: PoolClient,
  chargingProjectionId: string,
  foodProjectionId: string,
): Promise<void> {
  await client.query(
    `DELETE FROM nextstop.charging_park_food_poi_matches
     WHERE charging_projection_id = $1 AND food_projection_id = $2`,
    [chargingProjectionId, foodProjectionId],
  );
  await client.query(
    `INSERT INTO nextstop.charging_park_food_poi_matches (
       charging_projection_id, food_projection_id, park_id, osm_type, osm_id,
       broad_distance_meters
     )
     SELECT park.projection_id, food.projection_id, park.park_id,
            food.osm_type, food.osm_id,
            round(ST_Distance(park.navigation_coordinate, food.coordinate))::integer
     FROM nextstop.charging_park_projection AS park
     JOIN nextstop.food_poi_projection AS food
       ON food.projection_id = $2
      AND ST_DWithin(
        park.navigation_coordinate,
        food.coordinate,
        $3
      )
     WHERE park.projection_id = $1`,
    [
      chargingProjectionId,
      foodProjectionId,
      openStreetMapFoodPOIDescriptor.matchPrefilterDistanceMeters,
    ],
  );
}
