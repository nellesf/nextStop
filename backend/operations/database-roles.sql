\set ON_ERROR_STOP on
-- Run after restore/migration as nextstop_app, never a runtime role.
BEGIN;
SET LOCAL lock_timeout = '500ms';
SET LOCAL statement_timeout = '60s';
DO $owner$
BEGIN
  IF current_database() <> 'nextstop' OR current_user <> 'nextstop_app'
     OR (SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname=current_user)
     OR NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='nextstop' AND nspowner=current_user::regrole)
     OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='nextstop' AND c.relowner<>current_user::regrole) THEN
    RAISE EXCEPTION 'Expected restricted nextstop_app owner and owned restored objects';
  END IF;
END
$owner$;
REVOKE ALL ON DATABASE nextstop FROM PUBLIC;
GRANT CONNECT ON DATABASE nextstop TO nextstop_api, nextstop_auth, nextstop_worker, nextstop_support, nextstop_backup;
GRANT TEMPORARY ON DATABASE nextstop TO nextstop_worker;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA nextstop FROM PUBLIC;
GRANT USAGE ON SCHEMA nextstop TO nextstop_api, nextstop_auth, nextstop_worker, nextstop_support, nextstop_backup;

REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA nextstop FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA nextstop FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE nextstop_app IN SCHEMA nextstop
  REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE nextstop_app IN SCHEMA nextstop
  REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE nextstop_app IN SCHEMA nextstop
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM nextstop_api;
GRANT SELECT ON TABLE
  nextstop.projection_versions,
  nextstop.projection_conflicts,
  nextstop.normalized_charging_locations,
  nextstop.normalized_charging_points,
  nextstop.charging_park_projection,
  nextstop.availability_snapshots,
  nextstop.availability_observations,
  nextstop.food_poi_projection_versions,
  nextstop.food_poi_projection,
  nextstop.charging_park_food_poi_matches,
  nextstop.charging_park_location_memberships,
  nextstop.charging_park_power_projection,
  nextstop.charging_campus_projection,
  nextstop.charging_campus_park_memberships,
  nextstop.charging_campus_power_projection
TO nextstop_api;

REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM nextstop_auth;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  nextstop.app_attest_keys,
  nextstop.app_attest_challenges
TO nextstop_auth;

REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM nextstop_support;
GRANT SELECT, INSERT, UPDATE, DELETE ON nextstop.user_error_reports TO nextstop_support;

REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM nextstop_worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  nextstop.projection_versions,
  nextstop.provider_records,
  nextstop.static_projection_input_checks,
  nextstop.provider_quarantine,
  nextstop.projection_conflicts,
  nextstop.normalized_charging_locations,
  nextstop.normalized_charging_points,
  nextstop.charging_park_projection,
  nextstop.availability_snapshots,
  nextstop.availability_observations,
  nextstop.food_poi_projection_versions,
  nextstop.food_poi_projection,
  nextstop.food_poi_quarantine,
  nextstop.charging_park_food_poi_matches,
  nextstop.charging_park_location_memberships,
  nextstop.charging_park_power_projection,
  nextstop.charging_campus_projection,
  nextstop.charging_campus_park_memberships,
  nextstop.charging_campus_power_projection
TO nextstop_worker;

GRANT SELECT, INSERT, UPDATE ON TABLE
  nextstop.live_refresh_control,
  nextstop.monthly_ingestion_schedule,
  nextstop.monthly_import_budget
TO nextstop_worker;

GRANT EXECUTE ON FUNCTION nextstop.rebuild_charging_park_power_projection(uuid)
TO nextstop_worker;
GRANT EXECUTE ON FUNCTION nextstop.rebuild_charging_campus_power_projection(uuid)
TO nextstop_worker;
GRANT EXECUTE ON FUNCTION nextstop.refresh_charging_projection_statistics()
TO nextstop_worker;

GRANT EXECUTE ON FUNCTION nextstop.required_migrations_applied(text[])
TO nextstop_api, nextstop_auth;


REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM nextstop_backup;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA nextstop FROM nextstop_backup;
GRANT SELECT ON TABLE
  nextstop.projection_versions, nextstop.provider_records, nextstop.provider_quarantine,
  nextstop.projection_conflicts, nextstop.normalized_charging_locations, nextstop.normalized_charging_points,
  nextstop.charging_park_projection, nextstop.charging_park_location_memberships,
  nextstop.charging_park_power_projection, nextstop.charging_campus_projection,
  nextstop.charging_campus_park_memberships, nextstop.charging_campus_power_projection,
  nextstop.charging_park_food_poi_matches, nextstop.food_poi_projection_versions,
  nextstop.food_poi_projection, nextstop.food_poi_quarantine,
  nextstop.availability_snapshots, nextstop.availability_observations,
  nextstop.app_attest_keys, nextstop.app_attest_challenges, nextstop.schema_migrations,
  nextstop.static_projection_input_checks, nextstop.live_refresh_control,
  nextstop.monthly_ingestion_schedule, nextstop.monthly_import_budget
TO nextstop_backup;

\ir database-verify.sql
COMMIT;
