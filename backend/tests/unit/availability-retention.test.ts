import assert from "node:assert/strict";
import test from "node:test";
import type { Pool } from "pg";
import { pruneExpiredAvailabilitySnapshots } from "../../src/persistence/availability-retention.js";

void test("availability retention validates finite budgets before opening a database connection", async () => {
  const pool = { connect: () => { throw new Error("must not connect"); } } as unknown as Pool;
  for (const options of [{ maxSnapshots: 65 }, { maxSnapshots: 0 }, { batchSize: 1_001 },
    { maxBatchesPerSnapshot: 33 }, { maximumMilliseconds: 120_001 }, { batchSize: Number.NaN }]) {
    await assert.rejects(pruneExpiredAvailabilitySnapshots(pool, undefined, options), /Invalid availability retention limit/u);
  }
});

void test("monotonic cleanup deadline stops after a committed bounded batch", async () => {
  let tick = 0, releases = 0, connects = 0;
  const statements: string[] = [];
  const pool = { connect: () => { connects += 1; return Promise.resolve({
    query: (sql: string) => {
      statements.push(sql);
      if (sql.startsWith("SELECT id")) return Promise.resolve({ rows: [{ id: "10000000-0000-4000-8000-000000000001" }] });
      if (sql.startsWith("DELETE FROM nextstop.availability_observations")) return Promise.resolve({ rowCount: 1_000 });
      return Promise.resolve({ rowCount: 0 });
    }, release: () => { releases += 1; },
  }); } } as unknown as Pool;
  const result = await pruneExpiredAvailabilitySnapshots(pool, undefined,
    { maximumMilliseconds: 1, monotonicNow: () => tick++ < 2 ? 0 : 2 });
  assert.deepEqual(result, { kind: "bounded", deletedObservations: 1_000, deletedSnapshots: 0, batches: 1 });
  assert.equal(connects, 1); assert.equal(releases, 1); assert.equal(statements.at(-1), "COMMIT");
});

void test("retention rolls back query/lock timeouts but does not hide other database failures", async () => {
  for (const code of ["57014", "55P03", "42501"]) {
    const statements: string[] = []; let released = false;
    const pool = { connect: () => Promise.resolve({
      query: (sql: string) => {
        statements.push(sql);
        if (sql.startsWith("SELECT id")) return Promise.reject(Object.assign(new Error("private database detail"), { code }));
        return Promise.resolve({});
      }, release: () => { released = true; },
    }) } as unknown as Pool;
    if (code === "42501") await assert.rejects(pruneExpiredAvailabilitySnapshots(pool), { code });
    else assert.equal((await pruneExpiredAvailabilitySnapshots(pool)).kind, "busy");
    assert.equal(statements.at(-1), "ROLLBACK"); assert.equal(released, true);
  }
});
