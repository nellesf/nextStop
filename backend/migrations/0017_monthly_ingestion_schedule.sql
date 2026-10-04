BEGIN;

-- Durable due dates survive worker restarts and unchanged source downloads.
-- This contains only maintenance identifiers, never requests or user data.
CREATE TABLE nextstop.monthly_ingestion_schedule (
  job text PRIMARY KEY CHECK (job IN ('charging-static', 'food-pois')),
  next_due_at timestamptz NOT NULL,
  attempt_id uuid,
  last_attempt_at timestamptz,
  last_success_at timestamptz
);

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0017_monthly_ingestion_schedule.sql');

COMMIT;
