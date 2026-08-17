import { createHash } from "node:crypto";

import type { Pool } from "pg";

import type { CandidateSearching } from "./candidate-search.js";
import { NoProjectionAvailableError } from "./candidate-search.js";
import {
  InvalidPaginationTokenError,
  type CursorPayload,
  type SignedPaginationCodec,
  type SnapshotPayload,
} from "./signed-pagination.js";
import type {
  ChargingParkCandidate,
  Coverage,
  SearchRequest,
  SearchResponse,
  SourceSummary,
} from "../domain/candidate-search.js";
import {
  AvailabilitySnapshotWriter,
  type AvailabilitySnapshotRow,
} from "../persistence/availability-snapshot-writer.js";
import { ichTankeStromDescriptor } from "../providers/ich-tanke-strom/descriptor.js";

const pageSize = 50;

interface ProjectionRow {
  readonly id: string;
  readonly publishedAt: Date;
  readonly coverageStatus: Coverage["status"];
  readonly activeSources: string[];
  readonly unavailableSources: string[];
}

interface CandidateRow {
  readonly id: string;
  readonly name: string;
  readonly centroidLatitude: number;
  readonly centroidLongitude: number;
  readonly navigationLatitude: number;
  readonly navigationLongitude: number;
  readonly distanceFromRouteMeters: number;
  readonly straightLineLowerBoundMeters: number;
  readonly chargingPoints: number;
  readonly knownAvailable: number;
  readonly knownUnavailable: number;
  readonly unknown: number;
  readonly availabilityComplete: boolean;
  readonly lastLiveObservationAt: Date | null;
  readonly maximumPowerKW: number;
  readonly operators: string[];
  readonly operatorChargingPoints: {
    readonly name: string;
    readonly chargingPoints: number;
  }[];
  readonly sources: SourceSummary[];
  readonly dataUpdatedAt: Date;
}

export class PostGISCandidateSearch implements CandidateSearching {
  private readonly availabilitySnapshots: AvailabilitySnapshotWriter;

  constructor(
    private readonly pool: Pool,
    private readonly pagination: SignedPaginationCodec,
    private readonly now: () => Date = () => new Date(),
  ) {
    this.availabilitySnapshots = new AvailabilitySnapshotWriter(pool);
  }

  async search(request: SearchRequest): Promise<SearchResponse> {
    const requestFingerprint = fingerprintRequest(request);
    const page = resolvePage(request, requestFingerprint, this.pagination);
    const projection =
      page.snapshot === undefined
        ? await this.activeProjection()
        : await this.projection(page.snapshot.projectionId);
    if (projection === undefined) {
      throw new NoProjectionAvailableError();
    }
    const availabilitySnapshots = await this.resolveAvailabilitySnapshots(
      projection,
      page.snapshot,
    );
    const availabilitySnapshotIds = availabilitySnapshots
      .map(({ id }) => id)
      .toSorted();
    const snapshot: SnapshotPayload = page.snapshot ?? {
      kind: "snapshot",
      version: 2,
      projectionId: projection.id,
      availabilitySnapshotIds,
      requestFingerprint,
    };
    const rows = await this.candidates(
      projection.id,
      availabilitySnapshotIds,
      request,
      page.cursor,
    );
    const hasNextPage = rows.length > pageSize;
    const visibleRows = rows.slice(0, pageSize);
    const last = visibleRows.at(-1);
    const nextCursor =
      hasNextPage && last !== undefined
        ? this.pagination.encode({
            kind: "cursor",
            version: 2,
            projectionId: projection.id,
            availabilitySnapshotIds,
            requestFingerprint,
            lowerBoundMeters: last.straightLineLowerBoundMeters,
            parkId: last.id,
          })
        : null;

    return {
      snapshotToken: this.pagination.encode(snapshot),
      nextCursor,
      generatedAt: this.now().toISOString(),
      candidates: visibleRows.map((row) => mapCandidate(row, availabilitySnapshots)),
      coverage: mapCoverage(projection, availabilitySnapshots),
    };
  }

