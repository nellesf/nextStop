BEGIN;

-- Both publishers rebuild these matches inside their publication transaction.
-- Refresh only the affected food tables before the new pair becomes searchable.
-- The worker receives this fixed operation, never general MAINTAIN privileges.
CREATE FUNCTION nextstop.refresh_food_projection_statistics()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  ANALYZE nextstop.food_poi_projection;
  ANALYZE nextstop.charging_park_food_poi_matches;
END;
$function$;

REVOKE ALL ON FUNCTION nextstop.refresh_food_projection_statistics() FROM PUBLIC;

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0019_food_projection_statistics.sql');

COMMIT;
