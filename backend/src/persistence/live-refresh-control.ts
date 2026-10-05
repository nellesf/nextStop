import { randomUUID } from "node:crypto";
import type { Pool, PoolClient } from "pg";

export interface LiveRefreshLease { readonly providerId: "ich_tanke_strom"; readonly owner: string }
export interface LiveRefreshLeasing {
  acquire(): Promise<{ readonly lease?: LiveRefreshLease; readonly pending: boolean; readonly retryable?: boolean }>;
  finish(lease: LiveRefreshLease, success: boolean): Promise<void>;
}

export class PostgresLiveRefreshControl implements LiveRefreshLeasing {
  constructor(private readonly pool: Pool) {}
  async acquire(): ReturnType<LiveRefreshLeasing["acquire"]> {
    const owner = randomUUID();
    const result = await this.pool.query<{ owner: string }>(`INSERT INTO nextstop.live_refresh_control
      (provider_id, lease_owner, lease_until, next_allowed_at, last_attempt_at)
      VALUES ('ich_tanke_strom', $1, clock_timestamp() + interval '10 minutes', clock_timestamp() + interval '60 seconds', clock_timestamp())
      ON CONFLICT (provider_id) DO UPDATE SET lease_owner = EXCLUDED.lease_owner, lease_until = EXCLUDED.lease_until,
        next_allowed_at = EXCLUDED.next_allowed_at, last_attempt_at = EXCLUDED.last_attempt_at
      WHERE (live_refresh_control.lease_until IS NULL OR live_refresh_control.lease_until <= clock_timestamp())
        AND live_refresh_control.next_allowed_at <= clock_timestamp()
      RETURNING lease_owner AS owner`, [owner]);
    if (result.rows[0]?.owner === owner) return { lease: { providerId: "ich_tanke_strom", owner }, pending: true };
    const current = await this.pool.query<{ pending: boolean; retryable: boolean }>(`SELECT lease_until > clock_timestamp() AS pending,
        (COALESCE(lease_until > clock_timestamp(), false)
          OR last_success_at IS NULL OR last_success_at < last_attempt_at) AS retryable
      FROM nextstop.live_refresh_control WHERE provider_id = 'ich_tanke_strom'`);
    return { pending: current.rows[0]?.pending === true, retryable: current.rows[0]?.retryable === true };
  }
  async finish(lease: LiveRefreshLease, success: boolean): Promise<void> {
    await this.pool.query(`UPDATE nextstop.live_refresh_control SET lease_owner = NULL, lease_until = NULL,
      next_allowed_at = clock_timestamp() + interval '60 seconds',
      last_success_at = CASE WHEN $3 THEN clock_timestamp() ELSE last_success_at END
      WHERE provider_id = $1 AND lease_owner = $2`, [lease.providerId, lease.owner, success]);
  }
}

/** Checked in the publication transaction: an expired/crashed worker can never publish over its successor. */
export async function assertLiveRefreshLease(client: PoolClient, lease: LiveRefreshLease): Promise<void> {
  const current = await client.query(`SELECT provider_id FROM nextstop.live_refresh_control
    WHERE provider_id = $1 AND lease_owner = $2 AND lease_until > clock_timestamp() FOR UPDATE`,
  [lease.providerId, lease.owner]);
  if (current.rowCount !== 1) throw new Error("LiveRefreshLeaseLost");
}
