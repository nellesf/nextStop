BEGIN;

CREATE TABLE nextstop.food_poi_projection_versions (
  id uuid PRIMARY KEY,
  source_dataset_hash text NOT NULL CHECK (source_dataset_hash ~ '^[0-9a-f]{64}$'),
  source_observed_at timestamptz NOT NULL,
  fetched_at timestamptz NOT NULL,
  built_at timestamptz NOT NULL,
  published_at timestamptz,
  status text NOT NULL CHECK (status IN ('building', 'active', 'retired', 'failed')),
  source_urls text[] NOT NULL CHECK (cardinality(source_urls) > 0),
  poi_count integer NOT NULL DEFAULT 0 CHECK (poi_count >= 0),
  quarantine_count integer NOT NULL DEFAULT 0 CHECK (quarantine_count >= 0),
  failure_code text,
  CHECK (status NOT IN ('active', 'retired') OR published_at IS NOT NULL)
);

CREATE UNIQUE INDEX one_active_food_poi_projection
  ON nextstop.food_poi_projection_versions ((status))
  WHERE status = 'active';

CREATE TABLE nextstop.food_poi_projection (
  projection_id uuid NOT NULL
    REFERENCES nextstop.food_poi_projection_versions(id) ON DELETE CASCADE,
  osm_type text NOT NULL CHECK (osm_type IN ('node', 'way', 'relation')),
  osm_id bigint NOT NULL CHECK (osm_id > 0),
  chain text NOT NULL CHECK (chain IN ('mcdonalds', 'burger_king', 'kfc', 'subway')),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  coordinate geography(Point, 4326) NOT NULL,
  opening_hours text,
  address jsonb NOT NULL,
  match_method text NOT NULL CHECK (match_method IN ('brand_wikidata', 'brand', 'name')),
  source_record_url text NOT NULL,
  source_observed_at timestamptz NOT NULL,
  fetched_at timestamptz NOT NULL,
  PRIMARY KEY (projection_id, osm_type, osm_id)
);

CREATE INDEX food_poi_projection_coordinate_gist
  ON nextstop.food_poi_projection USING gist (coordinate);

CREATE INDEX food_poi_projection_chain
  ON nextstop.food_poi_projection (projection_id, chain);

CREATE TABLE nextstop.food_poi_quarantine (
  projection_id uuid NOT NULL
    REFERENCES nextstop.food_poi_projection_versions(id) ON DELETE CASCADE,
  sequence_number integer NOT NULL CHECK (sequence_number > 0),
  osm_type text,
  osm_id bigint,
  issue_codes text[] NOT NULL CHECK (cardinality(issue_codes) > 0),
  PRIMARY KEY (projection_id, sequence_number)
);

CREATE TABLE nextstop.charging_park_food_poi_matches (
  charging_projection_id uuid NOT NULL,
  food_projection_id uuid NOT NULL,
  park_id uuid NOT NULL,
  osm_type text NOT NULL,
  osm_id bigint NOT NULL,
  broad_distance_meters integer NOT NULL CHECK (
    broad_distance_meters >= 0 AND broad_distance_meters <= 700
  ),
  PRIMARY KEY (
    charging_projection_id,
    food_projection_id,
    park_id,
    osm_type,
    osm_id
  ),
  FOREIGN KEY (charging_projection_id, park_id)
    REFERENCES nextstop.charging_park_projection(projection_id, park_id)
    ON DELETE CASCADE,
  FOREIGN KEY (food_projection_id, osm_type, osm_id)
    REFERENCES nextstop.food_poi_projection(projection_id, osm_type, osm_id)
    ON DELETE CASCADE
);

CREATE INDEX charging_park_food_matches_food_lookup
  ON nextstop.charging_park_food_poi_matches (
    charging_projection_id,
    food_projection_id,
    park_id
  );

CREATE INDEX charging_park_food_matches_poi_lookup
  ON nextstop.charging_park_food_poi_matches (
    food_projection_id,
    osm_type,
    osm_id
  );

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0004_osm_food_poi_projection.sql');

COMMIT;
