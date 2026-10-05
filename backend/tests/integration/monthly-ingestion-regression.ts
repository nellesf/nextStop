import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Pool } from "pg";
import { PostgresMonthlySchedule } from "../../src/jobs/monthly-ingestion.js";
import { PostgresMonthlyImportBudget } from "../../src/jobs/cloud-monthly-ingestion.js";

export async function verifyMonthlyIngestion(pool: Pool): Promise<void> {
  const now = new Date("2026-10-01T02:00:00Z");
  const first = new PostgresMonthlySchedule(pool);
  const second = new PostgresMonthlySchedule(pool);
  const release = await first.acquireMaintenance();
  assert.ok(release);
  assert.equal(await second.acquireMaintenance(), undefined);
  await release();
  const nextRelease = await second.acquireMaintenance();
  assert.ok(nextRelease);
  await nextRelease();
  await pool.query("DELETE FROM nextstop.monthly_ingestion_schedule");
  await pool.query(
    "INSERT INTO nextstop.monthly_ingestion_schedule (job, next_due_at) VALUES ('charging-static', $1)", [now],
  );
  const attempts = [randomUUID(), randomUUID()];
  const claims = await Promise.all([
    first.claim("charging-static", now, attempts[0]!),
    second.claim("charging-static", now, attempts[1]!),
  ]);
  assert.deepEqual(claims.toSorted(), [false, true]);
  // Reconstructing the scheduler represents a new process after a crash.
  assert.equal((await new PostgresMonthlySchedule(pool).dueAt("charging-static", now)).toISOString(), "2026-10-02T02:00:00.000Z");
  const winner = claims[0] === true ? attempts[0]! : attempts[1]!;
  await first.complete("charging-static", now, randomUUID());
  assert.equal((await second.dueAt("charging-static", now)).toISOString(), "2026-10-02T02:00:00.000Z");
  await first.complete("charging-static", now, winner);
  assert.equal((await second.dueAt("charging-static", now)).toISOString(), "2026-11-01T02:00:00.000Z");
  assert.equal(await second.claim("charging-static", now, randomUUID()), false);
  await pool.query("DELETE FROM nextstop.monthly_ingestion_schedule");
  await verifyCloudMonthlyBudget(pool);
}

async function verifyCloudMonthlyBudget(pool: Pool): Promise<void> {
  const budget = new PostgresMonthlyImportBudget(pool);
  await pool.query("DELETE FROM nextstop.monthly_import_budget");
  const october = new Date("2026-10-31T23:59:59Z");
  const reservations = await Promise.all(Array.from({ length: 12 }, () => budget.reserve(october)));
  assert.equal(reservations.filter(Boolean).length, 3, "only three whole executions may reserve concurrently");
  assert.deepEqual((await pool.query("SELECT scope, month_start::text, attempts FROM nextstop.monthly_import_budget")).rows,
    [{ scope: "monthly-import", month_start: "2026-10-01", attempts: 3 }]);
  assert.equal(await new PostgresMonthlyImportBudget(pool).reserve(october), false, "restart cannot reset the budget");
  const november = new Date("2026-11-01T00:00:00Z");
  assert.equal(await budget.reserve(november), true, "UTC month boundary resets exactly once");
  assert.equal(await budget.reserve(october), false, "clock rollback cannot reset the counter");
  assert.equal((await pool.query<{ attempts: number }>("SELECT attempts FROM nextstop.monthly_import_budget")).rows[0]?.attempts, 1);
  await pool.query(`INSERT INTO nextstop.monthly_ingestion_schedule (job,next_due_at) VALUES
    ('charging-static','2026-11-01T00:00:00Z'),('food-pois','2026-12-10T00:00:00Z')`);
  await budget.deferDueUntilNextMonth(november);
  assert.deepEqual((await pool.query("SELECT job,next_due_at::text FROM nextstop.monthly_ingestion_schedule ORDER BY job")).rows,
    [{ job: "charging-static", next_due_at: "2026-12-01 02:00:00+00" }, { job: "food-pois", next_due_at: "2026-12-10 00:00:00+00" }]);
  await pool.query("DELETE FROM nextstop.monthly_ingestion_schedule");
  await pool.query("DELETE FROM nextstop.monthly_import_budget");
}
