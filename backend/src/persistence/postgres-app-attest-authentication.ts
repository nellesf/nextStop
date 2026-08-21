import type { Pool } from "pg";

import type {
  AppAttestAuthenticationRepository,
  AttestedKey,
} from "../application/app-attest-authentication.js";

export class PostgresAppAttestAuthenticationRepository
  implements AppAttestAuthenticationRepository
{
  constructor(private readonly pool: Pool) {}

  async deleteExpiredChallenges(now: Date, maximumRows: number): Promise<number> {
    const result = await this.pool.query(
      `WITH expired AS (
         SELECT challenge_id
         FROM nextstop.app_attest_challenges
         WHERE expires_at <= $1
         ORDER BY expires_at
         LIMIT $2
       )
       DELETE FROM nextstop.app_attest_challenges AS challenge
       USING expired
       WHERE challenge.challenge_id = expired.challenge_id`,
      [now, maximumRows],
    );
    return result.rowCount ?? 0;
  }

  async deleteStaleKeys(
    now: Date,
    maximumRows: number,
    excludedKeyIdHash: Buffer,
  ): Promise<number> {
    const result = await this.pool.query(
      `WITH stale AS (
         SELECT key.key_id_hash
         FROM nextstop.app_attest_keys AS key
         WHERE COALESCE(key.last_asserted_at, key.attested_at)
           <= $1::timestamptz - interval '90 days'
           AND key.key_id_hash <> $3
           AND NOT EXISTS (
             SELECT 1
             FROM nextstop.app_attest_challenges AS challenge
             WHERE challenge.key_id_hash = key.key_id_hash
               AND challenge.expires_at > $1
           )
         ORDER BY COALESCE(key.last_asserted_at, key.attested_at)
         LIMIT $2
       )
       DELETE FROM nextstop.app_attest_keys AS key
       USING stale
       WHERE key.key_id_hash = stale.key_id_hash
         AND key.key_id_hash <> $3
         AND COALESCE(key.last_asserted_at, key.attested_at)
           <= $1::timestamptz - interval '90 days'
         AND NOT EXISTS (
           SELECT 1
           FROM nextstop.app_attest_challenges AS challenge
           WHERE challenge.key_id_hash = key.key_id_hash
             AND challenge.expires_at > $1
         )`,
      [now, maximumRows, excludedKeyIdHash],
    );
    return result.rowCount ?? 0;
  }

  async insertChallenge(
    input: Parameters<AppAttestAuthenticationRepository["insertChallenge"]>[0],
  ): Promise<void> {
    await this.pool.query(
      `INSERT INTO nextstop.app_attest_challenges (
         challenge_id, key_id_hash, purpose, client_data, created_at, expires_at
       ) VALUES ($1, $2, $3, $4, $5, $6)`,
      [
        input.challengeId,
        input.keyIdHash,
        input.purpose,
        input.clientData,
        input.createdAt,
        input.expiresAt,
      ],
    );
  }

  async consumeChallenge(
    input: Parameters<AppAttestAuthenticationRepository["consumeChallenge"]>[0],
  ): Promise<Buffer | undefined> {
    const result = await this.pool.query<{ readonly clientData: Buffer }>(
      `DELETE FROM nextstop.app_attest_challenges
       WHERE challenge_id = $1
         AND key_id_hash = $2
         AND purpose = $3
         AND expires_at > $4
       RETURNING client_data AS "clientData"`,
      [input.challengeId, input.keyIdHash, input.purpose, input.now],
    );
    return result.rows[0]?.clientData;
  }

  async insertKey(key: AttestedKey, attestedAt: Date): Promise<boolean> {
    const result = await this.pool.query(
      `INSERT INTO nextstop.app_attest_keys (
         key_id_hash, public_key_pem, receipt, environment, sign_count,
         validation_category, bundle_version, attested_at
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (key_id_hash) DO NOTHING`,
      [
        key.keyIdHash,
        key.publicKeyPEM,
        key.receipt,
        key.environment,
        key.signCount,
        key.validationCategory ?? null,
        key.bundleVersion ?? null,
        attestedAt,
      ],
    );
    return result.rowCount === 1;
  }

  async findKey(keyIdHash: Buffer): Promise<AttestedKey | undefined> {
    const result = await this.pool.query<{
      readonly keyIdHash: Buffer;
      readonly publicKeyPEM: string;
      readonly receipt: Buffer;
      readonly environment: "production" | "development";
      readonly signCount: string;
      readonly validationCategory: number | null;
      readonly bundleVersion: string | null;
      readonly revokedAt: Date | null;
    }>(
      `SELECT key_id_hash AS "keyIdHash",
              public_key_pem AS "publicKeyPEM",
              receipt,
              environment,
              sign_count AS "signCount",
              validation_category AS "validationCategory",
              bundle_version AS "bundleVersion",
              revoked_at AS "revokedAt"
       FROM nextstop.app_attest_keys
       WHERE key_id_hash = $1`,
      [keyIdHash],
    );
    const row = result.rows[0];
    if (row === undefined) {
      return undefined;
    }
    const signCount = Number(row.signCount);
    if (!Number.isSafeInteger(signCount) || signCount < 0 || signCount > 0xffff_ffff) {
      throw new Error("Stored App Attest sign counter is invalid.");
    }
    return {
      keyIdHash: row.keyIdHash,
      publicKeyPEM: row.publicKeyPEM,
      receipt: row.receipt,
      environment: row.environment,
      signCount,
      ...(row.validationCategory === null
        ? {}
        : { validationCategory: row.validationCategory }),
      ...(row.bundleVersion === null ? {} : { bundleVersion: row.bundleVersion }),
      revoked: row.revokedAt !== null,
    };
  }

  async advanceCounter(
    input: Parameters<AppAttestAuthenticationRepository["advanceCounter"]>[0],
  ): Promise<boolean> {
    const result = await this.pool.query(
      `UPDATE nextstop.app_attest_keys
       SET sign_count = $3,
           last_asserted_at = $4
       WHERE key_id_hash = $1
         AND sign_count = $2
         AND $3 > sign_count
         AND revoked_at IS NULL`,
      [input.keyIdHash, input.previousSignCount, input.nextSignCount, input.assertedAt],
    );
    return result.rowCount === 1;
  }
}
