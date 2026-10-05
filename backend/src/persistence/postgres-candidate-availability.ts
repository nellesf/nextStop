import type { Pool } from "pg";
import { availabilityLimits, InvalidAvailabilityContextError, type AvailabilityContext,
  type AvailabilityReading, type AvailabilityResponse, type AvailabilitySelection } from "../application/candidate-availability.js";

interface Row {
  readonly id: string; readonly operatorNames: string[]; readonly total: number;
  readonly knownAvailable: number; readonly knownUnavailable: number; readonly observedAt: Date | null;
  readonly needsSwissRefresh: boolean;
}

/** Read-only, bounded by selected public candidates. Canonical EVSE ownership matches the power projections. */
export class PostgresCandidateAvailability implements AvailabilityReading {
  constructor(private readonly pool: Pool) {}
  async read(context: AvailabilityContext, candidates: readonly AvailabilitySelection[], now: Date): ReturnType<AvailabilityReading["read"]> {
    const projection = await this.pool.query(`SELECT id FROM nextstop.projection_versions
      WHERE id = $1 AND status IN ('active','retired') AND search_pruned_at IS NULL`, [context.projectionId]);
    if (projection.rowCount !== 1) throw new InvalidAvailabilityContextError();
    const result = await this.pool.query<Row>(availabilityQuery, [context.projectionId, context.candidateKind,
      context.minimumPowerKW, JSON.stringify(candidates), new Date(now.getTime() - availabilityLimits.maximumAgeSeconds * 1_000),
      new Date(now.getTime() - availabilityLimits.refreshAfterSeconds * 1_000), now]);
    if (result.rows.length !== candidates.length || result.rows.some((row) => {
      const requested = candidates.find(({ id }) => id === row.id);
      return requested === undefined || row.operatorNames.length !== requested.operatorNames.length ||
        !requested.operatorNames.every((name) => row.operatorNames.includes(name));
    })) throw new InvalidAvailabilityContextError();
    // Retention can begin between validation and aggregation; never return partially pruned counts.
    const retained = await this.pool.query(`SELECT id FROM nextstop.projection_versions
      WHERE id = $1 AND status IN ('active','retired') AND search_pruned_at IS NULL`, [context.projectionId]);
    if (retained.rowCount !== 1) throw new InvalidAvailabilityContextError();
    const values: AvailabilityResponse["candidates"] = candidates.map((selection) => {
      const row = result.rows.find(({ id }) => id === selection.id);
      if (row === undefined) throw new InvalidAvailabilityContextError();
      const unknown = row.total - row.knownAvailable - row.knownUnavailable;
      return { ...selection, availability: { knownAvailable: row.knownAvailable, knownUnavailable: row.knownUnavailable,
        unknown, total: row.total, complete: unknown === 0,
        ...(row.observedAt === null ? {} : { observedAt: row.observedAt.toISOString() }) } };
    });
    return { candidates: values, needsSwissRefresh: result.rows.some(({ needsSwissRefresh }) => needsSwissRefresh) };
  }
}

const availabilityQuery = `
WITH requested AS (
  SELECT id::uuid, "operatorNames" FROM jsonb_to_recordset($4::jsonb) AS r(id text, "operatorNames" text[])
), locations AS (
  SELECT r.id, membership.location_id
  FROM requested r JOIN nextstop.charging_park_location_memberships membership
    ON $2 = 'park' AND membership.projection_id = $1 AND membership.park_id = r.id
  UNION ALL
  SELECT r.id, membership.location_id
  FROM requested r JOIN nextstop.charging_campus_park_memberships campus
    ON $2 = 'campus' AND campus.projection_id = $1 AND campus.campus_id = r.id
  JOIN nextstop.charging_park_location_memberships membership
    ON membership.projection_id = campus.projection_id AND membership.park_id = campus.park_id
), memberships AS (
  SELECT locations.id, point.charging_point_id, location.operator_name, point.provider_id, point.provider_evse_key,
    CASE WHEN point.canonical_evse_identity IS NULL THEN 'source:' || COALESCE(point.provider_id, 'legacy') || ':' || point.charging_point_id::text
      WHEN EXISTS (SELECT 1 FROM nextstop.projection_conflicts conflict WHERE conflict.projection_id = point.projection_id
        AND conflict.canonical_evse_identity = point.canonical_evse_identity AND conflict.resolution = 'kept_distinct')
        THEN 'point:' || point.charging_point_id::text
      ELSE 'canonical:' || point.canonical_evse_identity END AS evse_key
  FROM locations JOIN nextstop.normalized_charging_points point
    ON point.projection_id = $1 AND point.location_id = locations.location_id AND point.maximum_power_kw >= $3
  JOIN nextstop.normalized_charging_locations location
    ON location.projection_id = point.projection_id AND location.location_id = point.location_id
), evses AS (
  SELECT membership.id, membership.evse_key,
    (array_agg(membership.operator_name ORDER BY membership.charging_point_id, membership.operator_name))[1] AS operator_name,
    bool_or(membership.provider_id = 'ich_tanke_strom') AS swiss,
    CASE WHEN bool_or(observation.availability_state = 'unknown') OR count(DISTINCT observation.availability_state) <> 1
      THEN 'unknown' ELSE min(observation.availability_state) END AS state,
    min(observation.observed_at) FILTER (WHERE observation.availability_state <> 'unknown') AS observed_at,
    bool_or(membership.provider_id = 'ich_tanke_strom' AND (snapshot.id IS NULL OR snapshot.observed_at < $6)) AS refresh
  FROM memberships membership
  LEFT JOIN nextstop.availability_snapshots snapshot ON snapshot.provider_id = membership.provider_id
    AND snapshot.status = 'active' AND snapshot.observed_at >= $5 AND snapshot.observed_at <= $7
  LEFT JOIN nextstop.availability_observations observation ON observation.snapshot_id = snapshot.id
    AND observation.provider_id = membership.provider_id AND observation.provider_evse_key = membership.provider_evse_key
    AND observation.observed_at >= $5 AND observation.observed_at <= $7
  GROUP BY membership.id, membership.evse_key
)
SELECT evses.id, array_agg(DISTINCT operator_name ORDER BY operator_name) AS "operatorNames", count(*)::int AS total,
  count(*) FILTER (WHERE state = 'available')::int AS "knownAvailable",
  count(*) FILTER (WHERE state IN ('occupied','reserved','out_of_service'))::int AS "knownUnavailable",
  min(observed_at) FILTER (WHERE state <> 'unknown') AS "observedAt",
  bool_or(swiss AND refresh) AS "needsSwissRefresh"
FROM evses JOIN requested ON requested.id = evses.id AND evses.operator_name = ANY(requested."operatorNames")
GROUP BY evses.id`;