  private async resolveAvailabilitySnapshots(
    projection: ProjectionRow,
    snapshot: SnapshotPayload | undefined,
  ): Promise<readonly AvailabilitySnapshotRow[]> {
    if (snapshot !== undefined) {
      const retained = await this.availabilitySnapshots.retained(
        snapshot.availabilitySnapshotIds,
      );
      if (
        retained.length !== snapshot.availabilitySnapshotIds.length ||
        !snapshot.availabilitySnapshotIds.every((id) =>
          retained.some((candidate) => candidate.id === id),
        )
      ) {
        throw new InvalidPaginationTokenError();
      }
      return retained;
    }
    if (!projection.activeSources.includes(ichTankeStromDescriptor.id)) {
      return [];
    }
    const notBefore = new Date(
      this.now().getTime() - ichTankeStromDescriptor.maximumLiveAgeSeconds * 1_000,
    ).toISOString();
    return this.availabilitySnapshots.activeFresh(
      [ichTankeStromDescriptor.id],
      notBefore,
    );
  }

  private async activeProjection(): Promise<ProjectionRow | undefined> {
    const result = await this.pool.query<ProjectionRow>(
      `SELECT id,
              published_at AS "publishedAt",
              coverage_status AS "coverageStatus",
              active_sources AS "activeSources",
              unavailable_sources AS "unavailableSources"
       FROM nextstop.projection_versions
       WHERE status = 'active'`,
    );
    return result.rows[0];
  }

  private async projection(id: string): Promise<ProjectionRow | undefined> {
    const result = await this.pool.query<ProjectionRow>(
      `SELECT id,
              published_at AS "publishedAt",
              coverage_status AS "coverageStatus",
              active_sources AS "activeSources",
              unavailable_sources AS "unavailableSources"
       FROM nextstop.projection_versions
       WHERE id = $1 AND status IN ('active', 'retired')`,
      [id],
    );
    return result.rows[0];
  }

  private async candidates(
    projectionId: string,
    availabilitySnapshotIds: readonly string[],
    request: SearchRequest,
    cursor: CursorPayload | undefined,
  ): Promise<readonly CandidateRow[]> {
    const origin = request.route.coordinates[0];
    if (origin === undefined) {
      throw new Error("Validated route did not contain an origin.");
    }
    const result = await this.pool.query<CandidateRow>(
      candidateQuery,
      [
        projectionId,
        JSON.stringify(request.route),
        origin[0],
        origin[1],
        request.criteria.minimumChargingPoints,
        request.criteria.minimumPowerKW,
        request.criteria.distanceRangeMeters.maximum,
        cursor?.lowerBoundMeters ?? null,
        cursor?.parkId ?? null,
        pageSize + 1,
        availabilitySnapshotIds,
      ],
    );
    return result.rows;
  }
}

