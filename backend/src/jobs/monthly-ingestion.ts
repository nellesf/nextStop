import { randomUUID } from "node:crypto";
import type { Pool } from "pg";

export type MonthlyIngestionJob = "charging-static" | "food-pois";
export const monthlyRetryMilliseconds = 24 * 60 * 60 * 1_000;
// Node timers overflow above 2^31-1 ms. A calendar month exceeds that limit.
export const maximumMaintenanceTimerMilliseconds = 24 * 24 * 60 * 60 * 1_000;

export function nextMonthlyImport(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1, 2));
}

export interface MonthlySchedule {
  acquireMaintenance(): Promise<(() => Promise<void>) | undefined>;
  dueAt(job: MonthlyIngestionJob, now: Date): Promise<Date>;
  claim(job: MonthlyIngestionJob, now: Date, attemptId: string): Promise<boolean>;
  complete(job: MonthlyIngestionJob, now: Date, attemptId: string): Promise<void>;
}

/** One persisted row per source family, not one job per user or request. */
export class PostgresMonthlySchedule implements MonthlySchedule {
  constructor(private readonly pool: Pool) {}

  async acquireMaintenance(): Promise<(() => Promise<void>) | undefined> {
    const client = await this.pool.connect();
    try {
      const result = await client.query<{ acquired: boolean }>(
        "SELECT pg_try_advisory_lock(684237155161395702) AS acquired",
      );
      if (result.rows[0]?.acquired !== true) { client.release(); return undefined; }
      return async () => {
        try {
          await client.query("SELECT pg_advisory_unlock(684237155161395702)");
          client.release();
        } catch { client.release(true); }
      };
    } catch (error) { client.release(true); throw error; }
  }

  async dueAt(job: MonthlyIngestionJob, now: Date): Promise<Date> {
    // An existing corpus is already usable: enabling monthly mode must not
    // start an expensive import during a release. Empty databases bootstrap now.
    const table = job === "charging-static" ? "projection_versions" : "food_poi_projection_versions";
    await this.pool.query(
      `INSERT INTO nextstop.monthly_ingestion_schedule (job, next_due_at)
       SELECT $1, CASE WHEN EXISTS (
         SELECT 1 FROM nextstop.${table} WHERE status = 'active'
       ) THEN $3::timestamptz ELSE $2::timestamptz END
       ON CONFLICT (job) DO NOTHING`, [job, now, nextMonthlyImport(now)],
    );
    const result = await this.pool.query<{ nextDueAt: Date }>(
      'SELECT next_due_at AS "nextDueAt" FROM nextstop.monthly_ingestion_schedule WHERE job = $1', [job],
    );
    const due = result.rows[0]?.nextDueAt;
    if (due === undefined) throw new Error("Monthly ingestion schedule is unavailable.");
    return due;
  }

  async claim(job: MonthlyIngestionJob, now: Date, attemptId: string): Promise<boolean> {
    // Reserve the retry date before downloading. A crash/restart cannot trigger
    // a tight download loop, and concurrent workers cannot claim the same job.
    const result = await this.pool.query(
      `UPDATE nextstop.monthly_ingestion_schedule
       SET next_due_at = $3, last_attempt_at = $2, attempt_id = $4
       WHERE job = $1 AND next_due_at <= $2`,
      [job, now, new Date(now.getTime() + monthlyRetryMilliseconds), attemptId],
    );
    return result.rowCount === 1;
  }

  async complete(job: MonthlyIngestionJob, now: Date, attemptId: string): Promise<void> {
    await this.pool.query(
      `UPDATE nextstop.monthly_ingestion_schedule
       SET next_due_at = $3, last_success_at = $2
       WHERE job = $1 AND attempt_id = $4`, [job, now, nextMonthlyImport(now), attemptId],
    );
  }
}

export interface MonthlyIngestionDependencies {
  readonly schedule: MonthlySchedule;
  readonly refresh: (job: MonthlyIngestionJob) => Promise<void>;
  readonly report: (job: MonthlyIngestionJob, outcome: "success" | "failed") => void;
  readonly foodEnabled: boolean;
  readonly stopped: () => boolean;
  readonly now?: () => Date;
  readonly makeAttemptId?: () => string;
}

/** Charging and food work run sequentially to avoid competing heavy imports. */
export async function runDueMonthlyImports(dependencies: MonthlyIngestionDependencies): Promise<number> {
  const release = await dependencies.schedule.acquireMaintenance();
  if (release === undefined) return 15 * 60 * 1_000;
  try { return await runExclusiveMonthlyImports(dependencies); }
  finally { await release(); }
}

async function runExclusiveMonthlyImports(dependencies: MonthlyIngestionDependencies): Promise<number> {
  const now = dependencies.now ?? (() => new Date());
  const jobs: readonly MonthlyIngestionJob[] = dependencies.foodEnabled
    ? ["charging-static", "food-pois"] : ["charging-static"];
  let nextDelay = maximumMaintenanceTimerMilliseconds;
  for (const job of jobs) {
    if (dependencies.stopped()) break;
    let due = await dependencies.schedule.dueAt(job, now());
    if (due.getTime() <= now().getTime()) {
      const attemptId = (dependencies.makeAttemptId ?? randomUUID)();
      if (await dependencies.schedule.claim(job, now(), attemptId)) {
        try {
          await dependencies.refresh(job);
          await dependencies.schedule.complete(job, now(), attemptId);
          dependencies.report(job, "success");
        } catch {
          // Keep the published corpus and the persisted one-day retry date.
          dependencies.report(job, "failed");
        }
      }
      due = await dependencies.schedule.dueAt(job, now());
    }
    nextDelay = Math.min(nextDelay, Math.max(1_000, due.getTime() - now().getTime()));
  }
  return nextDelay;
}
