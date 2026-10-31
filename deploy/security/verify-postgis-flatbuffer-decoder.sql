-- Fail closed using an ordinary database connection after restore or extension upgrade.
BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL statement_timeout = '10s';
DO $verify$
DECLARE
  inputs regprocedure[] := ARRAY['public.st_fromflatgeobuf(anyelement,bytea)'::regprocedure,
    'public.st_fromflatgeobuftotable(text,text,bytea)'::regprocedure];
  runtime_roles name[] := ARRAY['nextstop_api','nextstop_auth','nextstop_support','nextstop_worker'];
  owner_name name;
  role_name name;
BEGIN
  IF current_database() NOT IN ('nextstop','template_postgis')
      OR current_setting('server_version_num')::int / 10000 <> 17
      OR (SELECT count(*) FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid
          WHERE d.classid='pg_proc'::regclass AND d.refclassid='pg_extension'::regclass
            AND d.deptype='e' AND d.objid=ANY(inputs) AND e.extname='postgis') <> 2 THEN
    RAISE EXCEPTION 'Unexpected PostGIS database or input functions';
  END IF;
  SELECT pg_get_userbyid(extowner) INTO STRICT owner_name FROM pg_extension
    WHERE extname = 'postgis' AND extnamespace = 'public'::regnamespace;
  IF owner_name = 'postgres' THEN
    runtime_roles := runtime_roles || ARRAY['nextstop_app','nextstop_backup']::name[];
  ELSIF owner_name = 'nextstop_app' AND (SELECT rolsuper FROM pg_roles WHERE rolname = owner_name) THEN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname='nextstop_backup') THEN
      runtime_roles := array_append(runtime_roles,'nextstop_backup'::name);
    END IF;
  ELSE
    RAISE EXCEPTION 'Unexpected PostGIS owner';
  END IF;
  FOREACH role_name IN ARRAY runtime_roles LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname=role_name AND rolcanlogin)
       OR EXISTS (SELECT FROM unnest(inputs) fn CROSS JOIN pg_roles target
         WHERE pg_has_role(role_name,target.oid,'SET') AND has_function_privilege(target.oid,fn,'EXECUTE')) THEN
      RAISE EXCEPTION 'Runtime decoder ACL verification failed for %', role_name;
    END IF;
  END LOOP;
END
$verify$;
COMMIT;