const candidateQuery = `
WITH parameters AS (
  SELECT ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)::geography AS route,
         ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography AS origin
), base_parks AS (
  SELECT park.*
  FROM nextstop.charging_park_projection AS park
  CROSS JOIN parameters
  WHERE park.projection_id = $1
    AND ST_DWithin(park.navigation_coordinate, parameters.route, 5200)
    AND park.maximum_power_kw >= $6
), eligible_point_memberships AS (
  SELECT base.park_id,
         location.location_id,
         location.operator_name,
         location.coordinate AS location_coordinate,
         point.charging_point_id,
         point.provider_id,
         point.provider_evse_key,
         point.maximum_power_kw,
         point.availability_state,
         point.availability_is_live,
         point.availability_observed_at,
         COALESCE(
           point.canonical_evse_identity,
           COALESCE(point.provider_id, 'legacy') || ':' || point.charging_point_id::text
         ) AS evse_key
  FROM base_parks AS base
  JOIN nextstop.normalized_charging_locations AS location
    ON location.projection_id = base.projection_id
   AND location.location_id = ANY(base.member_location_ids)
  JOIN nextstop.normalized_charging_points AS point
    ON point.projection_id = location.projection_id
   AND point.location_id = location.location_id
  WHERE point.maximum_power_kw >= $6
), eligible_evses AS (
  SELECT park_id,
         evse_key,
         (array_agg(operator_name ORDER BY charging_point_id, operator_name))[1]
           AS operator_name,
         max(maximum_power_kw)::integer AS maximum_power_kw,
         CASE
           WHEN bool_and(availability_is_live)
             AND count(DISTINCT availability_state) = 1
             THEN min(availability_state)
           ELSE 'unknown'
         END AS static_availability_state,
         max(availability_observed_at) FILTER (
           WHERE availability_is_live AND availability_state <> 'unknown'
         ) AS static_observed_at
  FROM eligible_point_memberships
  GROUP BY park_id, evse_key
), eligible_aggregates AS (
  SELECT park_id,
         count(*)::integer AS charging_point_count,
         max(maximum_power_kw)::integer AS maximum_power_kw,
         count(*) FILTER (
           WHERE static_availability_state = 'available'
         )::integer AS known_available_count,
         count(*) FILTER (
           WHERE static_availability_state IN (
             'occupied', 'out_of_service', 'reserved'
           )
         )::integer AS known_unavailable_count,
         count(*) FILTER (
           WHERE static_availability_state = 'unknown'
         )::integer AS unknown_count,
         max(static_observed_at) AS last_live_observation_at
  FROM eligible_evses
  GROUP BY park_id
), operator_groups AS (
  SELECT park_id,
         operator_name,
         count(*)::integer AS charging_point_count
  FROM eligible_evses
  GROUP BY park_id, operator_name
), operator_aggregates AS (
  SELECT park_id,
         array_agg(operator_name ORDER BY operator_name) AS operators,
         jsonb_agg(
           jsonb_build_object(
             'name', operator_name,
             'chargingPoints', charging_point_count
           )
           ORDER BY operator_name
         ) AS operator_charging_points
  FROM operator_groups
  GROUP BY park_id
), eligible_locations AS (
  SELECT DISTINCT ON (park_id, location_id)
         park_id,
         location_id,
         location_coordinate
  FROM eligible_point_memberships
  ORDER BY park_id, location_id
), eligible_geometry AS (
  SELECT locations.park_id,
         ST_Centroid(ST_Collect(locations.location_coordinate::geometry))::geography
           AS centroid,
         (array_agg(
           locations.location_coordinate
           ORDER BY ST_Distance(
             locations.location_coordinate,
             base.navigation_coordinate
           ), locations.location_id
         ))[1] AS navigation_coordinate
  FROM eligible_locations AS locations
  JOIN base_parks AS base USING (park_id)
  GROUP BY locations.park_id
), eligible_base AS (
  SELECT base.*,
         round(ST_Distance(
           geometry.navigation_coordinate,
           parameters.route
         ))::integer AS distance_from_route_meters,
         ceil(ST_Distance(
           geometry.navigation_coordinate,
           parameters.origin
         ))::integer AS straight_line_lower_bound_meters,
         eligible.charging_point_count AS eligible_charging_point_count,
         eligible.maximum_power_kw AS eligible_maximum_power_kw,
         eligible.known_available_count AS eligible_known_available_count,
         eligible.known_unavailable_count AS eligible_known_unavailable_count,
         eligible.unknown_count AS eligible_unknown_count,
         eligible.last_live_observation_at AS eligible_last_live_observation_at,
         operator_aggregates.operators AS eligible_operators,
         operator_aggregates.operator_charging_points,
         geometry.centroid AS eligible_centroid,
         geometry.navigation_coordinate AS eligible_navigation_coordinate
  FROM base_parks AS base
  JOIN eligible_aggregates AS eligible USING (park_id)
  JOIN operator_aggregates USING (park_id)
  JOIN eligible_geometry AS geometry USING (park_id)
  CROSS JOIN parameters
  WHERE eligible.charging_point_count >= $5
    AND ST_DWithin(geometry.navigation_coordinate, parameters.route, 5000)
), live_point_states AS (
  SELECT base.park_id,
         membership.evse_key,
         CASE
           WHEN bool_or(observation.availability_state = 'unknown')
             OR count(DISTINCT observation.availability_state) > 1
             THEN 'unknown'
           ELSE min(observation.availability_state)
         END AS availability_state,
         max(observation.observed_at) FILTER (
           WHERE observation.availability_state <> 'unknown'
         ) AS observed_at
  FROM eligible_base AS base
  JOIN eligible_point_memberships AS membership USING (park_id)
  JOIN nextstop.availability_observations AS observation
    ON observation.snapshot_id = ANY($11::uuid[])
   AND observation.provider_id = membership.provider_id
   AND observation.provider_evse_key = membership.provider_evse_key
  WHERE cardinality($11::uuid[]) > 0
  GROUP BY base.park_id, membership.evse_key
), live_aggregates AS (
  SELECT park_id,
         count(*) FILTER (WHERE availability_state = 'available')::integer
           AS known_available_count,
         count(*) FILTER (
           WHERE availability_state IN ('occupied', 'out_of_service', 'reserved')
         )::integer AS known_unavailable_count,
         max(observed_at) AS last_live_observation_at
  FROM live_point_states
  GROUP BY park_id
), availability AS (
  SELECT base.*,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN base.eligible_known_available_count
           ELSE coalesce(live.known_available_count, 0)
         END AS resolved_known_available_count,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN base.eligible_known_unavailable_count
           ELSE coalesce(live.known_unavailable_count, 0)
         END AS resolved_known_unavailable_count,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN base.eligible_unknown_count
           ELSE base.eligible_charging_point_count
             - coalesce(live.known_available_count, 0)
             - coalesce(live.known_unavailable_count, 0)
         END AS resolved_unknown_count,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN base.eligible_last_live_observation_at
           ELSE live.last_live_observation_at
         END AS resolved_last_live_observation_at
  FROM eligible_base AS base
  LEFT JOIN live_aggregates AS live USING (park_id)
)
SELECT park_id AS id,
       CASE cardinality(eligible_operators)
         WHEN 1 THEN eligible_operators[1]
         WHEN 2 THEN eligible_operators[1] || ' & ' || eligible_operators[2]
         ELSE eligible_operators[1] || ' + ' || (cardinality(eligible_operators) - 1)::text
       END AS name,
       ST_Y(eligible_centroid::geometry) AS "centroidLatitude",
       ST_X(eligible_centroid::geometry) AS "centroidLongitude",
       ST_Y(eligible_navigation_coordinate::geometry) AS "navigationLatitude",
       ST_X(eligible_navigation_coordinate::geometry) AS "navigationLongitude",
       distance_from_route_meters AS "distanceFromRouteMeters",
       straight_line_lower_bound_meters AS "straightLineLowerBoundMeters",
       eligible_charging_point_count AS "chargingPoints",
       resolved_known_available_count AS "knownAvailable",
       resolved_known_unavailable_count AS "knownUnavailable",
       resolved_unknown_count AS unknown,
       resolved_unknown_count = 0 AS "availabilityComplete",
       resolved_last_live_observation_at AS "lastLiveObservationAt",
       eligible_maximum_power_kw AS "maximumPowerKW",
       eligible_operators AS operators,
       operator_charging_points AS "operatorChargingPoints",
       source_summaries AS sources,
       data_updated_at AS "dataUpdatedAt"
FROM availability
WHERE straight_line_lower_bound_meters <= $7
  AND (
    $8::integer IS NULL
    OR (straight_line_lower_bound_meters, park_id) > ($8, $9::uuid)
  )
ORDER BY straight_line_lower_bound_meters ASC, park_id ASC
LIMIT $10`;

