import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { executeMaintenanceMode, maintenanceJobConfiguration } from "../../src/jobs/maintenance-job.js";
import { runBudgetedMonthlyImports, type MonthlyImportBudget } from "../../src/jobs/cloud-monthly-ingestion.js";
import { monthlyRetryMilliseconds, nextMonthlyImport, type MonthlyIngestionJob, type MonthlySchedule } from "../../src/jobs/monthly-ingestion.js";

const instant = new Date("2026-10-01T02:00:00Z");
class Schedule implements MonthlySchedule {
  locked = false;
  dates = new Map<MonthlyIngestionJob, Date>([["charging-static", instant], ["food-pois", instant]]);
  acquireMaintenance(): Promise<(() => Promise<void>) | undefined> {
    if (this.locked) return Promise.resolve(undefined);
    this.locked = true;
    return Promise.resolve(() => { this.locked = false; return Promise.resolve(); });
  }
  dueAt(job: MonthlyIngestionJob): Promise<Date> { return Promise.resolve(this.dates.get(job)!); }
  claim(job: MonthlyIngestionJob, now: Date): Promise<boolean> {
    assert.equal(this.locked, true);
    if (this.dates.get(job)!.getTime() > now.getTime()) return Promise.resolve(false);
    this.dates.set(job, new Date(now.getTime() + monthlyRetryMilliseconds)); return Promise.resolve(true);
  }
  complete(job: MonthlyIngestionJob, now: Date): Promise<void> {
    this.dates.set(job, nextMonthlyImport(now)); return Promise.resolve();
  }
}
class Budget implements MonthlyImportBudget {
  reservations = 0;
  constructor(readonly schedule: Schedule) {}
  reserve(): Promise<boolean> {
    assert.equal(this.schedule.locked, true);
    if (this.reservations === 3) return Promise.resolve(false);
    this.reservations++; return Promise.resolve(true);
  }
  deferDueUntilNextMonth(now: Date): Promise<void> {
    for (const [job, due] of this.schedule.dates) if (due <= now) this.schedule.dates.set(job, nextMonthlyImport(now));
    return Promise.resolve();
  }
}

void test("one shared monthly reservation covers sequential charging and OSM, with no budget for an idle daily check", async () => {
  const schedule = new Schedule(), budget = new Budget(schedule), calls: string[] = [];
  const run = () => runBudgetedMonthlyImports({ schedule, foodEnabled: true, stopped: () => false, now: () => instant,
    refresh: (job) => { assert.equal(schedule.locked, true); calls.push(job); return Promise.resolve(); }, report: () => {} }, budget);
  assert.equal(await run(), "completed"); assert.equal(budget.reservations, 1);
  assert.deepEqual(calls, ["charging-static", "food-pois"]);
  assert.equal(await run(), "not_due"); assert.equal(budget.reservations, 1); assert.equal(schedule.locked, false);
});

void test("failed heavy jobs exit as failures, retry after24h, stop at three shared attempts and defer next month", async () => {
  const schedule = new Schedule(), budget = new Budget(schedule);
  let now = instant, charging = 0, food = 0;
  const run = () => runBudgetedMonthlyImports({ schedule, foodEnabled: true, stopped: () => false, now: () => now,
    refresh: (job) => { if (job === "charging-static") { charging++; throw new Error("provider unavailable"); }
      food++; return Promise.resolve(); }, report: () => {} }, budget);
  for (let attempt = 0; attempt < 3; attempt++) {
    await assert.rejects(run(), /MonthlyImportFailed/u);
    assert.equal(await run(), "not_due");
    now = new Date(now.getTime() + monthlyRetryMilliseconds);
  }
  assert.equal(charging, 3); assert.equal(food, 1); assert.equal(budget.reservations, 3);
  assert.equal(await run(), "budget_exhausted"); assert.equal(await run(), "not_due");
  assert.equal((await schedule.dueAt("charging-static")).toISOString(), "2026-11-01T02:00:00.000Z");
  assert.equal(schedule.locked, false);
});

