import type { ReadinessChecking } from "../api/readiness.js";
import { migrationManifest } from "./migration-policy.js";

export interface ReadinessDatabase {
  query(text: string, values: unknown[]): Promise<{ rows: { ready: boolean }[] }>;
}

const requiredMigrations = migrationManifest.map(({ name }) => name);

/** Checks serving data, never provider freshness or the health of a new build. */
export class SearchReadiness implements ReadinessChecking {
  constructor(private readonly database: ReadinessDatabase, private readonly configured: boolean) {}

  async isReady(): Promise<boolean> {
    if (!this.configured) return false;
    const result = await this.database.query(
      `SELECT nextstop.required_migrations_applied($1::text[])
         AND EXISTS (
           SELECT 1 FROM nextstop.projection_versions AS version
           WHERE version.status = 'active' AND version.search_pruned_at IS NULL
             AND version.park_count > 0 AND version.campus_count > 0
             AND EXISTS (SELECT 1 FROM nextstop.charging_park_power_projection AS park
                         WHERE park.projection_id = version.id)
             AND EXISTS (SELECT 1 FROM nextstop.charging_campus_power_projection AS campus
                         WHERE campus.projection_id = version.id)
         )
         AND EXISTS (
           SELECT 1 FROM nextstop.food_poi_projection_versions AS version
           WHERE version.status = 'active' AND version.poi_count > 0
             AND EXISTS (SELECT 1 FROM nextstop.food_poi_projection AS poi
                         WHERE poi.projection_id = version.id)
         ) AS ready`,
      [requiredMigrations],
    );
    return result.rows[0]?.ready === true;
  }
}

export class AuthenticationReadiness implements ReadinessChecking {
  constructor(private readonly database: ReadinessDatabase, private readonly configured: boolean) {}

  async isReady(): Promise<boolean> {
    if (!this.configured) return false;
    // LIMIT 0 validates access to both tables without exposing credential data.
    const result = await this.database.query(
      `WITH keys AS MATERIALIZED (
         SELECT key_id_hash FROM nextstop.app_attest_keys LIMIT 0
       ), challenges AS MATERIALIZED (
         SELECT challenge_id FROM nextstop.app_attest_challenges LIMIT 0
       )
       SELECT nextstop.required_migrations_applied($1::text[])
         AND (SELECT count(*) FROM keys) = 0
         AND (SELECT count(*) FROM challenges) = 0 AS ready`,
      [requiredMigrations],
    );
    return result.rows[0]?.ready === true;
  }
}