function resolvePage(
  request: SearchRequest,
  requestFingerprint: string,
  pagination: SignedPaginationCodec,
): Readonly<{ snapshot?: SnapshotPayload; cursor?: CursorPayload }> {
  const snapshotToken = request.page?.snapshotToken;
  const cursorToken = request.page?.cursor;
  if (snapshotToken === undefined && cursorToken === undefined) {
    return {};
  }
  if (snapshotToken === undefined || cursorToken === undefined) {
    throw new InvalidPaginationTokenError();
  }
  const snapshot = pagination.decodeSnapshot(snapshotToken);
  const cursor = pagination.decodeCursor(cursorToken);
  if (
    snapshot.requestFingerprint !== requestFingerprint ||
    cursor.requestFingerprint !== requestFingerprint ||
    snapshot.projectionId !== cursor.projectionId ||
    !sameStrings(
      snapshot.availabilitySnapshotIds,
      cursor.availabilitySnapshotIds,
    )
  ) {
    throw new InvalidPaginationTokenError();
  }
  return { snapshot, cursor };
}

function fingerprintRequest(request: SearchRequest): string {
  return createHash("sha256")
    .update(
      JSON.stringify({
        route: {
          type: "LineString",
          coordinates: request.route.coordinates,
        },
        criteria: {
          distanceRangeMeters: {
            minimum: request.criteria.distanceRangeMeters.minimum,
            maximum: request.criteria.distanceRangeMeters.maximum,
          },
          minimumChargingPoints: request.criteria.minimumChargingPoints,
          minimumPowerKW: request.criteria.minimumPowerKW,
          foodChain: request.criteria.foodChain ?? null,
        },
      }),
    )
    .digest("hex");
}

