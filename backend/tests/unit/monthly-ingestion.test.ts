import assert from "node:assert/strict";
import test from "node:test";
import {
  maximumMaintenanceTimerMilliseconds, monthlyRetryMilliseconds, nextMonthlyImport,
  runDueMonthlyImports, type MonthlyIngestionJob, type MonthlySchedule,
} from "../../src/jobs/monthly-ingestion.js";

class MemorySchedule implements MonthlySchedule {
  private locked = false;
  readonly dates = new Map<MonthlyIngestionJob, Date>();
  readonly attempts = new Map<MonthlyIngestionJob, string>();
  constructor(due: Date) {
    this.dates.set("charging-static", due);
    this.dates.set("food-pois", due);
  }
  acquireMaintenance(): Promise<(() => Promise<void>) | undefined> {
    if (this.locked) return Promise.resolve(undefined);
    this.locked = true;
    return Promise.resolve(() => { this.locked = false; return Promise.resolve(); });
  }
  dueAt(job: MonthlyIngestionJob): Promise<Date> { return Promise.resolve(this.dates.get(job)!); }
  claim(job: MonthlyIngestionJob, now: Date, attempt: string): Promise<boolean> {
    if (this.dates.get(job)!.getTime() > now.getTime()) return Promise.resolve(false);
    this.dates.set(job, new Date(now.getTime() + monthlyRetryMilliseconds));
    this.attempts.set(job, attempt);
    return Promise.resolve(true);
  }
  complete(job: MonthlyIngestionJob, now: Date, attempt: string): Promise<void> {
    if (this.attempts.get(job) === attempt) this.dates.set(job, nextMonthlyImport(now));
    return Promise.resolve();
  }
}

void test("monthly imports use calendar months at 02:00 UTC including leap/year boundaries", () => {
  for (const [input, expected] of [
    ["2026-10-04T04:00:00Z", "2026-11-01T02:00:00.000Z"],
    ["2026-12-31T23:59:59Z", "2027-01-01T02:00:00.000Z"],
    ["2028-02-29T12:00:00Z", "2028-03-01T02:00:00.000Z"],
  ]) assert.equal(nextMonthlyImport(new Date(input!)).toISOString(), expected);
});

void test("successful unchanged imports survive restart without downloading twice and run sequentially", async () => {
  const now = new Date("2026-10-01T02:00:00Z");
  const schedule = new MemorySchedule(now);
  const calls: string[] = [];
  let active = 0;
  const run = () => runDueMonthlyImports({
    schedule, now: () => now, foodEnabled: true, stopped: () => false,
    refresh: async (job) => {
      assert.equal(active++, 0);
      calls.push(job);
      await Promise.resolve();
      active--;
    },
    report: (job, result) => calls.push(`${job}:${result}`),
  });
  const delay = await run();
  assert.deepEqual(calls, ["charging-static", "charging-static:success", "food-pois", "food-pois:success"]);
  await run();
  assert.equal(calls.length, 4);
  assert.equal(delay, maximumMaintenanceTimerMilliseconds);
  assert.ok(delay < 2 ** 31 - 1);
  assert.equal((await schedule.dueAt("charging-static")).toISOString(), "2026-11-01T02:00:00.000Z");
});

void test("failure retains a durable one-day retry and still refreshes the independent food source", async () => {
  let now = new Date("2026-10-01T02:00:00Z");
  const schedule = new MemorySchedule(now);
  const calls: string[] = [];
  const run = () => runDueMonthlyImports({
    schedule, now: () => now, foodEnabled: true, stopped: () => false,
    refresh: (job) => { calls.push(job); return job === "charging-static" ? Promise.reject(new Error("offline")) : Promise.resolve(); },
    report: (job, result) => calls.push(`${job}:${result}`),
  });
  assert.equal(await run(), monthlyRetryMilliseconds);
  assert.deepEqual(calls, ["charging-static", "charging-static:failed", "food-pois", "food-pois:success"]);
  await run();
  assert.equal(calls.length, 4);
  now = new Date(now.getTime() + monthlyRetryMilliseconds);
  await run();
  assert.deepEqual(calls.slice(4), ["charging-static", "charging-static:failed"]);
});

void test("stopping during one import prevents the next source from starting", async () => {
  const now = new Date("2026-10-01T02:00:00Z");
  let stopped = false;
  const calls: string[] = [];
  await runDueMonthlyImports({
    schedule: new MemorySchedule(now), now: () => now, foodEnabled: true, stopped: () => stopped,
    refresh: (job) => { calls.push(job); stopped = true; return Promise.resolve(); }, report: () => undefined,
  });
  assert.deepEqual(calls, ["charging-static"]);
});

void test("a disabled food importer makes no food schedule or provider request", async () => {
  const now = new Date("2026-10-01T02:00:00Z");
  const schedule = new MemorySchedule(now);
  const calls: string[] = [];
  await runDueMonthlyImports({
    schedule, now: () => now, foodEnabled: false, stopped: () => false,
    refresh: (job) => { calls.push(job); return Promise.resolve(); }, report: () => undefined,
  });
  assert.deepEqual(calls, ["charging-static"]);
  assert.equal((await schedule.dueAt("food-pois")).getTime(), now.getTime());
});

void test("concurrent invocations share the persisted claim even while the first download waits", async () => {
  const now = new Date("2026-10-01T02:00:00Z");
  const schedule = new MemorySchedule(now);
  let release: (() => void) | undefined;
  const pending = new Promise<void>((resolve) => { release = resolve; });
  let calls = 0;
  const run = () => runDueMonthlyImports({
    schedule, now: () => now, foodEnabled: false, stopped: () => false,
    refresh: () => { calls++; return pending; }, report: () => undefined,
  });
  const first = run();
  await new Promise((resolve) => setImmediate(resolve));
  await run();
  assert.equal(calls, 1);
  release?.();
  await first;
});

void test("a second worker cannot start food while another worker is still importing charging data", async () => {
  const now = new Date("2026-10-01T02:00:00Z");
  const schedule = new MemorySchedule(now);
  let release: (() => void) | undefined;
  const pending = new Promise<void>((resolve) => { release = resolve; });
  const calls: string[] = [];
  const run = () => runDueMonthlyImports({
    schedule, now: () => now, foodEnabled: true, stopped: () => false,
    refresh: (job) => { calls.push(job); return job === "charging-static" ? pending : Promise.resolve(); },
    report: () => undefined,
  });
  const first = run();
  await new Promise((resolve) => setImmediate(resolve));
  await run();
  assert.deepEqual(calls, ["charging-static"]);
  release?.();
  await first;
  assert.deepEqual(calls, ["charging-static", "food-pois"]);
});
