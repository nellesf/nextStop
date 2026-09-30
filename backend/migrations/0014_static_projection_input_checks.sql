BEGIN;

-- Existing projections retain their original source hash and provenance. A
-- nullable fingerprint requires a rebuild before an old projection can be reused
-- for a different raw snapshot. Exact raw-hash matches remain reusable as before.
ALTER TABLE nextstop.projection_versions
  ADD COLUMN input_content_hash text
    CHECK (input_content_hash IS NULL OR input_content_hash ~ '^[0-9a-f]{64}$');

-- A raw snapshot can differ only in transport/envelope information or ordering.
-- Record that validated equivalence separately; never rewrite the source hash of
-- the projection that was actually built from an earlier snapshot.
CREATE TABLE nextstop.static_projection_input_checks (
  source_dataset_hash text PRIMARY KEY CHECK (source_dataset_hash ~ '^[0-9a-f]{64}$'),
  projection_id uuid NOT NULL REFERENCES nextstop.projection_versions(id) ON DELETE CASCADE,
  checked_at timestamptz NOT NULL
);

CREATE INDEX static_projection_input_checks_projection
  ON nextstop.static_projection_input_checks (projection_id);

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0014_static_projection_input_checks.sql');

COMMIT;
