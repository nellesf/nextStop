\set ON_ERROR_STOP on
-- Read-only verification; safe to run again as owner after a release.
DO $verify$
DECLARE
  role_attributes record;
BEGIN
  FOR role_attributes IN
    SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb,
           rolreplication, rolbypassrls
    FROM pg_roles
    WHERE rolname IN ('nextstop_api', 'nextstop_auth', 'nextstop_worker', 'nextstop_support', 'nextstop_backup')
  LOOP
    IF role_attributes.rolsuper
       OR role_attributes.rolinherit
       OR role_attributes.rolcreaterole
       OR role_attributes.rolcreatedb
       OR role_attributes.rolreplication
       OR role_attributes.rolbypassrls THEN
      RAISE EXCEPTION 'Unsafe runtime role attributes';
    END IF;
  END LOOP;

  -- No runtime can inherit or SET any other role. A bootstrap administrator
  -- may hold only ADMIN (not INHERIT/SET) on a runtime role for password rotation.
  IF EXISTS (
    SELECT 1 FROM pg_auth_members m
    WHERE m.member IN ('nextstop_app'::regrole,'nextstop_api'::regrole,'nextstop_auth'::regrole,'nextstop_worker'::regrole,'nextstop_support'::regrole,'nextstop_backup'::regrole)
       OR (m.roleid IN ('nextstop_api'::regrole,'nextstop_auth'::regrole,'nextstop_worker'::regrole,'nextstop_support'::regrole,'nextstop_backup'::regrole)
           AND (NOT m.admin_option OR m.inherit_option OR m.set_option
                OR NOT pg_has_role(m.member, 'cloudsqlsuperuser'::regrole, 'MEMBER')))
  ) THEN
    RAISE EXCEPTION 'Unsafe runtime role membership';
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
    'nextstop_support', 'nextstop.user_error_reports', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_table_privilege(
    'nextstop_api', 'nextstop.user_error_reports', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_table_privilege(
    'nextstop_auth', 'nextstop.user_error_reports', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_table_privilege(
    'nextstop_worker', 'nextstop.user_error_reports', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_table_privilege(
    'nextstop_support', 'nextstop.projection_versions', 'SELECT,INSERT,UPDATE,DELETE'
  ) OR has_schema_privilege('nextstop_support', 'nextstop', 'CREATE') THEN
    RAISE EXCEPTION 'nextstop_support grants do not match the error-report contract';
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
  IF NOT has_table_privilege('nextstop_backup','nextstop.app_attest_keys','SELECT')
     OR NOT has_table_privilege('nextstop_backup','nextstop.schema_migrations','SELECT')
     OR has_table_privilege('nextstop_backup','nextstop.user_error_reports','SELECT,INSERT,UPDATE,DELETE')
     OR has_schema_privilege('nextstop_backup','nextstop','CREATE')
     OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='nextstop' AND c.relkind='r'
                  AND has_table_privilege('nextstop_backup',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')) THEN
    RAISE EXCEPTION 'Backup role exceeds its report-excluding read-only contract';
  END IF;
END
$verify$;
