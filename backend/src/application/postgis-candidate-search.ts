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
  readonly sources: SourceSummary[];
  readonly dataUpdatedAt: Date;
}

export class PostGISCandidateSearch implements CandidateSearching {
  constructor(
    private readonly pool: Pool,
    private readonly pagination: SignedPaginationCodec,
    private readonly now: () => Date = () => new Date(),
  ) {}

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
    const snapshot: SnapshotPayload = page.snapshot ?? {
      kind: "snapshot",
      version: 1,
      projectionId: projection.id,
      requestFingerprint,
    };
    const rows = await this.candidates(projection.id, request, page.cursor);
    const hasNextPage = rows.length > pageSize;
    const visibleRows = rows.slice(0, pageSize);
    const last = visibleRows.at(-1);
    const nextCursor =
      hasNextPage && last !== undefined
        ? this.pagination.encode({
            kind: "cursor",
            version: 1,
            projectionId: projection.id,
            requestFingerprint,
            lowerBoundMeters: last.straightLineLowerBoundMeters,
            parkId: last.id,
          })
        : null;

    return {
      snapshotToken: this.pagination.encode(snapshot),
      nextCursor,
      generatedAt: this.now().toISOString(),
      candidates: visibleRows.map(mapCandidate),
      coverage: {
        status: projection.coverageStatus,
        activeSources: projection.activeSources,
        unavailableSources: projection.unavailableSources,
        projectionUpdatedAt: projection.publishedAt.toISOString(),
      },
    };
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
        request.criteria.minimumAvailablePoints ?? null,
        request.criteria.distanceRangeMeters.maximum,
        cursor?.lowerBoundMeters ?? null,
        cursor?.parkId ?? null,
        pageSize + 1,
      ],
    );
    return result.rows;
  }
}

const candidateQuery = `
WITH parameters AS (
  SELECT ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)::geography AS route,
         ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography AS origin
), filtered AS (
  SELECT park.*,
         round(ST_Distance(park.navigation_coordinate, parameters.route))::integer
           AS distance_from_route_meters,
         ceil(ST_Distance(park.navigation_coordinate, parameters.origin))::integer
           AS straight_line_lower_bound_meters
  FROM nextstop.charging_park_projection AS park
  CROSS JOIN parameters
  WHERE park.projection_id = $1
    AND ST_DWithin(park.navigation_coordinate, parameters.route, 5000)
    AND park.charging_point_count >= $5
    AND park.maximum_power_kw >= $6
    AND ($7::integer IS NULL OR park.known_available_count + park.unknown_count >= $7)
)
SELECT park_id AS id,
       name,
       ST_Y(centroid::geometry) AS "centroidLatitude",
       ST_X(centroid::geometry) AS "centroidLongitude",
       ST_Y(navigation_coordinate::geometry) AS "navigationLatitude",
       ST_X(navigation_coordinate::geometry) AS "navigationLongitude",
       distance_from_route_meters AS "distanceFromRouteMeters",
       straight_line_lower_bound_meters AS "straightLineLowerBoundMeters",
       charging_point_count AS "chargingPoints",
       known_available_count AS "knownAvailable",
       known_unavailable_count AS "knownUnavailable",
       unknown_count AS unknown,
       availability_complete AS "availabilityComplete",
       last_live_observation_at AS "lastLiveObservationAt",
       maximum_power_kw AS "maximumPowerKW",
       operators,
       source_summaries AS sources,
       data_updated_at AS "dataUpdatedAt"
FROM filtered
WHERE straight_line_lower_bound_meters <= $8
  AND (
    $9::integer IS NULL
    OR (straight_line_lower_bound_meters, park_id) > ($9, $10::uuid)
  )
ORDER BY straight_line_lower_bound_meters ASC, park_id ASC
LIMIT $11`;

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
    snapshot.projectionId !== cursor.projectionId
  ) {
    throw new InvalidPaginationTokenError();
  }
  return { snapshot, cursor };
}

function fingerprintRequest(request: SearchRequest): string {
  return createHash("sha256")
    .update(
      JSON.stringify({
        route: request.route,
        criteria: request.criteria,
      }),
    )
    .digest("hex");
}

function mapCandidate(row: CandidateRow): ChargingParkCandidate {
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
    sources: row.sources,
    dataUpdatedAt: row.dataUpdatedAt.toISOString(),
  };
}
