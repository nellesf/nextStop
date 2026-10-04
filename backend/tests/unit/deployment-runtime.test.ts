import assert from "node:assert/strict";
import test from "node:test";
import { databasePoolConfiguration } from "../../src/persistence/database.js";
import { deploymentRuntime, httpShutdownGraceMilliseconds } from "../../src/runtime/deployment-runtime.js";
import { startReportPurge } from "../../src/runtime/report-purge.js";
import { liveRefreshTransport } from "../../src/runtime/live-refresh-transport.js";

const cloud = { NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging" };
const url = "postgresql://synthetic-user:synthetic-password@db.example.org/nextstop";

void test("cloud runtime requires explicit staging opt-in; VM defaults and drain duration are unchanged", () => {
  assert.equal(deploymentRuntime({}), "vm");
  assert.equal(deploymentRuntime({ NEXTSTOP_ENVIRONMENT: "production" }), "vm");
  assert.equal(deploymentRuntime(cloud), "cloud-run");
  for (const value of [{ NEXTSTOP_RUNTIME: "cloud-run" }, { ...cloud, NEXTSTOP_ENVIRONMENT: "production" }, { NEXTSTOP_RUNTIME: "other" }]) {
    assert.throws(() => deploymentRuntime(value));
  }
  assert.equal(httpShutdownGraceMilliseconds("cloud-run"), 8_000);
  assert.equal(httpShutdownGraceMilliseconds("vm"), 30_000);
});

void test("VM database connection/pool configuration remains unchanged", () => {
  assert.deepEqual(databasePoolConfiguration(url, {}, {}), {
    connectionString: url, max: 10, connectionTimeoutMillis: 5_000, idleTimeoutMillis: 30_000, application_name: "nextstop-backend",
  });
  const customized = databasePoolConfiguration(url, { maxConnections: 8, connectionTimeoutMilliseconds: 500,
    queryTimeoutMilliseconds: 750, statementTimeoutMilliseconds: 500 }, {});
  assert.equal(customized.max, 8); assert.equal(customized.connectionTimeoutMillis, 500);
  assert.equal(customized.query_timeout, 750); assert.equal(customized.statement_timeout, 500);
});

void test("cloud pools bound connections, allow cold DB connection time and enforce verified TLS independently of URL mode", () => {
  const configuration = databasePoolConfiguration(`${url}?sslmode=require`, { maxConnections: 10,
    connectionTimeoutMilliseconds: 500, statementTimeoutMilliseconds: 1_000 }, cloud);
  assert.equal(configuration.max, 4);
  assert.equal(configuration.connectionTimeoutMillis, 10_000);
  assert.equal(configuration.idleTimeoutMillis, 1_000);
  assert.equal(configuration.statement_timeout, 1_000);
  assert.deepEqual(configuration.ssl, { rejectUnauthorized: true });
  assert.equal(new URL(configuration.connectionString ?? "").searchParams.has("sslmode"), false);
  assert.equal(databasePoolConfiguration(url, {}, cloud).max, 2);
  assert.deepEqual(databasePoolConfiguration(`${url}?sslmode=verify-full`, {}, { ...cloud, DATABASE_SSL_CA: "synthetic-CA" }).ssl,
    { rejectUnauthorized: true, ca: "synthetic-CA" });
  for (const suffix of ["sslmode=disable", "sslmode=no-verify", "sslmode=prefer", "ssl=false", "sslrootcert=/private/path",
    "sslkey=/private/key", "uselibpqcompat=true", "host=/tmp"]) {
    assert.throws(() => databasePoolConfiguration(`${url}?${suffix}`, {}, cloud), (error: unknown) =>
      error instanceof Error && !/synthetic-password|\/private\//u.test(error.message));
  }
  assert.throws(() => databasePoolConfiguration("not a URL with private credential", {}, cloud), /connection URL is invalid/u);
});

void test("cloud API start has no support DB purge and schedules no periodic DB work", async () => {
  let calls = 0, timers = 0;
  const stop = await startReportPurge({ purge: () => { calls += 1; return Promise.resolve(0); } }, "cloud-run", {
    schedule: () => { timers += 1; return () => {}; },
  });
  stop(); assert.equal(calls, 0); assert.equal(timers, 0);
});

void test("VM still purges on startup and every15 minutes with overlap prevention", async () => {
  let calls = 0, stopped = false;
  let tick = (): void => {};
  const running = Promise.withResolvers<number>();
  const stop = await startReportPurge({ purge: () => {
    calls += 1; return calls === 1 ? Promise.resolve(0) : running.promise;
  } }, "vm", { schedule: (work, milliseconds) => {
    assert.equal(milliseconds, 15 * 60 * 1_000); tick = work; return () => { stopped = true; };
  } });
  assert.equal(calls, 1);
  tick(); tick(); assert.equal(calls, 2);
  running.resolve(0); await running.promise;
  stop(); assert.equal(stopped, true);
});

void test("VM transport does not require Cloud Tasks configuration and cross-runtime transports fail closed", async () => {
  const transport = await liveRefreshTransport("vm", { LIVE_REFRESH_TOKEN: "synthetic-only-token-at-least-thirty-two-bytes" });
  await transport.close();
  await assert.rejects(liveRefreshTransport("vm", { LIVE_REFRESH_TRANSPORT: "cloud-tasks" }), /match/u);
  await assert.rejects(liveRefreshTransport("cloud-run", { LIVE_REFRESH_TRANSPORT: "vm-http" }), /match/u);
});
