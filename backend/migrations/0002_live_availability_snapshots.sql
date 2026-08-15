BEGIN;

ALTER TABLE nextstop.normalized_charging_points
  ADD COLUMN provider_id text,
  ADD COLUMN provider_evse_key text;

ALTER TABLE nextstop.provider_quarantine
  ADD COLUMN provider_id text NOT NULL
    DEFAULT 'bundesnetzagentur_ladesaeulenregister';

ALTER TABLE nextstop.provider_quarantine
  DROP CONSTRAINT provider_quarantine_pkey,
  ADD PRIMARY KEY (projection_id, provider_id, row_number);

CREATE INDEX normalized_points_provider_evse_key
  ON nextstop.normalized_charging_points (projection_id, provider_id, provider_evse_key)
  WHERE provider_evse_key IS NOT NULL;

CREATE INDEX normalized_points_location
  ON nextstop.normalized_charging_points (projection_id, location_id);

CREATE TABLE nextstop.availability_snapshots (
  id uuid PRIMARY KEY,
  provider_id text NOT NULL,
  source_hash text NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
  observed_at timestamptz NOT NULL,
  fetched_at timestamptz NOT NULL,
  published_at timestamptz,
  status text NOT NULL CHECK (status IN ('building', 'active', 'retired', 'failed')),
  record_count integer NOT NULL DEFAULT 0 CHECK (record_count >= 0),
  quarantine_count integer NOT NULL DEFAULT 0 CHECK (quarantine_count >= 0),
  failure_code text,
  CHECK (status NOT IN ('active', 'retired') OR published_at IS NOT NULL)
);

CREATE UNIQUE INDEX one_active_availability_snapshot_per_provider
  ON nextstop.availability_snapshots (provider_id)
  WHERE status = 'active';

CREATE INDEX availability_snapshots_retention
  ON nextstop.availability_snapshots (provider_id, observed_at DESC)
  WHERE status IN ('active', 'retired');

CREATE TABLE nextstop.availability_observations (
  snapshot_id uuid NOT NULL REFERENCES nextstop.availability_snapshots(id) ON DELETE CASCADE,
  provider_id text NOT NULL,
  provider_evse_key text NOT NULL,
  native_identity text NOT NULL,
  availability_state text NOT NULL CHECK (
    availability_state IN ('available', 'occupied', 'out_of_service', 'reserved', 'unknown')
  ),
  observed_at timestamptz NOT NULL,
  source_reference jsonb NOT NULL,
  PRIMARY KEY (snapshot_id, provider_evse_key)
);

CREATE INDEX availability_observations_lookup
  ON nextstop.availability_observations (
    snapshot_id,
    provider_id,
    provider_evse_key
  );

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0002_live_availability_snapshots.sql');

COMMIT;
