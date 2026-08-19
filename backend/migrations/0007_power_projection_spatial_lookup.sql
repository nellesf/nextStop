BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE INDEX charging_park_power_projection_lookup_gist
  ON nextstop.charging_park_power_projection USING gist (
    projection_id,
    minimum_power_kw,
    navigation_coordinate
  );

DROP INDEX nextstop.charging_park_power_projection_coordinate_gist;

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0007_power_projection_spatial_lookup.sql');

COMMIT;
