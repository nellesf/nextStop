\set ON_ERROR_STOP on
\set ECHO none
\getenv owner_password OWNER_DATABASE_PASSWORD
\getenv api_password API_DATABASE_PASSWORD
\getenv auth_password AUTH_DATABASE_PASSWORD
\getenv support_password SUPPORT_DATABASE_PASSWORD
\getenv worker_password WORKER_DATABASE_PASSWORD
\getenv backup_password BACKUP_DATABASE_PASSWORD

-- Run once/as needed as the Cloud SQL bootstrap administrator on database nextstop.
-- Runtime services never receive this administrator credential.
BEGIN;
SET LOCAL lock_timeout = '500ms';
SET LOCAL statement_timeout = '60s';
DO $guard$
BEGIN
  IF current_database() <> 'nextstop'
     OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
     OR NOT pg_has_role(current_user, 'cloudsqlsuperuser', 'MEMBER') THEN
    RAISE EXCEPTION 'Expected the non-superuser Cloud SQL bootstrap administrator on nextstop';
  END IF;
  IF current_setting('log_statement') <> 'none'
     OR current_setting('log_parameter_max_length_on_error') <> '0'
     OR current_setting('log_min_duration_statement') <> '-1'
     OR current_setting('log_min_duration_sample') <> '-1' THEN
    RAISE EXCEPTION 'Database logging must preserve the credential redaction contract';
  END IF;
END
$guard$;
SELECT length(:'owner_password') >= 32 AND length(:'api_password') >= 32
   AND length(:'auth_password') >= 32 AND length(:'support_password') >= 32
   AND length(:'worker_password') >= 32 AND length(:'backup_password') >= 32 AS passwords_valid \gset
\if :passwords_valid
\else
  ROLLBACK;
  DO $password_guard$ BEGIN
    RAISE EXCEPTION 'Database passwords must each contain at least 32 characters.';
  END $password_guard$;
\endif

-- Fresh roles start without elevated attributes. Refuse an unsafe existing role
-- rather than attempt SUPERUSER/REPLICATION alterations forbidden by Cloud SQL.
DO $roles$
DECLARE role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['nextstop_app','nextstop_api','nextstop_auth','nextstop_support','nextstop_worker','nextstop_backup'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
      PERFORM set_config('createrole_self_grant', CASE WHEN role_name='nextstop_app' THEN 'set' ELSE '' END, true);
      EXECUTE format('CREATE ROLE %I LOGIN NOINHERIT NOCREATEDB NOCREATEROLE', role_name);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name
       AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls OR rolinherit OR NOT rolcanlogin))
       OR EXISTS (SELECT 1 FROM pg_auth_members WHERE member = role_name::regrole) THEN
      RAISE EXCEPTION 'Existing role does not satisfy the restricted Cloud SQL contract';
    END IF;
    -- Vanilla PG17 automatically grants creator ADMIN; Cloud SQL suppresses
    -- that grant. Only add an explicit grant when none exists, because granting
    -- ADMIN back to one's own grantor fails on ordinary PostgreSQL 17.
    IF NOT EXISTS (SELECT 1 FROM pg_auth_members
         WHERE roleid=role_name::regrole AND member=current_user::regrole) THEN
      EXECUTE format('GRANT %I TO %I WITH ADMIN TRUE, INHERIT FALSE, SET %s',
        role_name, current_user, CASE WHEN role_name='nextstop_app' THEN 'TRUE' ELSE 'FALSE' END);
    END IF;
    -- PG17 can store the creator's automatic ADMIN and requested SET grants
    -- under different grantors. Verify their effective union, not one row.
    IF NOT COALESCE((SELECT bool_or(admin_option) AND NOT bool_or(inherit_option)
         AND bool_or(set_option)=(role_name='nextstop_app')
       FROM pg_auth_members WHERE roleid=role_name::regrole AND member=current_user::regrole), false) THEN
      RAISE EXCEPTION 'Bootstrap administrator lacks the exact restricted administration grant';
    END IF;
  END LOOP;
  PERFORM set_config('createrole_self_grant', '', true);
END
$roles$;

SELECT format('ALTER ROLE nextstop_app PASSWORD %L', :'owner_password') \gexec
SELECT format('ALTER ROLE nextstop_api PASSWORD %L', :'api_password') \gexec
SELECT format('ALTER ROLE nextstop_auth PASSWORD %L', :'auth_password') \gexec
SELECT format('ALTER ROLE nextstop_support PASSWORD %L', :'support_password') \gexec
SELECT format('ALTER ROLE nextstop_worker PASSWORD %L', :'worker_password') \gexec
SELECT format('ALTER ROLE nextstop_backup PASSWORD %L', :'backup_password') \gexec
ALTER ROLE nextstop_backup SET default_transaction_read_only = on;
ALTER ROLE nextstop_backup SET statement_timeout = '15min';
ALTER ROLE nextstop_backup SET lock_timeout = '500ms';
ALTER ROLE nextstop_backup SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE nextstop_app SET lock_timeout = '500ms';
ALTER ROLE nextstop_app SET statement_timeout = '5min';
ALTER ROLE nextstop_api
  NOCREATEDB NOCREATEROLE NOINHERIT;
ALTER ROLE nextstop_api SET default_transaction_read_only = on;
ALTER ROLE nextstop_api SET statement_timeout = '15s';
ALTER ROLE nextstop_api SET lock_timeout = '2s';
ALTER ROLE nextstop_api SET idle_in_transaction_session_timeout = '10s';

ALTER ROLE nextstop_auth
  NOCREATEDB NOCREATEROLE NOINHERIT;
ALTER ROLE nextstop_auth SET default_transaction_read_only = off;
ALTER ROLE nextstop_auth SET statement_timeout = '5s';
ALTER ROLE nextstop_auth SET lock_timeout = '2s';
ALTER ROLE nextstop_auth SET idle_in_transaction_session_timeout = '10s';

ALTER ROLE nextstop_worker
  NOCREATEDB NOCREATEROLE NOINHERIT;
ALTER ROLE nextstop_worker SET default_transaction_read_only = off;
ALTER ROLE nextstop_worker SET lock_timeout = '5s';
ALTER ROLE nextstop_worker SET statement_timeout = '5min';
ALTER ROLE nextstop_worker SET idle_in_transaction_session_timeout = '30s';

ALTER ROLE nextstop_support
  NOCREATEDB NOCREATEROLE NOINHERIT;
ALTER ROLE nextstop_support SET default_transaction_read_only = off;
ALTER ROLE nextstop_support SET statement_timeout = '5s';
ALTER ROLE nextstop_support SET lock_timeout = '2s';
ALTER ROLE nextstop_support SET idle_in_transaction_session_timeout = '10s';


DO $database_owner$
BEGIN
  IF (SELECT datdba FROM pg_database WHERE datname='nextstop') <> 'nextstop_app'::regrole THEN
    ALTER DATABASE nextstop OWNER TO nextstop_app;
  END IF;
END
$database_owner$;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gist;
SET LOCAL ROLE nextstop_app;
GRANT CONNECT ON DATABASE nextstop TO SESSION_USER;
CREATE SCHEMA IF NOT EXISTS nextstop AUTHORIZATION nextstop_app;
RESET ROLE;
COMMIT;
