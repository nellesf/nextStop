import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { runCloudMigrations, type CloudMigrationCommand } from "../../src/jobs/cloud-migrate.js";

const environment = { NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging",
  DATABASE_TRANSPORT: "cloud-sql-socket", CLOUD_SQL_CONNECTION_NAME: "nextstop-tech-testing:europe-west1:nextstop-staging",
  DATABASE_URL: "postgresql://nextstop_app:synthetic%3Aprivate%40password@localhost/nextstop",
  UNRELATED_SECRET: "must-not-reach-child", NODE_OPTIONS: "untrusted-extra-loader", PGHOST: "untrusted-host" };

void test("cloud migrations run expand-only then restricted object grants with secret-free arguments and bounded children", async () => {
  const calls: CloudMigrationCommand[] = [];
  await runCloudMigrations(environment, (command) => { calls.push(command); return Promise.resolve(); });
  assert.deepEqual(calls.map((command) => command.phase), ["schema", "grants"]);
  assert.match(calls[0]!.arguments[0]!, /\/persistence\/migrate\.js$/u);
  assert.equal(calls[0]!.arguments[1], "--expand-only");
  assert.equal(calls[1]!.executable, "/usr/lib/postgresql/17/bin/psql");
  assert.ok(calls[1]!.arguments.includes("ON_ERROR_STOP=1"));
  assert.match(calls[1]!.arguments.at(-1)!, /\/operations\/database-roles\.sql$/u);
  assert.equal(calls[1]!.environment.PGUSER, "nextstop_app");
  assert.equal(calls[1]!.environment.PGHOST, "/cloudsql/nextstop-tech-testing:europe-west1:nextstop-staging");
  assert.equal(calls[1]!.environment.PGPASSWORD, "synthetic:private@password");
  assert.equal(calls[1]!.environment.DATABASE_URL, undefined);
  for (const command of calls) {
    assert.doesNotMatch(command.arguments.join(" "), /synthetic|postgresql:/u);
    assert.equal(command.environment.UNRELATED_SECRET, undefined);
    assert.equal(command.environment.NODE_OPTIONS, undefined);
    assert.ok(command.timeoutMilliseconds > 0 && command.timeoutMilliseconds < 900_000);
  }
});

void test("a failed schema phase prevents grants and neither phase reflects child errors", async () => {
  for (const failed of ["schema", "grants"]) {
    const calls: string[] = [];
    await assert.rejects(runCloudMigrations(environment, (command) => {
      calls.push(command.phase);
      return command.phase === failed ? Promise.reject(new Error("private password plus raw SQL")) : Promise.resolve();
    }), (error: unknown) => error instanceof Error && error.message === "Cloud migration phase failed.");
    assert.deepEqual(calls, failed === "schema" ? ["schema"] : ["schema", "grants"]);
  }
});

void test("invalid environment or non-owner credentials never start a migration child", async () => {
  for (const change of [{ NEXTSTOP_RUNTIME: "vm" }, { NEXTSTOP_ENVIRONMENT: "production" },
    { DATABASE_TRANSPORT: "direct-tls" }, { DATABASE_URL: environment.DATABASE_URL.replace("nextstop_app", "nextstop_worker") },
    { DATABASE_URL: environment.DATABASE_URL + "?host=private" }]) {
    let started = false;
    await assert.rejects(runCloudMigrations({ ...environment, ...change }, () => { started = true; return Promise.resolve(); }));
    assert.equal(started, false);
  }
});

void test("actual migration entrypoint emits only fixed diagnostic metadata on configuration failure", () => {
  const result = spawnSync(process.execPath, ["--import", "tsx", "src/jobs/cloud-migrate.ts"], {
    cwd: new URL("../..", import.meta.url), encoding: "utf8", timeout: 10_000,
    env: { ...process.env, ...environment, NODE_OPTIONS: "", DATABASE_URL: "postgres://private:secret@remote/nextstop" },
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr.trim(), '{"event":"cloud_migration_failed","phase":"configuration"}');
});
