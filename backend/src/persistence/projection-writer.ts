import type { Pool, PoolClient } from "pg";

import type {
  ChargingParkProjection,
  EVSEIdentityConflict,
  NormalizedLocationObservation,
  QuarantinedProviderRecord,
  SourceReference,
} from "../domain/normalized-charging.js";
import { bundesnetzagenturDescriptor } from "../providers/bundesnetzagentur/descriptor.js";
import { ichTankeStromDescriptor } from "../providers/ich-tanke-strom/descriptor.js";

export interface ProjectionMetadata {
  readonly id: string;
  readonly sourceDatasetHash: string;
  readonly sourceObservedAt: string;
  readonly builtAt: string;
  readonly coverageStatus: "complete" | "degraded" | "stale";
  readonly activeSources: readonly string[];
  readonly unavailableSources: readonly string[];
}

export interface QuarantineInput {
  readonly providerId: string;
  readonly summary: QuarantinedProviderRecord;
  readonly rawPayload: Readonly<Record<string, unknown>>;
}

export interface ProjectionCounts {
  readonly locationCount: number;
  readonly chargingPointCount: number;
  readonly parkCount: number;
  readonly quarantineCount: number;
  readonly conflictCount: number;
}

export class ProjectionWriter {
  constructor(private readonly pool: Pool) {}

  async activeProjectionId(): Promise<string | undefined> {
    const result = await this.pool.query<{ readonly id: string }>(
      "SELECT id FROM nextstop.projection_versions WHERE status = 'active'",
    );
    return result.rows[0]?.id;
  }

  async activeProjectionIdForHash(sourceDatasetHash: string): Promise<string | undefined> {
    const result = await this.pool.query<{ readonly id: string }>(
      `SELECT id
       FROM nextstop.projection_versions
       WHERE status = 'active' AND source_dataset_hash = $1`,
      [sourceDatasetHash],
    );
    return result.rows[0]?.id;
  }

  async create(metadata: ProjectionMetadata): Promise<void> {
    await this.pool.query(
      `INSERT INTO nextstop.projection_versions (
         id, source_dataset_hash, source_observed_at, built_at, status,
         coverage_status, active_sources, unavailable_sources
       ) VALUES ($1, $2, $3, $4, 'building', $5, $6, $7)`,
      [
        metadata.id,
        metadata.sourceDatasetHash,
        metadata.sourceObservedAt,
        metadata.builtAt,
        metadata.coverageStatus,
        metadata.activeSources,
        metadata.unavailableSources,
      ],
    );
  }

