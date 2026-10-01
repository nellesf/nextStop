BEGIN;

-- Runtime roles can verify a release's schema contract without reading or
-- modifying the migration registry. No identifiers or SQL come from callers.
CREATE FUNCTION nextstop.required_migrations_applied(required_names text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT required_names IS NOT NULL
    AND cardinality(required_names) BETWEEN 1 AND 256
    AND NOT EXISTS (
      SELECT 1 FROM unnest(required_names) AS required(name)
      WHERE required.name IS NULL OR NOT EXISTS (
        SELECT 1 FROM nextstop.schema_migrations AS applied
        WHERE applied.name = required.name
      )
    );
$function$;

REVOKE ALL ON FUNCTION nextstop.required_migrations_applied(text[]) FROM PUBLIC;

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0015_runtime_readiness.sql');

COMMIT;