function mapCandidate(
  row: CandidateRow,
  availabilitySnapshots: readonly AvailabilitySnapshotRow[],
): ChargingParkCandidate {
  const liveObservedByProvider = new Map(
    availabilitySnapshots.map(({ providerId, observedAt }) => [
      providerId,
      observedAt.toISOString(),
    ]),
  );
  return {
    id: row.id,
    name: row.name,
    coordinate: {
      latitude: row.centroidLatitude,
      longitude: row.centroidLongitude,
    },
    navigationCoordinate: {
      latitude: row.navigationLatitude,
      longitude: row.navigationLongitude,
    },
    distanceFromRouteMeters: row.distanceFromRouteMeters,
    straightLineLowerBoundMeters: row.straightLineLowerBoundMeters,
    chargingPoints: row.chargingPoints,
    availability: {
      knownAvailable: row.knownAvailable,
      knownUnavailable: row.knownUnavailable,
      unknown: row.unknown,
      total: row.chargingPoints,
      complete: row.availabilityComplete,
      observedAt: row.lastLiveObservationAt?.toISOString() ?? null,
    },
    maximumPowerKW: row.maximumPowerKW,
    operators: row.operators,
    operatorChargingPoints: row.operatorChargingPoints,
    sources: row.sources.map((source) => {
      const liveObservedAt = liveObservedByProvider.get(source.id);
      return liveObservedAt === undefined ? source : { ...source, liveObservedAt };
    }),
    dataUpdatedAt: row.dataUpdatedAt.toISOString(),
  };
}

function mapCoverage(
  projection: ProjectionRow,
  availabilitySnapshots: readonly AvailabilitySnapshotRow[],
): Coverage {
  const expectsSwissLive = projection.activeSources.includes(ichTankeStromDescriptor.id);
  const hasSwissLive = availabilitySnapshots.some(
    ({ providerId }) => providerId === ichTankeStromDescriptor.id,
  );
  const liveUnavailable = expectsSwissLive && !hasSwissLive;
  const status =
    projection.coverageStatus === "stale"
      ? "stale"
      : liveUnavailable
        ? "degraded"
        : projection.coverageStatus;
  return {
    status,
    activeSources: projection.activeSources,
    unavailableSources: [
      ...new Set([
        ...projection.unavailableSources,
        ...(liveUnavailable ? [`${ichTankeStromDescriptor.id}:live`] : []),
      ]),
    ].toSorted(),
    projectionUpdatedAt: projection.publishedAt.toISOString(),
  };
}

function sameStrings(first: readonly string[], second: readonly string[]): boolean {
  return first.length === second.length && first.every((value, index) => value === second[index]);
}
