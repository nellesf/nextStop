BEGIN;

CREATE TABLE nextstop.charging_park_location_memberships (
  projection_id uuid NOT NULL,
  park_id uuid NOT NULL,
  location_id uuid NOT NULL,
  PRIMARY KEY (projection_id, park_id, location_id),
  FOREIGN KEY (projection_id, park_id)
    REFERENCES nextstop.charging_park_projection(projection_id, park_id)
    ON DELETE CASCADE,
  FOREIGN KEY (projection_id, location_id)
    REFERENCES nextstop.normalized_charging_locations(projection_id, location_id)
    ON DELETE CASCADE
);

CREATE INDEX charging_park_location_memberships_location
  ON nextstop.charging_park_location_memberships (projection_id, location_id, park_id);

CREATE TABLE nextstop.charging_park_power_projection (
  projection_id uuid NOT NULL,
  park_id uuid NOT NULL,
  minimum_power_kw integer NOT NULL CHECK (
    minimum_power_kw IN (11, 22, 50, 100, 150, 200, 250, 300, 350, 400)
  ),
  centroid geography(Point, 4326) NOT NULL,
  navigation_coordinate geography(Point, 4326) NOT NULL,
  charging_point_count integer NOT NULL CHECK (charging_point_count > 0),
  known_available_count integer NOT NULL CHECK (known_available_count >= 0),
  known_unavailable_count integer NOT NULL CHECK (known_unavailable_count >= 0),
  unknown_count integer NOT NULL CHECK (unknown_count >= 0),
  last_live_observation_at timestamptz,
  maximum_power_kw integer NOT NULL CHECK (maximum_power_kw >= minimum_power_kw),
  operators text[] NOT NULL CHECK (cardinality(operators) > 0),
  operator_charging_point_counts jsonb NOT NULL CHECK (
    jsonb_typeof(operator_charging_point_counts) = 'array'
    AND jsonb_array_length(operator_charging_point_counts) > 0
  ),
  PRIMARY KEY (projection_id, park_id, minimum_power_kw),
  FOREIGN KEY (projection_id, park_id)
    REFERENCES nextstop.charging_park_projection(projection_id, park_id)
    ON DELETE CASCADE,
  CHECK (
    known_available_count + known_unavailable_count + unknown_count
      = charging_point_count
  )
);

CREATE INDEX charging_park_power_projection_filters
  ON nextstop.charging_park_power_projection (
    projection_id,
    minimum_power_kw,
    charging_point_count,
    park_id
  );

CREATE INDEX charging_park_power_projection_coordinate_gist
  ON nextstop.charging_park_power_projection USING gist (navigation_coordinate);

CREATE FUNCTION nextstop.rebuild_charging_park_power_projection(target_projection_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
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
           COALESCE(
             point.canonical_evse_identity,
             COALESCE(point.provider_id, 'legacy') || ':' || point.charging_point_id::text
           ) AS evse_key
    FROM nextstop.charging_park_location_memberships AS membership
    JOIN nextstop.normalized_charging_locations AS location
      ON location.projection_id = membership.projection_id
     AND location.location_id = membership.location_id
    JOIN nextstop.normalized_charging_points AS point
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
    JOIN nextstop.charging_park_projection AS park
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
END;
$function$;

SELECT nextstop.rebuild_charging_park_power_projection(id)
FROM nextstop.projection_versions
WHERE status IN ('building', 'active', 'retired');

ANALYZE nextstop.charging_park_location_memberships;
ANALYZE nextstop.charging_park_power_projection;

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0005_power_search_projection.sql');

COMMIT;