  async writeObservations(
    projectionId: string,
    observations: readonly NormalizedLocationObservation[],
  ): Promise<void> {
    if (observations.length === 0) {
      return;
    }
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await this.writeProviderRecords(client, observations);
      await this.writeLocations(client, projectionId, observations);
      await this.writeChargingPoints(client, projectionId, observations);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async writeQuarantines(
    projectionId: string,
    quarantines: readonly QuarantineInput[],
  ): Promise<void> {
    if (quarantines.length === 0) {
      return;
    }
    await this.pool.query(
      `INSERT INTO nextstop.provider_quarantine (
         projection_id, provider_id, row_number, source_record_id, issue_codes, raw_payload
       )
       SELECT $1, provider_id, row_number, source_record_id, issue_codes, raw_payload
       FROM jsonb_to_recordset($2::jsonb) AS item(
         provider_id text,
         row_number integer,
         source_record_id text,
         issue_codes text[],
         raw_payload jsonb
       )`,
      [
        projectionId,
        JSON.stringify(
          quarantines.map(({ providerId, summary, rawPayload }) => ({
            provider_id: providerId,
            row_number: summary.rowNumber,
            source_record_id: summary.sourceRecordId ?? null,
            issue_codes: summary.issueCodes,
            raw_payload: rawPayload,
          })),
        ),
      ],
    );
  }

  async writeParks(
    projectionId: string,
    parks: readonly ChargingParkProjection[],
  ): Promise<void> {
    if (parks.length === 0) {
      return;
    }
    await this.pool.query(
      `INSERT INTO nextstop.charging_park_projection (
         projection_id, park_id, name, centroid, navigation_coordinate,
         member_location_ids, operators, operator_charging_point_counts, charging_point_count,
         known_available_count, known_unavailable_count, unknown_count,
         availability_complete, last_live_observation_at, maximum_power_kw,
         source_summaries, data_updated_at
       )
       SELECT $1,
              park_id,
              name,
              ST_SetSRID(ST_MakePoint(centroid_longitude, centroid_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(navigation_longitude, navigation_latitude), 4326)::geography,
              member_location_ids,
              operators,
              operator_charging_point_counts,
              charging_point_count,
              known_available_count,
              known_unavailable_count,
              unknown_count,
              availability_complete,
              last_live_observation_at,
              maximum_power_kw,
              source_summaries,
              data_updated_at
       FROM jsonb_to_recordset($2::jsonb) AS item(
         park_id uuid,
         name text,
         centroid_latitude double precision,
         centroid_longitude double precision,
         navigation_latitude double precision,
         navigation_longitude double precision,
         member_location_ids uuid[],
         operators text[],
         operator_charging_point_counts jsonb,
         charging_point_count integer,
         known_available_count integer,
         known_unavailable_count integer,
         unknown_count integer,
         availability_complete boolean,
         last_live_observation_at timestamptz,
         maximum_power_kw integer,
         source_summaries jsonb,
         data_updated_at timestamptz
       )`,
      [projectionId, JSON.stringify(parks.map(storedPark))],
    );
  }

  async writeConflicts(
    projectionId: string,
    conflicts: readonly EVSEIdentityConflict[],
  ): Promise<void> {
    if (conflicts.length === 0) {
      return;
    }
    await this.pool.query(
      `INSERT INTO nextstop.projection_conflicts (
         projection_id, conflict_id, conflict_type, canonical_evse_identity,
         location_ids, charging_point_ids, maximum_distance_meters, resolution
       )
       SELECT $1,
              conflict_id,
              conflict_type,
              canonical_evse_identity,
              location_ids,
              charging_point_ids,
              maximum_distance_meters,
              resolution
       FROM jsonb_to_recordset($2::jsonb) AS item(
         conflict_id uuid,
         conflict_type text,
         canonical_evse_identity text,
         location_ids uuid[],
         charging_point_ids uuid[],
         maximum_distance_meters integer,
         resolution text
       )`,
      [
        projectionId,
        JSON.stringify(
          conflicts.map((conflict) => ({
            conflict_id: conflict.id,
            conflict_type: conflict.type,
            canonical_evse_identity: conflict.canonicalEVSEIdentity,
            location_ids: conflict.locationIds,
            charging_point_ids: conflict.chargingPointIds,
            maximum_distance_meters: conflict.maximumDistanceMeters,
            resolution: conflict.resolution,
          })),
        ),
      ],
    );
  }

  async publish(
    projectionId: string,
    counts: ProjectionCounts,
    publishedAt: string,
  ): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SELECT pg_advisory_xact_lock(684237155161395695)");
      const actual = await client.query<{
        readonly locations: number;
        readonly chargingPoints: number;
        readonly parks: number;
        readonly quarantines: number;
        readonly conflicts: number;
      }>(
        `SELECT
           (SELECT count(*)::integer FROM nextstop.normalized_charging_locations WHERE projection_id = $1) AS locations,
           (SELECT count(*)::integer FROM nextstop.normalized_charging_points WHERE projection_id = $1) AS "chargingPoints",
           (SELECT count(*)::integer FROM nextstop.charging_park_projection WHERE projection_id = $1) AS parks,
           (SELECT count(*)::integer FROM nextstop.provider_quarantine WHERE projection_id = $1) AS quarantines,
           (SELECT count(*)::integer FROM nextstop.projection_conflicts WHERE projection_id = $1) AS conflicts`,
        [projectionId],
      );
      const row = actual.rows[0];
      if (
        row === undefined ||
        row.locations !== counts.locationCount ||
        row.chargingPoints !== counts.chargingPointCount ||
        row.parks !== counts.parkCount ||
        row.quarantines !== counts.quarantineCount ||
        row.conflicts !== counts.conflictCount ||
        counts.parkCount === 0
      ) {
        throw new Error("Projection row counts do not match the validated import.");
      }
      await client.query(
        `UPDATE nextstop.projection_versions
         SET status = 'retired'
         WHERE status = 'active'`,
      );
      const published = await client.query(
        `UPDATE nextstop.projection_versions
         SET status = 'active',
             published_at = $2,
             location_count = $3,
             charging_point_count = $4,
             park_count = $5,
             quarantine_count = $6,
             conflict_count = $7
         WHERE id = $1 AND status = 'building'`,
        [
          projectionId,
          publishedAt,
          counts.locationCount,
          counts.chargingPointCount,
          counts.parkCount,
          counts.quarantineCount,
          counts.conflictCount,
        ],
      );
      if (published.rowCount !== 1) {
        throw new Error("Projection is not in the building state.");
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
      `UPDATE nextstop.projection_versions
       SET status = 'failed', failure_code = $2
       WHERE id = $1 AND status = 'building'`,
      [projectionId, failureCode],
    );
  }

