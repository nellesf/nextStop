BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS nextstop;

CREATE TABLE nextstop.projection_versions (
  id uuid PRIMARY KEY,
  source_dataset_hash text NOT NULL CHECK (source_dataset_hash ~ '^[0-9a-f]{64}$'),
  source_observed_at timestamptz NOT NULL,
  built_at timestamptz NOT NULL,
  published_at timestamptz,
  status text NOT NULL CHECK (status IN ('building', 'active', 'retired', 'failed')),
  coverage_status text NOT NULL CHECK (coverage_status IN ('complete', 'degraded', 'stale')),
  active_sources text[] NOT NULL,
  unavailable_sources text[] NOT NULL,
  location_count integer NOT NULL DEFAULT 0 CHECK (location_count >= 0),
  charging_point_count integer NOT NULL DEFAULT 0 CHECK (charging_point_count >= 0),
  park_count integer NOT NULL DEFAULT 0 CHECK (park_count >= 0),
  quarantine_count integer NOT NULL DEFAULT 0 CHECK (quarantine_count >= 0),
  conflict_count integer NOT NULL DEFAULT 0 CHECK (conflict_count >= 0),
  failure_code text,
  CHECK (status NOT IN ('active', 'retired') OR published_at IS NOT NULL)
);

CREATE UNIQUE INDEX one_active_projection
  ON nextstop.projection_versions ((status))
  WHERE status = 'active';

CREATE TABLE nextstop.provider_records (
  provider_id text NOT NULL,
  source_record_id text NOT NULL,
  content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
  observed_at timestamptz NOT NULL,
  fetched_at timestamptz NOT NULL,
  raw_payload jsonb NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider_id, source_record_id, content_hash)
);

CREATE INDEX provider_records_observed_at
  ON nextstop.provider_records (provider_id, observed_at DESC);

CREATE TABLE nextstop.provider_quarantine (
  projection_id uuid NOT NULL REFERENCES nextstop.projection_versions(id) ON DELETE CASCADE,
  row_number integer NOT NULL CHECK (row_number > 0),
  source_record_id text,
  issue_codes text[] NOT NULL CHECK (cardinality(issue_codes) > 0),
  raw_payload jsonb NOT NULL,
  PRIMARY KEY (projection_id, row_number)
);

CREATE TABLE nextstop.projection_conflicts (
  projection_id uuid NOT NULL REFERENCES nextstop.projection_versions(id) ON DELETE CASCADE,
  conflict_id uuid NOT NULL,
  conflict_type text NOT NULL CHECK (conflict_type = 'evse_coordinate_disagreement'),
  canonical_evse_identity text NOT NULL,
  location_ids uuid[] NOT NULL CHECK (cardinality(location_ids) > 1),
  charging_point_ids uuid[] NOT NULL CHECK (cardinality(charging_point_ids) > 1),
  maximum_distance_meters integer NOT NULL CHECK (maximum_distance_meters > 200),
  resolution text NOT NULL CHECK (resolution = 'kept_distinct'),
  PRIMARY KEY (projection_id, conflict_id)
);

CREATE TABLE nextstop.normalized_charging_locations (
  projection_id uuid NOT NULL REFERENCES nextstop.projection_versions(id) ON DELETE CASCADE,
  location_id uuid NOT NULL,
  name text NOT NULL,
  operator_name text NOT NULL,
  coordinate geography(Point, 4326) NOT NULL,
  address jsonb NOT NULL,
  active boolean NOT NULL,
  source_reference jsonb NOT NULL,
  PRIMARY KEY (projection_id, location_id)
);

CREATE INDEX normalized_locations_coordinate_gist
  ON nextstop.normalized_charging_locations USING gist (coordinate);

CREATE TABLE nextstop.normalized_charging_points (
  projection_id uuid NOT NULL,
  charging_point_id uuid NOT NULL,
  location_id uuid NOT NULL,
  native_identity text,
  canonical_evse_identity text,
  identity_decision text NOT NULL CHECK (identity_decision IN ('exact', 'unresolved')),
  connectors jsonb NOT NULL,
  maximum_power_kw integer NOT NULL CHECK (maximum_power_kw > 0),
  availability_state text NOT NULL CHECK (
    availability_state IN ('available', 'occupied', 'out_of_service', 'reserved', 'unknown')
  ),
  availability_is_live boolean NOT NULL,
  availability_observed_at timestamptz,
  source_reference jsonb NOT NULL,
  PRIMARY KEY (projection_id, charging_point_id),
  FOREIGN KEY (projection_id, location_id)
    REFERENCES nextstop.normalized_charging_locations(projection_id, location_id)
    ON DELETE CASCADE
);

CREATE INDEX normalized_points_canonical_identity
  ON nextstop.normalized_charging_points (canonical_evse_identity)
  WHERE canonical_evse_identity IS NOT NULL;

CREATE TABLE nextstop.charging_park_projection (
  projection_id uuid NOT NULL REFERENCES nextstop.projection_versions(id) ON DELETE CASCADE,
  park_id uuid NOT NULL,
  name text NOT NULL,
  centroid geography(Point, 4326) NOT NULL,
  navigation_coordinate geography(Point, 4326) NOT NULL,
  member_location_ids uuid[] NOT NULL CHECK (cardinality(member_location_ids) > 0),
  operators text[] NOT NULL CHECK (cardinality(operators) > 0),
  charging_point_count integer NOT NULL CHECK (charging_point_count > 0),
  known_available_count integer NOT NULL CHECK (known_available_count >= 0),
  known_unavailable_count integer NOT NULL CHECK (known_unavailable_count >= 0),
  unknown_count integer NOT NULL CHECK (unknown_count >= 0),
  availability_complete boolean NOT NULL,
  last_live_observation_at timestamptz,
  maximum_power_kw integer NOT NULL CHECK (maximum_power_kw > 0),
  source_summaries jsonb NOT NULL,
  data_updated_at timestamptz NOT NULL,
  PRIMARY KEY (projection_id, park_id),
  CHECK (
    known_available_count + known_unavailable_count + unknown_count = charging_point_count
  )
);

CREATE INDEX charging_park_projection_coordinate_gist
  ON nextstop.charging_park_projection USING gist (navigation_coordinate);

CREATE INDEX charging_park_projection_filters
  ON nextstop.charging_park_projection (
    projection_id,
    charging_point_count,
    maximum_power_kw
  );

CREATE TABLE nextstop.schema_migrations (
  name text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO nextstop.schema_migrations (name) VALUES ('0001_initial_postgis_projection.sql');

COMMIT;