void test("global lock covers both imports and the budget; a concurrent execution cannot reserve or download", async () => {
  const schedule = new Schedule(), budget = new Budget(schedule);
  let release: (() => void) | undefined;
  const wait = new Promise<void>((resolve) => { release = resolve; });
  const run = () => runBudgetedMonthlyImports({ schedule, foodEnabled: true, stopped: () => false, now: () => instant,
    refresh: () => wait, report: () => {} }, budget);
  const first = run(); await new Promise((resolve) => setImmediate(resolve));
  await assert.rejects(run(), /MonthlyImportBusy/u); assert.equal(budget.reservations, 1);
  release?.(); assert.equal(await first, "completed"); assert.equal(schedule.locked, false);
});

void test("budget database error releases the global lock and never starts provider work", async () => {
  const schedule = new Schedule(); let refreshed = false;
  await assert.rejects(runBudgetedMonthlyImports({ schedule, foodEnabled: true, stopped: () => false, now: () => instant,
    refresh: () => { refreshed = true; return Promise.resolve(); }, report: () => {} }, {
    reserve: () => Promise.reject(new Error("database unavailable")), deferDueUntilNextMonth: () => Promise.resolve(),
  }), /database unavailable/u);
  assert.equal(refreshed, false); assert.equal(schedule.locked, false);
});

void test("cloud maintenance configuration enforces runtime, cache, role connection and hard per-mode deadlines", () => {
  const base = { NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging", DATABASE_URL: "postgres://worker/database",
    SUPPORT_DATABASE_URL: "postgres://support/database", DOWNLOAD_CACHE_BACKEND: "gcs", DOWNLOAD_CACHE_BUCKET: "private-cache" };
  assert.deepEqual(maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: "monthly-import" }),
    { mode: "monthly-import", maximumSeconds: 28_800, databaseURL: base.DATABASE_URL });
  assert.equal(maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: "report-purge" }).databaseURL, base.SUPPORT_DATABASE_URL);
  for (const mode of ["monthly-import", "cleanup", "report-purge"]) {
    assert.throws(() => maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: mode, MAINTENANCE_JOB_MAX_SECONDS: "28801" }));
    assert.throws(() => maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: mode, MAINTENANCE_JOB_MAX_SECONDS: "0" }));
    assert.throws(() => maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: mode, NEXTSTOP_ENVIRONMENT: "production" }));
  }
  for (const change of [{ DOWNLOAD_CACHE_BACKEND: "file" }, { DOWNLOAD_CACHE_BUCKET: "gs://invalid" }, { NEXTSTOP_RUNTIME: "vm" },
    { DATABASE_URL: "" }, { MAINTENANCE_JOB_MODE: "unknown" }]) {
    assert.throws(() => maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: "monthly-import", ...change }));
  }
  assert.throws(() => maintenanceJobConfiguration({ ...base, MAINTENANCE_JOB_MODE: "report-purge", SUPPORT_DATABASE_URL: "" }));
});

void test("maintenance mode dispatches exactly one action and propagates its failure", async () => {
  const calls: string[] = [];
  const actions = { monthly: () => { calls.push("monthly"); return Promise.resolve("not_due"); },
    cleanup: () => { calls.push("cleanup"); return Promise.resolve(); }, purge: () => { calls.push("purge"); return Promise.resolve(); } };
  assert.equal(await executeMaintenanceMode("monthly-import", actions), "not_due");
  assert.equal(await executeMaintenanceMode("cleanup", actions), "completed");
  assert.equal(await executeMaintenanceMode("report-purge", actions), "completed");
  assert.deepEqual(calls, ["monthly", "cleanup", "purge"]);
  await assert.rejects(executeMaintenanceMode("cleanup", { ...actions, cleanup: () => Promise.reject(new Error("lock timeout")) }));
});

void test("actual maintenance entrypoint exits nonzero on invalid configuration without exposing private configuration", () => {
  const result = spawnSync(process.execPath, ["--import", "tsx", "src/jobs/maintenance-job.ts"], {
    cwd: new URL("../..", import.meta.url), encoding: "utf8", timeout: 10_000,
    env: { ...process.env, NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging", MAINTENANCE_JOB_MODE: "invalid",
      DATABASE_URL: "postgres://private-user:private-secret@private-host/nextstop" },
  });
  assert.equal(result.status, 1); assert.equal(result.stdout, "");
  assert.equal(result.stderr.trim(), '{"event":"maintenance_job_failed"}');
});
