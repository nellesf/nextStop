BEGIN;

ALTER TABLE nextstop.projection_versions
  ADD COLUMN campus_count integer NOT NULL DEFAULT 0 CHECK (campus_count >= 0);

CREATE INDEX projection_conflicts_identity_lookup
  ON nextstop.projection_conflicts (
    projection_id,
    canonical_evse_identity
  )
  WHERE resolution = 'kept_distinct';

CREATE TABLE nextstop.charging_campus_projection (
  projection_id uuid NOT NULL REFERENCES nextstop.projection_versions(id) ON DELETE CASCADE,
  campus_id uuid NOT NULL,
  name text NOT NULL,
  centroid geography(Point, 4326) NOT NULL,
  navigation_coordinate geography(Point, 4326) NOT NULL,
  member_park_ids uuid[] NOT NULL CHECK (cardinality(member_park_ids) > 0),
  member_location_ids uuid[] NOT NULL CHECK (cardinality(member_location_ids) > 0),
  operators text[] NOT NULL CHECK (cardinality(operators) > 0),
  operator_charging_point_counts jsonb NOT NULL CHECK (
    jsonb_typeof(operator_charging_point_counts) = 'array'
    AND jsonb_array_length(operator_charging_point_counts) > 0
  ),
  charging_point_count integer NOT NULL CHECK (charging_point_count > 0),
  known_available_count integer NOT NULL CHECK (known_available_count >= 0),
  known_unavailable_count integer NOT NULL CHECK (known_unavailable_count >= 0),
  unknown_count integer NOT NULL CHECK (unknown_count >= 0),
  availability_complete boolean NOT NULL,
  last_live_observation_at timestamptz,
  maximum_power_kw integer NOT NULL CHECK (maximum_power_kw > 0),
  source_summaries jsonb NOT NULL,
  data_updated_at timestamptz NOT NULL,
  PRIMARY KEY (projection_id, campus_id),
  CHECK (
    known_available_count + known_unavailable_count + unknown_count = charging_point_count
  )
);

CREATE INDEX charging_campus_projection_filters
  ON nextstop.charging_campus_projection (
    projection_id,
    charging_point_count,
    maximum_power_kw
  );