  private async writeProviderRecords(
    client: PoolClient,
    observations: readonly NormalizedLocationObservation[],
  ): Promise<void> {
    await client.query(
      `INSERT INTO nextstop.provider_records (
         provider_id, source_record_id, content_hash, observed_at, fetched_at, raw_payload
       )
       SELECT provider_id, source_record_id, content_hash, observed_at, fetched_at, raw_payload
       FROM jsonb_to_recordset($1::jsonb) AS item(
         provider_id text,
         source_record_id text,
         content_hash text,
         observed_at timestamptz,
         fetched_at timestamptz,
         raw_payload jsonb
       )
       ON CONFLICT (provider_id, source_record_id, content_hash) DO NOTHING`,
      [
        JSON.stringify(
          observations.map(({ location, rawPayload }) => ({
            provider_id: location.sourceReference.providerId,
            source_record_id: location.sourceReference.sourceRecordId,
            content_hash: location.sourceReference.contentHash,
            observed_at: location.sourceReference.observedAt,
            fetched_at: location.sourceReference.fetchedAt,
            raw_payload: rawPayload,
          })),
        ),
      ],
    );
  }

  private async writeLocations(
    client: PoolClient,
    projectionId: string,
    observations: readonly NormalizedLocationObservation[],
  ): Promise<void> {
    await client.query(
      `INSERT INTO nextstop.normalized_charging_locations (
         projection_id, location_id, name, operator_name, coordinate,
         address, active, source_reference
       )
       SELECT $1,
              location_id,
              name,
              operator_name,
              ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography,
              address,
              active,
              source_reference
       FROM jsonb_to_recordset($2::jsonb) AS item(
         location_id uuid,
         name text,
         operator_name text,
         latitude double precision,
         longitude double precision,
         address jsonb,
         active boolean,
         source_reference jsonb
       )`,
      [
        projectionId,
        JSON.stringify(
          observations.map(({ location }) => ({
            location_id: location.id,
            name: location.name,
            operator_name: location.operatorName,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            address: location.address,
            active: location.active,
            source_reference: location.sourceReference,
          })),
        ),
      ],
    );
  }

