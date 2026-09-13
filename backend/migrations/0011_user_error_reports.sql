BEGIN;

CREATE TABLE nextstop.user_error_reports (
  report_id uuid PRIMARY KEY,
  deletion_token_hash bytea NOT NULL CHECK (octet_length(deletion_token_hash) = 32),
  payload_hash bytea CHECK (octet_length(payload_hash) = 32),
  payload jsonb,
  payload_bytes integer NOT NULL CHECK (payload_bytes BETWEEN 0 AND 131072),
  received_at timestamptz,
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > received_at AND expires_at <= received_at + interval '720 hours'),
  CHECK ((payload IS NOT NULL AND payload_bytes > 0 AND received_at IS NOT NULL AND payload_hash IS NOT NULL)
      OR (payload IS NULL AND payload_bytes = 0 AND received_at IS NULL AND payload_hash IS NULL))
);
CREATE INDEX user_error_reports_retention ON nextstop.user_error_reports (expires_at);

INSERT INTO nextstop.schema_migrations (name) VALUES ('0011_user_error_reports.sql');
COMMIT;
