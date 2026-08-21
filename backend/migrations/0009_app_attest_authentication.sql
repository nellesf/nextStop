BEGIN;

CREATE TABLE nextstop.app_attest_keys (
  key_id_hash bytea PRIMARY KEY CHECK (octet_length(key_id_hash) = 32),
  public_key_pem text NOT NULL CHECK (length(public_key_pem) BETWEEN 64 AND 4096),
  receipt bytea NOT NULL CHECK (octet_length(receipt) BETWEEN 1 AND 131072),
  environment text NOT NULL CHECK (environment IN ('production', 'development')),
  sign_count bigint NOT NULL DEFAULT 0 CHECK (sign_count BETWEEN 0 AND 4294967295),
  validation_category integer,
  bundle_version text CHECK (bundle_version IS NULL OR length(bundle_version) BETWEEN 1 AND 64),
  attested_at timestamptz NOT NULL DEFAULT now(),
  last_asserted_at timestamptz,
  revoked_at timestamptz
);

CREATE TABLE nextstop.app_attest_challenges (
  challenge_id uuid PRIMARY KEY,
  key_id_hash bytea NOT NULL CHECK (octet_length(key_id_hash) = 32),
  purpose text NOT NULL CHECK (purpose IN ('attestation', 'assertion')),
  client_data bytea NOT NULL CHECK (octet_length(client_data) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > created_at),
  CHECK (expires_at <= created_at + interval '3 minutes')
);

CREATE INDEX app_attest_keys_retention
  ON nextstop.app_attest_keys ((COALESCE(last_asserted_at, attested_at)));

CREATE INDEX app_attest_challenges_expiry
  ON nextstop.app_attest_challenges (expires_at);

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0009_app_attest_authentication.sql');

COMMIT;
