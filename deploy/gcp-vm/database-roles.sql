\set ON_ERROR_STOP on

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nextstop_api') THEN
    CREATE ROLE nextstop_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nextstop_auth') THEN
    CREATE ROLE nextstop_auth LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nextstop_worker') THEN
    CREATE ROLE nextstop_worker LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END
$roles$;

DO $memberships$
DECLARE
  membership record;
BEGIN
  FOR membership IN
    SELECT DISTINCT granted.rolname AS granted_role, member.rolname AS member_role
    FROM pg_auth_members AS membership_link
    JOIN pg_roles AS granted ON granted.oid = membership_link.roleid
    JOIN pg_roles AS member ON member.oid = membership_link.member
    WHERE member.rolname IN ('nextstop_api', 'nextstop_auth', 'nextstop_worker')
       OR granted.rolname IN ('nextstop_api', 'nextstop_auth', 'nextstop_worker')
  LOOP
    EXECUTE format(
      'REVOKE %I FROM %I',
      membership.granted_role,
      membership.member_role
    );
  END LOOP;
END
$memberships$;

SELECT format('ALTER ROLE nextstop_api PASSWORD %L', :'api_password') \gexec
SELECT format('ALTER ROLE nextstop_auth PASSWORD %L', :'auth_password') \gexec
SELECT format('ALTER ROLE nextstop_worker PASSWORD %L', :'worker_password') \gexec

ALTER ROLE nextstop_api
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE nextstop_api SET default_transaction_read_only = on;
ALTER ROLE nextstop_api SET statement_timeout = '15s';
ALTER ROLE nextstop_api SET lock_timeout = '2s';
ALTER ROLE nextstop_api SET idle_in_transaction_session_timeout = '10s';

ALTER ROLE nextstop_auth
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE nextstop_auth SET default_transaction_read_only = off;
ALTER ROLE nextstop_auth SET statement_timeout = '5s';
ALTER ROLE nextstop_auth SET lock_timeout = '2s';
ALTER ROLE nextstop_auth SET idle_in_transaction_session_timeout = '10s';

ALTER ROLE nextstop_worker
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE nextstop_worker SET default_transaction_read_only = off;
ALTER ROLE nextstop_worker SET lock_timeout = '5s';
ALTER ROLE nextstop_worker SET idle_in_transaction_session_timeout = '30s';

REVOKE ALL ON DATABASE nextstop FROM PUBLIC;
GRANT CONNECT ON DATABASE nextstop TO nextstop_api, nextstop_auth, nextstop_worker;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA nextstop FROM PUBLIC;
GRANT USAGE ON SCHEMA nextstop TO nextstop_api, nextstop_auth, nextstop_worker;

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

REVOKE ALL ON ALL TABLES IN SCHEMA nextstop FROM nextstop_worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  nextstop.projection_versions,
  nextstop.provider_records,
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

GRANT EXECUTE ON FUNCTION nextstop.rebuild_charging_park_power_projection(uuid)
TO nextstop_worker;
GRANT EXECUTE ON FUNCTION nextstop.rebuild_charging_campus_power_projection(uuid)
TO nextstop_worker;

DO $verify$
DECLARE
  role_attributes record;
BEGIN
  FOR role_attributes IN
    SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb,
           rolreplication, rolbypassrls
    FROM pg_roles
    WHERE rolname IN ('nextstop_api', 'nextstop_auth', 'nextstop_worker')
  LOOP
    IF role_attributes.rolsuper
       OR role_attributes.rolinherit
       OR role_attributes.rolcreaterole
       OR role_attributes.rolcreatedb
       OR role_attributes.rolreplication
       OR role_attributes.rolbypassrls THEN
      RAISE EXCEPTION 'Unsafe attributes remain on role %', role_attributes.rolname;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM pg_auth_members AS membership_link
    JOIN pg_roles AS granted ON granted.oid = membership_link.roleid
    JOIN pg_roles AS member ON member.oid = membership_link.member
    WHERE member.rolname IN ('nextstop_api', 'nextstop_auth', 'nextstop_worker')
       OR granted.rolname IN ('nextstop_api', 'nextstop_auth', 'nextstop_worker')
  ) THEN
    RAISE EXCEPTION 'Runtime database roles still have an inherited or assumable membership';
  END IF;

  IF NOT has_table_privilege(
    'nextstop_auth', 'nextstop.app_attest_keys', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR NOT has_table_privilege(
    'nextstop_auth', 'nextstop.app_attest_challenges', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_table_privilege(
    'nextstop_auth', 'nextstop.projection_versions', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_schema_privilege('nextstop_auth', 'nextstop', 'CREATE') THEN
    RAISE EXCEPTION 'nextstop_auth grants do not match the authentication contract';
  END IF;

  IF NOT has_table_privilege(
    'nextstop_api', 'nextstop.projection_versions', 'SELECT'
  ) OR has_table_privilege(
    'nextstop_api', 'nextstop.provider_records', 'SELECT'
  ) OR has_table_privilege(
    'nextstop_api', 'nextstop.projection_versions', 'INSERT,UPDATE,DELETE'
  ) OR has_schema_privilege('nextstop_api', 'nextstop', 'CREATE') THEN
    RAISE EXCEPTION 'nextstop_api grants do not match the read-only contract';
  END IF;

  IF NOT has_table_privilege(
    'nextstop_worker', 'nextstop.provider_records', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_table_privilege(
    'nextstop_worker', 'nextstop.schema_migrations', 'SELECT'
  ) OR has_schema_privilege('nextstop_worker', 'nextstop', 'CREATE')
     OR NOT has_function_privilege(
       'nextstop_worker',
       'nextstop.rebuild_charging_park_power_projection(uuid)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'nextstop_worker',
       'nextstop.rebuild_charging_campus_power_projection(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'nextstop_worker grants do not match the ingestion contract';
  END IF;
END
$verify$;
