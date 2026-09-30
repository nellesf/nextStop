BEGIN;

-- Retention applies only to derived search rows. Version metadata, normalized
-- observations, provider records, quarantines, and identity conflicts stay intact.
ALTER TABLE nextstop.projection_versions
  ADD COLUMN retired_at timestamptz,
  ADD COLUMN search_pruned_at timestamptz,
  ADD COLUMN search_prune_completed_at timestamptz,
  ADD COLUMN search_prune_stage integer NOT NULL DEFAULT 0
    CHECK (search_prune_stage BETWEEN 0 AND 7),
  ADD CONSTRAINT pruned_projection_cannot_be_active
    CHECK (search_pruned_at IS NULL OR status IN ('retired', 'failed'));

-- The original retirement instant is unknown. Start the full grace period at
-- migration time instead of mistaking an old publication date for retirement.
UPDATE nextstop.projection_versions
SET retired_at = CURRENT_TIMESTAMP
WHERE status = 'retired';

CREATE FUNCTION nextstop.record_projection_retirement()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status = 'retired' AND OLD.status <> 'retired' THEN
    NEW.retired_at := clock_timestamp();
  ELSIF NEW.status = 'active' THEN
    NEW.retired_at := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER projection_retirement_timestamp
BEFORE UPDATE OF status ON nextstop.projection_versions
FOR EACH ROW EXECUTE FUNCTION nextstop.record_projection_retirement();

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0013_search_projection_retention.sql');

COMMIT;
