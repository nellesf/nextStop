BEGIN;

ALTER TABLE nextstop.projection_conflicts
  DROP CONSTRAINT projection_conflicts_resolution_check;

ALTER TABLE nextstop.projection_conflicts
  ADD CONSTRAINT projection_conflicts_resolution_check
  CHECK (resolution IN ('kept_distinct', 'audit_only'));

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0010_audit_only_projection_conflicts.sql');

COMMIT;
