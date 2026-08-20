import { createHash } from "node:crypto";

import type { Pool } from "pg";

import type { CandidateSearching } from "./candidate-search.js";
import {
  FoodPOIDataUnavailableError,
  NoProjectionAvailableError,
} from "./candidate-search.js";
import {
  InvalidPaginationTokenError,
  type CursorPayload,
  type SignedPaginationCodec,
  type SnapshotPayload,
} from "./signed-pagination.js";
import type {
  ChargingLocationLookup,
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
import { openStreetMapFoodPOIDescriptor } from "../providers/openstreetmap/descriptor.js";

const pageSize = 50;

interface ProjectionRow {
  readonly id: string;
  readonly campusCount: number;
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
  readonly locationLookups: ChargingLocationLookup[];
  readonly sources: SourceSummary[];
  readonly dataUpdatedAt: Date;
  readonly foodOSMType: "node" | "way" | "relation" | null;
  readonly foodOSMId: string | null;
  readonly foodChain: "mcdonalds" | "burger_king" | "kfc" | "subway" | null;
  readonly foodName: string | null;
  readonly foodLatitude: number | null;
  readonly foodLongitude: number | null;
  readonly foodDistanceMeters: number | null;
  readonly foodOpeningHours: string | null;
  readonly foodSourceRecordURL: string | null;
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
    if (
      projection === undefined ||
      (request.criteria.foodChain == null && projection.campusCount === 0)
    ) {
      throw new NoProjectionAvailableError();
    }
    const foodProjectionId = await this.resolveFoodProjectionId(request, page.snapshot);
    const availabilitySnapshots = await this.resolveAvailabilitySnapshots(
      projection,
      page.snapshot,
    );
    const availabilitySnapshotIds = availabilitySnapshots
      .map(({ id }) => id)
      .toSorted();
    const snapshot: SnapshotPayload = page.snapshot ?? {
      kind: "snapshot",
      version: 3,
      projectionId: projection.id,
      foodProjectionId,
      availabilitySnapshotIds,
      requestFingerprint,
    };
    const rows = await this.candidates(
      projection.id,
      availabilitySnapshotIds,
      request,
      page.cursor,
      foodProjectionId,
    );
    const hasNextPage = rows.length > pageSize;
    const visibleRows = rows.slice(0, pageSize);
    const last = visibleRows.at(-1);
    const nextCursor =
      hasNextPage && last !== undefined
        ? this.pagination.encode({
            kind: "cursor",
            version: 3,
            projectionId: projection.id,
            foodProjectionId,
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
      attributions: request.criteria.foodChain == null
        ? []
        : [{
            id: openStreetMapFoodPOIDescriptor.id,
            name: openStreetMapFoodPOIDescriptor.name,
            notice: openStreetMapFoodPOIDescriptor.attributionNotice,
            licenseName: openStreetMapFoodPOIDescriptor.licenseName,
            licenseURL: openStreetMapFoodPOIDescriptor.licenseURL,
            transportName: openStreetMapFoodPOIDescriptor.transportName,
            transportURL: openStreetMapFoodPOIDescriptor.transportURL,
          }],
    };
  }

  private async resolveFoodProjectionId(
    request: SearchRequest,
    snapshot: SnapshotPayload | undefined,
  ): Promise<string | null> {
    if (request.criteria.foodChain == null) return null;
    const expectedId = snapshot?.foodProjectionId;
    const result = await this.pool.query<{ readonly id: string }>(
      expectedId === undefined
        ? "SELECT id FROM nextstop.food_poi_projection_versions WHERE status = 'active'"
        : `SELECT id FROM nextstop.food_poi_projection_versions
           WHERE id = $1 AND status IN ('active', 'retired')`,
      expectedId === undefined ? [] : [expectedId],
    );
    const id = result.rows[0]?.id;
    if (id === undefined) throw new FoodPOIDataUnavailableError();
    return id;
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
              campus_count AS "campusCount",
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
              campus_count AS "campusCount",
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
    foodProjectionId: string | null,
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
        foodProjectionId,
        request.criteria.foodChain ?? null,
      ],
    );
    return result.rows;
  }
}