CREATE TABLE nextstop.charging_campus_park_memberships (
  projection_id uuid NOT NULL,
  campus_id uuid NOT NULL,
  park_id uuid NOT NULL,
  PRIMARY KEY (projection_id, campus_id, park_id),
  FOREIGN KEY (projection_id, campus_id)
    REFERENCES nextstop.charging_campus_projection(projection_id, campus_id)
    ON DELETE CASCADE,
  FOREIGN KEY (projection_id, park_id)
    REFERENCES nextstop.charging_park_projection(projection_id, park_id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX charging_campus_park_memberships_one_campus_per_park
  ON nextstop.charging_campus_park_memberships (projection_id, park_id);

CREATE TABLE nextstop.charging_campus_power_projection (
  projection_id uuid NOT NULL,
  campus_id uuid NOT NULL,
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
  PRIMARY KEY (projection_id, campus_id, minimum_power_kw),
  FOREIGN KEY (projection_id, campus_id)
    REFERENCES nextstop.charging_campus_projection(projection_id, campus_id)
    ON DELETE CASCADE,
  CHECK (
    known_available_count + known_unavailable_count + unknown_count
      = charging_point_count
  )
);

CREATE INDEX charging_campus_power_projection_filters
  ON nextstop.charging_campus_power_projection (
    projection_id,
    minimum_power_kw,
    charging_point_count,
    campus_id
  );

CREATE INDEX charging_campus_power_projection_lookup_gist
  ON nextstop.charging_campus_power_projection USING gist (
    projection_id,
    minimum_power_kw,
    navigation_coordinate
  );

-- Keep existing published projections searchable during rollout. The importer
-- fingerprints the new projection policy and replaces these one-park fallback
-- campuses on its next static refresh.
INSERT INTO nextstop.charging_campus_projection (
  projection_id,
  campus_id,
  name,
  centroid,
  navigation_coordinate,
  member_park_ids,
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
)
SELECT park.projection_id,
       park.park_id,
       park.name,
       park.centroid,
       park.navigation_coordinate,
       ARRAY[park.park_id],
       park.member_location_ids,
       park.operators,
       park.operator_charging_point_counts,
       park.charging_point_count,
       park.known_available_count,
       park.known_unavailable_count,
       park.unknown_count,
       park.availability_complete,
       park.last_live_observation_at,
       park.maximum_power_kw,
       park.source_summaries,
       park.data_updated_at
FROM nextstop.charging_park_projection AS park;

UPDATE nextstop.projection_versions AS projection
SET campus_count = counts.campus_count
FROM (
  SELECT campus.projection_id, count(*)::integer AS campus_count
  FROM nextstop.charging_campus_projection AS campus
  GROUP BY campus.projection_id
) AS counts
WHERE counts.projection_id = projection.id;

CREATE OR REPLACE FUNCTION nextstop.rebuild_charging_park_power_projection(
  target_projection_id uuid
)
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

CREATE FUNCTION nextstop.rebuild_charging_campus_power_projection(
  target_projection_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
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
               FROM nextstop.projection_conflicts AS conflict
               WHERE conflict.projection_id = point.projection_id
                 AND conflict.canonical_evse_identity = point.canonical_evse_identity
                 AND conflict.resolution = 'kept_distinct'
             )
               THEN 'point:' || point.charging_point_id::text
             ELSE 'canonical:' || point.canonical_evse_identity
           END AS evse_key
    FROM nextstop.charging_campus_park_memberships AS campus
    JOIN nextstop.charging_park_location_memberships AS park
      ON park.projection_id = campus.projection_id
     AND park.park_id = campus.park_id
    JOIN nextstop.normalized_charging_locations AS location
      ON location.projection_id = park.projection_id
     AND location.location_id = park.location_id
    JOIN nextstop.normalized_charging_points AS point
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
    JOIN nextstop.charging_campus_projection AS campus
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
END;
$function$;

ALTER FUNCTION nextstop.rebuild_charging_park_power_projection(uuid)
  SET work_mem TO '128MB';

ALTER FUNCTION nextstop.rebuild_charging_campus_power_projection(uuid)
  SET work_mem TO '128MB';

SELECT nextstop.rebuild_charging_park_power_projection(id)
FROM nextstop.projection_versions
WHERE status IN ('building', 'active', 'retired');

SELECT nextstop.rebuild_charging_campus_power_projection(id)
FROM nextstop.projection_versions
WHERE status IN ('building', 'active', 'retired');

CREATE TEMPORARY TABLE retained_food_match_pairs
ON COMMIT DROP
AS
SELECT charging.id AS charging_projection_id,
       food.id AS food_projection_id
FROM nextstop.projection_versions AS charging
CROSS JOIN nextstop.food_poi_projection_versions AS food
WHERE charging.status IN ('active', 'retired')
  AND food.status IN ('active', 'retired');

DELETE FROM nextstop.charging_park_food_poi_matches;

INSERT INTO nextstop.charging_park_food_poi_matches (
  charging_projection_id,
  food_projection_id,
  park_id,
  osm_type,
  osm_id,
  broad_distance_meters
)
SELECT park.projection_id,
       food.projection_id,
       park.park_id,
       food.osm_type,
       food.osm_id,
       round(ST_Distance(park.navigation_coordinate, food.coordinate))::integer
FROM retained_food_match_pairs AS pair
JOIN nextstop.charging_park_projection AS park
  ON park.projection_id = pair.charging_projection_id
JOIN nextstop.food_poi_projection AS food
  ON food.projection_id = pair.food_projection_id
 AND ST_DWithin(park.navigation_coordinate, food.coordinate, 700);

ANALYZE nextstop.projection_conflicts;
ANALYZE nextstop.charging_park_location_memberships;
ANALYZE nextstop.charging_park_power_projection;
ANALYZE nextstop.charging_campus_projection;
ANALYZE nextstop.charging_campus_park_memberships;
ANALYZE nextstop.charging_campus_power_projection;
ANALYZE nextstop.charging_park_food_poi_matches;

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0008_conditional_charging_campus.sql');

COMMIT;
