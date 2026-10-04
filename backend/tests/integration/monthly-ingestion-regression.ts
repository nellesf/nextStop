import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Pool } from "pg";
import { PostgresMonthlySchedule } from "../../src/jobs/monthly-ingestion.js";

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
}
