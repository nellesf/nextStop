BEGIN;

-- One provider-wide lease and cooldown. No request, route, candidate or user data.
CREATE TABLE nextstop.live_refresh_control (
  provider_id text PRIMARY KEY CHECK (provider_id = 'ich_tanke_strom'),
  lease_owner uuid,
  lease_until timestamptz,
  next_allowed_at timestamptz NOT NULL,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  CHECK ((lease_owner IS NULL) = (lease_until IS NULL))
);

INSERT INTO nextstop.schema_migrations (name) VALUES ('0016_demand_live_refresh.sql');
COMMIT;
