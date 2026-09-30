BEGIN;

-- Leave every published projection untouched. These replacements take effect only
-- when a worker builds a version, and keep the existing domain aggregation rules.
-- Staging is session-local and bounded to that version, independent of the number
-- of historical projections or when autovacuum last analyzed the shared tables.

CREATE OR REPLACE FUNCTION nextstop.rebuild_charging_park_power_projection(
  target_projection_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- A just-loaded UUID is absent from the shared tables' last statistics.
  -- Copy each source independently before joining: these tables contain exactly
  -- one version and ANALYZE samples the new build even inside a transaction.
  -- The worker owns its temporary tables; no owner/MAINTAIN privilege is needed.
  CREATE TEMPORARY TABLE power_build_candidates ON COMMIT DROP AS
  SELECT projection_id, park_id, navigation_coordinate, member_location_ids
  FROM nextstop.charging_park_projection
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_candidates (park_id);

  CREATE TEMPORARY TABLE power_build_locations ON COMMIT DROP AS
  SELECT projection_id, location_id, operator_name, coordinate
  FROM nextstop.normalized_charging_locations
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_locations (location_id);

  CREATE TEMPORARY TABLE power_build_points ON COMMIT DROP AS
  SELECT projection_id, location_id, charging_point_id, provider_id,
         canonical_evse_identity, maximum_power_kw, availability_state,
         availability_is_live, availability_observed_at
  FROM nextstop.normalized_charging_points
  WHERE projection_id = target_projection_id;
  CREATE INDEX ON power_build_points (location_id);

  CREATE TEMPORARY TABLE power_build_conflicts ON COMMIT DROP AS
  SELECT DISTINCT projection_id, canonical_evse_identity, resolution
  FROM nextstop.projection_conflicts
  WHERE projection_id = target_projection_id AND resolution = 'kept_distinct';
  CREATE UNIQUE INDEX ON power_build_conflicts (canonical_evse_identity);

  ANALYZE pg_temp.power_build_candidates;
  ANALYZE pg_temp.power_build_locations;
  ANALYZE pg_temp.power_build_points;
  ANALYZE pg_temp.power_build_conflicts;

  DELETE FROM nextstop.charging_park_power_projection
  WHERE projection_id = target_projection_id;

  DELETE FROM nextstop.charging_park_location_memberships
  WHERE projection_id = target_projection_id;

  INSERT INTO nextstop.charging_park_location_memberships (
    projection_id, park_id, location_id
  )
  SELECT park.projection_id, park.park_id, member.location_id
  FROM nextstop.charging_park_projection AS park
  CROSS JOIN LATERAL unnest(park.member_location_ids) AS member(location_id)
  WHERE park.projection_id = target_projection_id;

  CREATE TEMPORARY TABLE power_build_park_memberships ON COMMIT DROP AS
  SELECT projection_id, park_id, location_id
  FROM nextstop.charging_park_location_memberships
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_park_memberships (park_id, location_id);
  CREATE INDEX ON power_build_park_memberships (location_id);
  ANALYZE pg_temp.power_build_park_memberships;

  INSERT INTO nextstop.charging_park_power_projection (
    projection_id,
    park_id,
    minimum_power_kw,
    centroid,
    navigation_coordinate,
    charging_point_count,
    known_available_count,
    known_unavailable_count,
    unknown_count,
    last_live_observation_at,
    maximum_power_kw,
    operators,
    operator_charging_point_counts
  )
  WITH power_thresholds(minimum_power_kw) AS (
    VALUES (11), (22), (50), (100), (150), (200), (250), (300), (350), (400)
  ), eligible_point_memberships AS (
    SELECT membership.projection_id,
           membership.park_id,
           threshold.minimum_power_kw,
           location.location_id,
           location.operator_name,
           location.coordinate AS location_coordinate,
           point.charging_point_id,
           point.maximum_power_kw,
           point.availability_state,
           point.availability_is_live,
           point.availability_observed_at,
           CASE
             WHEN point.canonical_evse_identity IS NULL
               THEN 'source:' || COALESCE(point.provider_id, 'legacy') || ':'
                 || point.charging_point_id::text
             WHEN EXISTS (
               SELECT 1
               FROM pg_temp.power_build_conflicts AS conflict
               WHERE conflict.projection_id = point.projection_id
                 AND conflict.canonical_evse_identity = point.canonical_evse_identity
                 AND conflict.resolution = 'kept_distinct'
             )
               THEN 'point:' || point.charging_point_id::text
             ELSE 'canonical:' || point.canonical_evse_identity
           END AS evse_key
    FROM pg_temp.power_build_park_memberships AS membership
    JOIN pg_temp.power_build_locations AS location
      ON location.projection_id = membership.projection_id
     AND location.location_id = membership.location_id
    JOIN pg_temp.power_build_points AS point
      ON point.projection_id = location.projection_id
     AND point.location_id = location.location_id
    JOIN power_thresholds AS threshold
      ON point.maximum_power_kw >= threshold.minimum_power_kw
    WHERE membership.projection_id = target_projection_id
  ), eligible_evses AS (
    SELECT projection_id,
           park_id,
           minimum_power_kw,
           evse_key,
           (array_agg(operator_name ORDER BY charging_point_id, operator_name))[1]
             AS operator_name,
           max(maximum_power_kw)::integer AS maximum_power_kw,
           CASE
             WHEN bool_and(availability_is_live)
               AND count(DISTINCT availability_state) = 1
               THEN min(availability_state)
             ELSE 'unknown'
           END AS availability_state,
           max(availability_observed_at) FILTER (
             WHERE availability_is_live AND availability_state <> 'unknown'
           ) AS availability_observed_at
    FROM eligible_point_memberships
    GROUP BY projection_id, park_id, minimum_power_kw, evse_key
  ), eligible_aggregates AS (
    SELECT projection_id,
           park_id,
           minimum_power_kw,
           count(*)::integer AS charging_point_count,
           count(*) FILTER (
             WHERE availability_state = 'available'
           )::integer AS known_available_count,
           count(*) FILTER (
             WHERE availability_state IN ('occupied', 'out_of_service', 'reserved')
           )::integer AS known_unavailable_count,
           count(*) FILTER (
             WHERE availability_state = 'unknown'
           )::integer AS unknown_count,
           max(availability_observed_at) AS last_live_observation_at,
           max(maximum_power_kw)::integer AS maximum_power_kw
    FROM eligible_evses
    GROUP BY projection_id, park_id, minimum_power_kw
  ), operator_groups AS (
    SELECT projection_id,
           park_id,
           minimum_power_kw,
           operator_name,
           count(*)::integer AS charging_point_count
    FROM eligible_evses
    GROUP BY projection_id, park_id, minimum_power_kw, operator_name
  ), operator_aggregates AS (
    SELECT projection_id,
           park_id,
           minimum_power_kw,
           array_agg(operator_name ORDER BY operator_name) AS operators,
           jsonb_agg(
             jsonb_build_object(
               'name', operator_name,
               'chargingPoints', charging_point_count
             )
             ORDER BY operator_name
           ) AS operator_charging_point_counts
    FROM operator_groups
    GROUP BY projection_id, park_id, minimum_power_kw
  ), eligible_locations AS (
    SELECT DISTINCT projection_id,
           park_id,
           minimum_power_kw,
           location_id,
           location_coordinate
    FROM eligible_point_memberships
  ), eligible_geometry AS (
    SELECT location.projection_id,
           location.park_id,
           location.minimum_power_kw,
           ST_Centroid(ST_Collect(location.location_coordinate::geometry))::geography
             AS centroid,
           (array_agg(
             location.location_coordinate
             ORDER BY ST_Distance(
               location.location_coordinate,
               park.navigation_coordinate
             ), location.location_id
           ))[1] AS navigation_coordinate
    FROM eligible_locations AS location
    JOIN pg_temp.power_build_candidates AS park
      ON park.projection_id = location.projection_id
     AND park.park_id = location.park_id
    GROUP BY location.projection_id, location.park_id, location.minimum_power_kw
  )
  SELECT aggregate.projection_id,
         aggregate.park_id,
         aggregate.minimum_power_kw,
         geometry.centroid,
         geometry.navigation_coordinate,
         aggregate.charging_point_count,
         aggregate.known_available_count,
         aggregate.known_unavailable_count,
         aggregate.unknown_count,
         aggregate.last_live_observation_at,
         aggregate.maximum_power_kw,
         operator.operators,
         operator.operator_charging_point_counts
  FROM eligible_aggregates AS aggregate
  JOIN operator_aggregates AS operator
    USING (projection_id, park_id, minimum_power_kw)
  JOIN eligible_geometry AS geometry
    USING (projection_id, park_id, minimum_power_kw);
  DROP TABLE pg_temp.power_build_candidates,
             pg_temp.power_build_locations,
             pg_temp.power_build_points,
             pg_temp.power_build_conflicts,
             pg_temp.power_build_park_memberships;
END;
$function$;

CREATE OR REPLACE FUNCTION nextstop.rebuild_charging_campus_power_projection(
  target_projection_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- A just-loaded UUID is absent from the shared tables' last statistics.
  -- Copy each source independently before joining: these tables contain exactly
  -- one version and ANALYZE samples the new build even inside a transaction.
  -- The worker owns its temporary tables; no owner/MAINTAIN privilege is needed.
  CREATE TEMPORARY TABLE power_build_candidates ON COMMIT DROP AS
  SELECT projection_id, campus_id, navigation_coordinate, member_park_ids
  FROM nextstop.charging_campus_projection
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_candidates (campus_id);

  CREATE TEMPORARY TABLE power_build_locations ON COMMIT DROP AS
  SELECT projection_id, location_id, operator_name, coordinate
  FROM nextstop.normalized_charging_locations
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_locations (location_id);

  CREATE TEMPORARY TABLE power_build_points ON COMMIT DROP AS
  SELECT projection_id, location_id, charging_point_id, provider_id,
         canonical_evse_identity, maximum_power_kw, availability_state,
         availability_is_live, availability_observed_at
  FROM nextstop.normalized_charging_points
  WHERE projection_id = target_projection_id;
  CREATE INDEX ON power_build_points (location_id);

  CREATE TEMPORARY TABLE power_build_conflicts ON COMMIT DROP AS
  SELECT DISTINCT projection_id, canonical_evse_identity, resolution
  FROM nextstop.projection_conflicts
  WHERE projection_id = target_projection_id AND resolution = 'kept_distinct';
  CREATE UNIQUE INDEX ON power_build_conflicts (canonical_evse_identity);

  ANALYZE pg_temp.power_build_candidates;
  ANALYZE pg_temp.power_build_locations;
  ANALYZE pg_temp.power_build_points;
  ANALYZE pg_temp.power_build_conflicts;

  DELETE FROM nextstop.charging_campus_power_projection
  WHERE projection_id = target_projection_id;

  DELETE FROM nextstop.charging_campus_park_memberships
  WHERE projection_id = target_projection_id;

  INSERT INTO nextstop.charging_campus_park_memberships (
    projection_id, campus_id, park_id
  )
  SELECT campus.projection_id, campus.campus_id, member.park_id
  FROM nextstop.charging_campus_projection AS campus
  CROSS JOIN LATERAL unnest(campus.member_park_ids) AS member(park_id)
  WHERE campus.projection_id = target_projection_id;

  CREATE TEMPORARY TABLE power_build_park_memberships ON COMMIT DROP AS
  SELECT projection_id, park_id, location_id
  FROM nextstop.charging_park_location_memberships
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_park_memberships (park_id, location_id);
  CREATE INDEX ON power_build_park_memberships (location_id);
  ANALYZE pg_temp.power_build_park_memberships;

  CREATE TEMPORARY TABLE power_build_campus_memberships ON COMMIT DROP AS
  SELECT projection_id, campus_id, park_id
  FROM nextstop.charging_campus_park_memberships
  WHERE projection_id = target_projection_id;
  CREATE UNIQUE INDEX ON power_build_campus_memberships (park_id);
  ANALYZE pg_temp.power_build_campus_memberships;

  INSERT INTO nextstop.charging_campus_power_projection (
    projection_id,
    campus_id,
    minimum_power_kw,
    centroid,
    navigation_coordinate,
    charging_point_count,
    known_available_count,
    known_unavailable_count,
    unknown_count,
    last_live_observation_at,
    maximum_power_kw,
    operators,
    operator_charging_point_counts
  )
  WITH power_thresholds(minimum_power_kw) AS (
    VALUES (11), (22), (50), (100), (150), (200), (250), (300), (350), (400)
  ), eligible_point_memberships AS (
    SELECT campus.projection_id,
           campus.campus_id,
           threshold.minimum_power_kw,
           location.location_id,
           location.operator_name,
           location.coordinate AS location_coordinate,
           point.charging_point_id,
           point.maximum_power_kw,
           point.availability_state,
           point.availability_is_live,
           point.availability_observed_at,
           CASE
             WHEN point.canonical_evse_identity IS NULL
               THEN 'source:' || COALESCE(point.provider_id, 'legacy') || ':'
                 || point.charging_point_id::text
             WHEN EXISTS (
               SELECT 1
               FROM pg_temp.power_build_conflicts AS conflict
               WHERE conflict.projection_id = point.projection_id
                 AND conflict.canonical_evse_identity = point.canonical_evse_identity
                 AND conflict.resolution = 'kept_distinct'
             )
               THEN 'point:' || point.charging_point_id::text
             ELSE 'canonical:' || point.canonical_evse_identity
           END AS evse_key
    FROM pg_temp.power_build_campus_memberships AS campus
    JOIN pg_temp.power_build_park_memberships AS park
      ON park.projection_id = campus.projection_id
     AND park.park_id = campus.park_id
    JOIN pg_temp.power_build_locations AS location
      ON location.projection_id = park.projection_id
     AND location.location_id = park.location_id
    JOIN pg_temp.power_build_points AS point
      ON point.projection_id = location.projection_id
     AND point.location_id = location.location_id
    JOIN power_thresholds AS threshold
      ON point.maximum_power_kw >= threshold.minimum_power_kw
    WHERE campus.projection_id = target_projection_id
  ), eligible_evses AS (
    SELECT projection_id,
           campus_id,
           minimum_power_kw,
           evse_key,
           (array_agg(operator_name ORDER BY charging_point_id, operator_name))[1]
             AS operator_name,
           max(maximum_power_kw)::integer AS maximum_power_kw,
           CASE
             WHEN bool_and(availability_is_live)
               AND count(DISTINCT availability_state) = 1
               THEN min(availability_state)
             ELSE 'unknown'
           END AS availability_state,
           max(availability_observed_at) FILTER (
             WHERE availability_is_live AND availability_state <> 'unknown'
           ) AS availability_observed_at
    FROM eligible_point_memberships
    GROUP BY projection_id, campus_id, minimum_power_kw, evse_key
  ), eligible_aggregates AS (
    SELECT projection_id,
           campus_id,
           minimum_power_kw,
           count(*)::integer AS charging_point_count,
           count(*) FILTER (
             WHERE availability_state = 'available'
           )::integer AS known_available_count,
           count(*) FILTER (
             WHERE availability_state IN ('occupied', 'out_of_service', 'reserved')
           )::integer AS known_unavailable_count,
           count(*) FILTER (
             WHERE availability_state = 'unknown'
           )::integer AS unknown_count,
           max(availability_observed_at) AS last_live_observation_at,
           max(maximum_power_kw)::integer AS maximum_power_kw
    FROM eligible_evses
    GROUP BY projection_id, campus_id, minimum_power_kw
  ), operator_groups AS (
    SELECT projection_id,
           campus_id,
           minimum_power_kw,
           operator_name,
           count(*)::integer AS charging_point_count
    FROM eligible_evses
    GROUP BY projection_id, campus_id, minimum_power_kw, operator_name
  ), operator_aggregates AS (
    SELECT projection_id,
           campus_id,
           minimum_power_kw,
           array_agg(operator_name ORDER BY operator_name) AS operators,
           jsonb_agg(
             jsonb_build_object(
               'name', operator_name,
               'chargingPoints', charging_point_count
             )
             ORDER BY operator_name
           ) AS operator_charging_point_counts
    FROM operator_groups
    GROUP BY projection_id, campus_id, minimum_power_kw
  ), eligible_locations AS (
    SELECT DISTINCT projection_id,
           campus_id,
           minimum_power_kw,
           location_id,
           location_coordinate
    FROM eligible_point_memberships
  ), eligible_geometry AS (
    SELECT location.projection_id,
           location.campus_id,
           location.minimum_power_kw,
           ST_Centroid(ST_Collect(location.location_coordinate::geometry))::geography
             AS centroid,
           (array_agg(
             location.location_coordinate
             ORDER BY ST_Distance(
               location.location_coordinate,
               campus.navigation_coordinate
             ), location.location_id
           ))[1] AS navigation_coordinate
    FROM eligible_locations AS location
    JOIN pg_temp.power_build_candidates AS campus
      ON campus.projection_id = location.projection_id
     AND campus.campus_id = location.campus_id
    GROUP BY location.projection_id, location.campus_id, location.minimum_power_kw
  )
  SELECT aggregate.projection_id,
         aggregate.campus_id,
         aggregate.minimum_power_kw,
         geometry.centroid,
         geometry.navigation_coordinate,
         aggregate.charging_point_count,
         aggregate.known_available_count,
         aggregate.known_unavailable_count,
         aggregate.unknown_count,
         aggregate.last_live_observation_at,
         aggregate.maximum_power_kw,
         operator.operators,
         operator.operator_charging_point_counts
  FROM eligible_aggregates AS aggregate
  JOIN operator_aggregates AS operator
    USING (projection_id, campus_id, minimum_power_kw)
  JOIN eligible_geometry AS geometry
    USING (projection_id, campus_id, minimum_power_kw);
  DROP TABLE pg_temp.power_build_candidates,
             pg_temp.power_build_locations,
             pg_temp.power_build_points,
             pg_temp.power_build_conflicts,
             pg_temp.power_build_park_memberships,
             pg_temp.power_build_campus_memberships;
END;
$function$;

ALTER FUNCTION nextstop.rebuild_charging_park_power_projection(uuid)
  SET work_mem TO '128MB';
ALTER FUNCTION nextstop.rebuild_charging_campus_power_projection(uuid)
  SET work_mem TO '128MB';

-- A completed build must also become visible to plans on the read-only search
-- connection. Grant only this fixed list of ANALYZE operations to the worker;
-- it receives neither table ownership nor general maintenance/schema privileges.
CREATE FUNCTION nextstop.refresh_charging_projection_statistics()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  ANALYZE nextstop.normalized_charging_locations
    (projection_id, location_id, operator_name, coordinate);
  ANALYZE nextstop.normalized_charging_points
    (projection_id, charging_point_id, location_id, canonical_evse_identity,
     maximum_power_kw, provider_id, provider_evse_key);
  ANALYZE nextstop.projection_conflicts
    (projection_id, canonical_evse_identity, resolution);
  ANALYZE nextstop.charging_park_projection
    (projection_id, park_id, navigation_coordinate);
  ANALYZE nextstop.charging_campus_projection
    (projection_id, campus_id, navigation_coordinate);
  ANALYZE nextstop.charging_park_location_memberships;
  ANALYZE nextstop.charging_campus_park_memberships;
  ANALYZE nextstop.charging_park_power_projection
    (projection_id, park_id, minimum_power_kw, charging_point_count, navigation_coordinate);
  ANALYZE nextstop.charging_campus_power_projection
    (projection_id, campus_id, minimum_power_kw, charging_point_count, navigation_coordinate);
  ANALYZE nextstop.charging_park_food_poi_matches;
END;
$function$;

REVOKE ALL ON FUNCTION nextstop.refresh_charging_projection_statistics() FROM PUBLIC;

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0012_projection_build_statistics.sql');

COMMIT;
