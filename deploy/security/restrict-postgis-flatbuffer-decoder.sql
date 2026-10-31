-- Run as the PostGIS owner. These two entry points accept untrusted binary data.
BEGIN;
SET LOCAL search_path = pg_catalog;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $harden$
DECLARE
  row_decoder regprocedure := 'public.st_fromflatgeobuf(anyelement,bytea)'::regprocedure;
  header_decoder regprocedure := 'public.st_fromflatgeobuftotable(text,text,bytea)'::regprocedure;
  matched integer;
  app_role name;
  required_roles name[] := ARRAY['nextstop_api','nextstop_auth','nextstop_support','nextstop_worker'];
BEGIN
  IF current_database() NOT IN ('nextstop','template_postgis')
     OR current_setting('server_version_num')::int / 10000 <> 17 THEN
    RAISE EXCEPTION 'Unexpected database or engine';
  END IF;
  IF NOT (
    (current_user = 'nextstop_app' AND (SELECT rolsuper FROM pg_roles WHERE rolname = current_user))
    OR (current_user = 'postgres' AND EXISTS (
      SELECT FROM pg_roles WHERE rolname = 'cloudsqlsuperuser' AND pg_has_role(current_user,oid,'MEMBER')
    ))
  ) THEN
    RAISE EXCEPTION 'The verified installation owner is required';
  END IF;
  SELECT count(*) INTO matched
    FROM pg_proc p
    JOIN pg_roles owner ON owner.oid = p.proowner
    JOIN pg_language l ON l.oid = p.prolang
    JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
    JOIN pg_extension e ON d.refclassid = 'pg_extension'::regclass AND e.oid = d.refobjid
    WHERE owner.rolname = current_user AND p.pronamespace = 'public'::regnamespace
      AND p.prokind = 'f' AND l.lanname = 'c'
      AND (p.probin = '$libdir/postgis-3' OR (owner.rolname = 'postgres'
        AND p.probin = '$libdir/postgis-' || substring(e.extversion FROM '^[0-9]+[.][0-9]+') || '/postgis-3'))
      AND ((p.oid = row_decoder AND p.prosrc = 'pgis_fromflatgeobuf' AND p.proretset
            AND p.prorettype = 'anyelement'::regtype)
        OR (p.oid = header_decoder AND p.prosrc = 'pgis_tablefromflatgeobuf' AND NOT p.proretset
            AND p.prorettype = 'void'::regtype))
      AND e.extname = 'postgis' AND e.extnamespace = p.pronamespace AND e.extowner = p.proowner;
  IF matched <> 2 OR (SELECT count(*) FROM pg_roles WHERE rolname = ANY(required_roles) AND rolcanlogin) <> 4 THEN
    RAISE EXCEPTION 'Unexpected decoder installation or runtime role inventory';
  END IF;

  REVOKE EXECUTE ON FUNCTION public.st_fromflatgeobuf(anyelement,bytea),
    public.st_fromflatgeobuftotable(text,text,bytea) FROM PUBLIC;
  FOR app_role IN SELECT rolname FROM pg_roles
    WHERE rolname = ANY(required_roles || ARRAY['nextstop_backup','nextstop_app']::name[])
      AND rolname <> current_user
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s, %s FROM %I', row_decoder, header_decoder, app_role);
    IF EXISTS (SELECT FROM pg_roles target WHERE pg_has_role(app_role,target.oid,'SET')
               AND (has_function_privilege(target.oid,row_decoder,'EXECUTE')
                 OR has_function_privilege(target.oid,header_decoder,'EXECUTE'))) THEN
      RAISE EXCEPTION 'Runtime role still has a route to a decoder';
    END IF;
  END LOOP;
END
$harden$;
COMMIT;
