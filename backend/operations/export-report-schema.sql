\set ON_ERROR_STOP on
\set ECHO none
-- Invoke with psql -XqAt. Only catalog metadata is read, never report rows or
-- table locks requiring SELECT. Save stdout privately as report-schema.sql.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '500ms';
SET LOCAL search_path = pg_catalog;
DO $guard$
DECLARE relation oid := to_regclass('nextstop.user_error_reports');
BEGIN
  IF relation IS NULL OR NOT EXISTS (
    SELECT 1 FROM pg_class WHERE oid=relation AND relkind='r'
      AND relpersistence='p' AND NOT relispartition AND NOT relrowsecurity
      AND NOT relforcerowsecurity AND reloptions IS NULL AND relreplident='d'
  ) OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=relation OR inhparent=relation)
    OR EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid=a.atttypid
       WHERE a.attrelid=relation AND a.attnum>0 AND NOT a.attisdropped
         AND (a.attidentity<>'' OR a.attgenerated<>'' OR a.atthasdef
              OR t.typnamespace<>'pg_catalog'::regnamespace OR a.attcollation<>t.typcollation))
    OR EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid=relation AND contype NOT IN ('p','c'))
    OR EXISTS (SELECT 1 FROM pg_constraint WHERE confrelid=relation)
    OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=relation AND NOT tgisinternal)
    OR EXISTS (SELECT 1 FROM pg_rewrite WHERE ev_class=relation)
    OR EXISTS (SELECT 1 FROM pg_index WHERE indrelid=relation AND (NOT indisvalid OR NOT indisready)) THEN
    RAISE EXCEPTION 'Report schema has unreviewed features; backup supplement export refused';
  END IF;
END
$guard$;
SELECT '-- Report schema only; intentionally contains no report rows.';
SELECT 'CREATE TABLE nextstop.user_error_reports (' || E'\n' ||
  string_agg(format('  %I %s%s', attname, format_type(atttypid,atttypmod),
    CASE WHEN attnotnull THEN ' NOT NULL' ELSE '' END), E',\n' ORDER BY attnum)
  || E'\n);'
FROM pg_attribute WHERE attrelid='nextstop.user_error_reports'::regclass
  AND attnum>0 AND NOT attisdropped;
SELECT format('ALTER TABLE nextstop.user_error_reports ADD CONSTRAINT %I %s;',
  conname, pg_get_constraintdef(oid,false))
FROM pg_constraint WHERE conrelid='nextstop.user_error_reports'::regclass ORDER BY conname;
SELECT pg_get_indexdef(i.indexrelid) || ';'
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
WHERE i.indrelid='nextstop.user_error_reports'::regclass
  AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conindid=i.indexrelid)
ORDER BY c.relname;
ROLLBACK;