const candidateQuery = `
WITH parameters AS (
  SELECT ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)::geography AS route,
         ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography AS origin
), eligible_base AS MATERIALIZED (
  SELECT 'park'::text AS candidate_kind,
         power.projection_id,
         power.park_id AS candidate_id,
         power.centroid,
         power.navigation_coordinate,
         power.charging_point_count,
         power.known_available_count,
         power.known_unavailable_count,
         power.unknown_count,
         power.last_live_observation_at,
         power.maximum_power_kw,
         power.operators,
         power.operator_charging_point_counts,
         park.source_summaries,
         park.data_updated_at,
         round(ST_Distance(
           power.navigation_coordinate,
           parameters.route
         ))::integer AS distance_from_route_meters,
         ceil(ST_Distance(
           power.navigation_coordinate,
           parameters.origin
         ))::integer AS straight_line_lower_bound_meters
  FROM nextstop.charging_park_power_projection AS power
  JOIN nextstop.charging_park_projection AS park
    ON park.projection_id = power.projection_id
   AND park.park_id = power.park_id
  CROSS JOIN parameters
  WHERE $13::text IS NOT NULL
    AND power.projection_id = $1
    AND power.minimum_power_kw = $6
    AND power.charging_point_count >= $5
    AND ST_DWithin(power.navigation_coordinate, parameters.route, 5000)
    AND ST_DWithin(power.navigation_coordinate, parameters.origin, $7)
  UNION ALL
  SELECT 'campus'::text AS candidate_kind,
         power.projection_id,
         power.campus_id AS candidate_id,
         power.centroid,
         power.navigation_coordinate,
         power.charging_point_count,
         power.known_available_count,
         power.known_unavailable_count,
         power.unknown_count,
         power.last_live_observation_at,
         power.maximum_power_kw,
         power.operators,
         power.operator_charging_point_counts,
         campus.source_summaries,
         campus.data_updated_at,
         round(ST_Distance(
           power.navigation_coordinate,
           parameters.route
         ))::integer AS distance_from_route_meters,
         ceil(ST_Distance(
           power.navigation_coordinate,
           parameters.origin
         ))::integer AS straight_line_lower_bound_meters
  FROM nextstop.charging_campus_power_projection AS power
  JOIN nextstop.charging_campus_projection AS campus
    ON campus.projection_id = power.projection_id
   AND campus.campus_id = power.campus_id
  CROSS JOIN parameters
  WHERE $13::text IS NULL
    AND power.projection_id = $1
    AND power.minimum_power_kw = $6
    AND power.charging_point_count >= $5
    AND ST_DWithin(power.navigation_coordinate, parameters.route, 5000)
    AND ST_DWithin(power.navigation_coordinate, parameters.origin, $7)
), selected_candidates AS MATERIALIZED (
  SELECT base.*,
         food.osm_type AS food_osm_type,
         food.osm_id AS food_osm_id,
         food.chain AS food_chain,
         food.name AS food_name,
         food.coordinate AS food_coordinate,
         food.distance_meters AS food_distance_meters,
         food.opening_hours AS food_opening_hours,
         food.source_record_url AS food_source_record_url
  FROM eligible_base AS base
  LEFT JOIN LATERAL (
    SELECT poi.osm_type, poi.osm_id, poi.chain, poi.name, poi.coordinate,
           poi.opening_hours, poi.source_record_url,
           round(ST_Distance(
             poi.coordinate,
             base.navigation_coordinate
           ))::integer AS distance_meters
    FROM nextstop.charging_park_food_poi_matches AS match
    JOIN nextstop.food_poi_projection AS poi
      ON poi.projection_id = match.food_projection_id
     AND poi.osm_type = match.osm_type
     AND poi.osm_id = match.osm_id
    WHERE match.charging_projection_id = base.projection_id
      AND match.food_projection_id = $12::uuid
      AND match.park_id = base.candidate_id
      AND poi.chain = $13::text
      AND ST_DWithin(
        poi.coordinate,
        base.navigation_coordinate,
        500
      )
    ORDER BY ST_Distance(poi.coordinate, base.navigation_coordinate),
             poi.osm_type, poi.osm_id
    LIMIT 1
  ) AS food ON base.candidate_kind = 'park' AND $13::text IS NOT NULL
  WHERE (base.candidate_kind = 'campus' OR food.osm_id IS NOT NULL)
    AND (
      $8::integer IS NULL
      OR (base.straight_line_lower_bound_meters, base.candidate_id) > ($8, $9::uuid)
    )
  ORDER BY base.straight_line_lower_bound_meters, base.candidate_id
  LIMIT $10
), selected_candidate_locations AS (
  SELECT candidate.projection_id,
         candidate.candidate_id,
         membership.location_id
  FROM selected_candidates AS candidate
  JOIN nextstop.charging_park_location_memberships AS membership
    ON candidate.candidate_kind = 'park'
   AND membership.projection_id = candidate.projection_id
   AND membership.park_id = candidate.candidate_id
  UNION ALL
  SELECT candidate.projection_id,
         candidate.candidate_id,
         park_location.location_id
  FROM selected_candidates AS candidate
  JOIN nextstop.charging_campus_park_memberships AS campus
    ON candidate.candidate_kind = 'campus'
   AND campus.projection_id = candidate.projection_id
   AND campus.campus_id = candidate.candidate_id
  JOIN nextstop.charging_park_location_memberships AS park_location
    ON park_location.projection_id = campus.projection_id
   AND park_location.park_id = campus.park_id
), eligible_point_memberships AS (
  SELECT candidate.projection_id,
         candidate.candidate_id,
         point.location_id,
         point.charging_point_id,
         point.provider_id,
         point.provider_evse_key,
         CASE
           WHEN point.canonical_evse_identity IS NULL
             THEN 'source:' || COALESCE(point.provider_id, 'legacy') || ':'
               || point.charging_point_id::text
           WHEN EXISTS (
             SELECT 1
             FROM nextstop.projection_conflicts AS conflict
             WHERE conflict.projection_id = point.projection_id
               AND conflict.canonical_evse_identity = point.canonical_evse_identity
               AND conflict.resolution = 'kept_distinct'
           )
             THEN 'point:' || point.charging_point_id::text
           ELSE 'canonical:' || point.canonical_evse_identity
         END AS evse_key
  FROM selected_candidate_locations AS candidate
  JOIN nextstop.normalized_charging_points AS point
    ON point.projection_id = candidate.projection_id
   AND point.location_id = candidate.location_id
  WHERE point.maximum_power_kw >= $6
), location_lookup_aggregates AS (
  SELECT eligible.candidate_id,
         jsonb_agg(
           jsonb_build_object(
             'id', location.location_id,
             'operatorName', location.operator_name,
             'coordinate', jsonb_build_object(
               'latitude', ST_Y(location.coordinate::geometry),
               'longitude', ST_X(location.coordinate::geometry)
             ),
             'address', jsonb_strip_nulls(jsonb_build_object(
               'street', location.address->>'street',
               'houseNumber', location.address->>'houseNumber',
               'postalCode', location.address->>'postalCode',
               'city', location.address->>'city'
             ))
           )
           ORDER BY location.operator_name, location.location_id
         ) AS location_lookups
  FROM (
    SELECT DISTINCT projection_id, candidate_id, location_id
    FROM eligible_point_memberships
  ) AS eligible
  JOIN selected_candidates AS candidate
    ON candidate.projection_id = eligible.projection_id
   AND candidate.candidate_id = eligible.candidate_id
  JOIN nextstop.normalized_charging_locations AS location
    ON location.projection_id = eligible.projection_id
   AND location.location_id = eligible.location_id
   AND location.operator_name = ANY(candidate.operators)
  GROUP BY eligible.candidate_id
), live_point_states AS (
  SELECT candidate.candidate_id,
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
  FROM selected_candidates AS candidate
  JOIN eligible_point_memberships AS membership USING (candidate_id)
  JOIN nextstop.availability_observations AS observation
    ON observation.snapshot_id = ANY($11::uuid[])
   AND observation.provider_id = membership.provider_id
   AND observation.provider_evse_key = membership.provider_evse_key
  WHERE cardinality($11::uuid[]) > 0
  GROUP BY candidate.candidate_id, membership.evse_key
), live_aggregates AS (
  SELECT candidate_id,
         count(*) FILTER (WHERE availability_state = 'available')::integer
           AS known_available_count,
         count(*) FILTER (
           WHERE availability_state IN ('occupied', 'out_of_service', 'reserved')
         )::integer AS known_unavailable_count,
         max(observed_at) AS last_live_observation_at
  FROM live_point_states
  GROUP BY candidate_id
), availability AS (
  SELECT candidate.*,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN candidate.known_available_count
           ELSE coalesce(live.known_available_count, 0)
         END AS resolved_known_available_count,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN candidate.known_unavailable_count
           ELSE coalesce(live.known_unavailable_count, 0)
         END AS resolved_known_unavailable_count,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN candidate.unknown_count
           ELSE candidate.charging_point_count
             - coalesce(live.known_available_count, 0)
             - coalesce(live.known_unavailable_count, 0)
         END AS resolved_unknown_count,
         CASE WHEN cardinality($11::uuid[]) = 0
           THEN candidate.last_live_observation_at
           ELSE live.last_live_observation_at
         END AS resolved_last_live_observation_at
  FROM selected_candidates AS candidate
  LEFT JOIN live_aggregates AS live USING (candidate_id)
)
SELECT candidate_id AS id,
       CASE cardinality(operators)
         WHEN 1 THEN operators[1]
         WHEN 2 THEN operators[1] || ' & ' || operators[2]
         ELSE operators[1] || ' + ' || (cardinality(operators) - 1)::text
       END AS name,
       ST_Y(centroid::geometry) AS "centroidLatitude",
       ST_X(centroid::geometry) AS "centroidLongitude",
       ST_Y(navigation_coordinate::geometry) AS "navigationLatitude",
       ST_X(navigation_coordinate::geometry) AS "navigationLongitude",
       distance_from_route_meters AS "distanceFromRouteMeters",
       straight_line_lower_bound_meters AS "straightLineLowerBoundMeters",
       charging_point_count AS "chargingPoints",
       resolved_known_available_count AS "knownAvailable",
       resolved_known_unavailable_count AS "knownUnavailable",
       resolved_unknown_count AS unknown,
       resolved_unknown_count = 0 AS "availabilityComplete",
       resolved_last_live_observation_at AS "lastLiveObservationAt",
       maximum_power_kw AS "maximumPowerKW",
       operators,
       operator_charging_point_counts AS "operatorChargingPoints",
       lookup.location_lookups AS "locationLookups",
       source_summaries AS sources,
       data_updated_at AS "dataUpdatedAt",
       food_osm_type AS "foodOSMType",
       food_osm_id::text AS "foodOSMId",
       food_chain AS "foodChain",
       food_name AS "foodName",
       ST_Y(food_coordinate::geometry) AS "foodLatitude",
       ST_X(food_coordinate::geometry) AS "foodLongitude",
       food_distance_meters AS "foodDistanceMeters",
       food_opening_hours AS "foodOpeningHours",
       food_source_record_url AS "foodSourceRecordURL"
FROM availability
JOIN location_lookup_aggregates AS lookup USING (candidate_id)
ORDER BY straight_line_lower_bound_meters ASC, candidate_id ASC
`;

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
    snapshot.foodProjectionId !== cursor.foodProjectionId ||
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
    locationLookups: row.locationLookups,
    sources: row.sources.map((source) => {
      const liveObservedAt = liveObservedByProvider.get(source.id);
      return liveObservedAt === undefined ? source : { ...source, liveObservedAt };
    }),
    dataUpdatedAt: row.dataUpdatedAt.toISOString(),
    foodPOI:
      row.foodOSMType === null ||
      row.foodOSMId === null ||
      row.foodChain === null ||
      row.foodName === null ||
      row.foodLatitude === null ||
      row.foodLongitude === null ||
      row.foodDistanceMeters === null ||
      row.foodSourceRecordURL === null
        ? null
        : {
            id: `osm:${row.foodOSMType}:${row.foodOSMId}`,
            chain: row.foodChain,
            name: row.foodName,
            coordinate: {
              latitude: row.foodLatitude,
              longitude: row.foodLongitude,
            },
            distanceFromChargingParkMeters: row.foodDistanceMeters,
            openingHours: row.foodOpeningHours,
            sourceRecordURL: row.foodSourceRecordURL,
          },
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