  private async writeChargingPoints(
    client: PoolClient,
    projectionId: string,
    observations: readonly NormalizedLocationObservation[],
  ): Promise<void> {
    const rows = observations.flatMap(({ location }) =>
      location.chargingPoints.map((point) => ({
        charging_point_id: point.id,
        location_id: location.id,
        provider_id: point.sourceReference.providerId,
        native_identity: point.nativeIdentity ?? null,
        provider_evse_key: point.providerEVSEKey ?? null,
        canonical_evse_identity: point.canonicalEVSEIdentity ?? null,
        identity_decision: point.identityDecision,
        connectors: point.connectors,
        maximum_power_kw: point.maximumPowerKW,
        availability_state: point.availability.state,
        availability_is_live: point.availability.isLive,
        availability_observed_at: point.availability.observedAt ?? null,
        source_reference: point.sourceReference,
      })),
    );
    await client.query(
      `INSERT INTO nextstop.normalized_charging_points (
         projection_id, charging_point_id, location_id, native_identity,
         provider_id, provider_evse_key, canonical_evse_identity, identity_decision, connectors, maximum_power_kw,
         availability_state, availability_is_live, availability_observed_at,
         source_reference
       )
       SELECT $1,
              charging_point_id,
              location_id,
              native_identity,
              provider_id,
              provider_evse_key,
              canonical_evse_identity,
              identity_decision,
              connectors,
              maximum_power_kw,
              availability_state,
              availability_is_live,
              availability_observed_at,
              source_reference
       FROM jsonb_to_recordset($2::jsonb) AS item(
         charging_point_id uuid,
         location_id uuid,
         native_identity text,
         provider_id text,
         provider_evse_key text,
         canonical_evse_identity text,
         identity_decision text,
         connectors jsonb,
         maximum_power_kw integer,
         availability_state text,
         availability_is_live boolean,
         availability_observed_at timestamptz,
         source_reference jsonb
       )`,
      [projectionId, JSON.stringify(rows)],
    );
  }
}

function storedPark(park: ChargingParkProjection): Readonly<Record<string, unknown>> {
  return {
    park_id: park.id,
    name: park.name,
    centroid_latitude: park.centroid.latitude,
    centroid_longitude: park.centroid.longitude,
    navigation_latitude: park.navigationCoordinate.latitude,
    navigation_longitude: park.navigationCoordinate.longitude,
    member_location_ids: park.memberLocationIds,
    operators: park.operators,
    operator_charging_point_counts: park.operatorChargingPointCounts,
    charging_point_count: park.chargingPointCount,
    known_available_count: park.availability.knownAvailableCount,
    known_unavailable_count: park.availability.knownUnavailableCount,
    unknown_count: park.availability.unknownCount,
    availability_complete: park.availability.complete,
    last_live_observation_at: park.availability.lastLiveObservationAt ?? null,
    maximum_power_kw: park.maximumPowerKW,
    source_summaries: sourceSummaries(park.sourceReferences),
    data_updated_at: park.lastStaticObservationAt,
  };
}

function sourceSummaries(references: readonly SourceReference[]) {
  const observedByProvider = new Map<string, string>();
  for (const reference of references) {
    const current = observedByProvider.get(reference.providerId);
    if (current === undefined || reference.observedAt > current) {
      observedByProvider.set(reference.providerId, reference.observedAt);
    }
  }
  return [...observedByProvider.entries()]
    .toSorted(([first], [second]) => first.localeCompare(second))
    .map(([providerId, staticObservedAt]) => {
      const descriptor = sourceDescriptors.get(providerId);
      if (descriptor === undefined) {
        throw new Error(`Unknown source descriptor: ${providerId}`);
      }
      return {
        id: providerId,
        name: descriptor.name,
        qualityTier: descriptor.qualityTier,
        staticObservedAt,
      };
    });
}

const sourceDescriptors: ReadonlyMap<
  string,
  Readonly<{ name: string; qualityTier: SourceReference["qualityTier"] }>
> = new Map(
  [bundesnetzagenturDescriptor, ichTankeStromDescriptor].map((descriptor) => [
    descriptor.id,
    descriptor,
  ]),
);
