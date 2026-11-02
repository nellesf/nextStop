BEGIN;

-- Each retired park triggers a foreign-key check, even after its food matches
-- have been pruned. Index the two referencing columns together so this check
-- can seek directly to a park across every food projection.
CREATE INDEX charging_park_food_matches_park_lookup
  ON nextstop.charging_park_food_poi_matches (charging_projection_id, park_id);

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0020_park_food_matches_parent_lookup.sql');

COMMIT;
