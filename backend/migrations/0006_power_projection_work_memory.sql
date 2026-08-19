BEGIN;

ALTER FUNCTION nextstop.rebuild_charging_park_power_projection(uuid)
  SET work_mem TO '128MB';

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0006_power_projection_work_memory.sql');

COMMIT;
