BEGIN;

ALTER TABLE nextstop.charging_park_projection
  ADD COLUMN operator_charging_point_counts jsonb;

WITH deduplicated_memberships AS (
  SELECT DISTINCT ON (
           park.projection_id,
           park.park_id,
           COALESCE(
             point.canonical_evse_identity,
             COALESCE(point.provider_id, 'legacy') || ':' || point.charging_point_id::text
           )
         )
         park.projection_id,
         park.park_id,
         location.operator_name
  FROM nextstop.charging_park_projection AS park
  JOIN nextstop.normalized_charging_locations AS location
    ON location.projection_id = park.projection_id
   AND location.location_id = ANY(park.member_location_ids)
  JOIN nextstop.normalized_charging_points AS point
    ON point.projection_id = location.projection_id
   AND point.location_id = location.location_id
  ORDER BY park.projection_id,
           park.park_id,
           COALESCE(
             point.canonical_evse_identity,
             COALESCE(point.provider_id, 'legacy') || ':' || point.charging_point_id::text
           ),
           point.charging_point_id,
           location.operator_name
), operator_counts AS (
  SELECT projection_id,
         park_id,
         jsonb_agg(
           jsonb_build_object(
             'operatorName', operator_name,
             'chargingPointCount', charging_point_count
           )
           ORDER BY operator_name
         ) AS value
  FROM (
    SELECT projection_id,
           park_id,
           operator_name,
           count(*)::integer AS charging_point_count
    FROM deduplicated_memberships
    GROUP BY projection_id, park_id, operator_name
  ) AS grouped
  GROUP BY projection_id, park_id
)
UPDATE nextstop.charging_park_projection AS park
SET operator_charging_point_counts = operator_counts.value
FROM operator_counts
WHERE operator_counts.projection_id = park.projection_id
  AND operator_counts.park_id = park.park_id;

ALTER TABLE nextstop.charging_park_projection
  ALTER COLUMN operator_charging_point_counts SET NOT NULL,
  ADD CONSTRAINT operator_charging_point_counts_array
    CHECK (jsonb_typeof(operator_charging_point_counts) = 'array'),
  ADD CONSTRAINT operator_charging_point_counts_not_empty
    CHECK (jsonb_array_length(operator_charging_point_counts) > 0);

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0003_operator_charging_point_counts.sql');

COMMIT;
