import assert from "node:assert/strict";
import test from "node:test";

import { createApp } from "../../src/api/app.js";
import { createAuthApp } from "../../src/api/auth-app.js";
import { AuthenticationReadiness, SearchReadiness } from "../../src/persistence/runtime-readiness.js";

for (const [name, makeApp] of [["search", createApp], ["authentication", createAuthApp]] as const) {
  void test(`${name} readiness is separate from liveness and never exposes failures`, async () => {
    const release = `sha256:${"a".repeat(64)}`;
    let state: boolean | Error = true;
    const app = makeApp({
      release,
      readiness: { isReady: () => state instanceof Error ? Promise.reject(state) : Promise.resolve(state) },
    });
    try {
      assert.deepEqual((await app.inject({ method: "GET", url: "/ready" })).json(), { status: "ready", release });
      for (const next of [false, new Error("postgres://private:secret@database/route")]) {
        state = next;
        const response = await app.inject({ method: "GET", url: "/ready" });
        assert.equal(response.statusCode, 503);
        assert.equal(response.headers["cache-control"], "no-store");
        assert.deepEqual(response.json(), { status: "not_ready", release });
        assert.equal((await app.inject({ method: "GET", url: "/health" })).statusCode, 200);
      }
    } finally { await app.close(); }
  });
  void test(`${name} readiness fails closed when no checker is configured`, async () => {
    const app = makeApp();
    try { assert.equal((await app.inject({ method: "GET", url: "/ready" })).statusCode, 503); }
    finally { await app.close(); }
  });
  void test(`${name} refuses mutable or arbitrary release metadata`, () => {
    assert.throws(() => makeApp({ release: "latest" }), /immutable SHA-256/u);
  });
}

void test("readiness requires configuration, schema/data confirmation and a successful database read", async () => {
  let calls = 0;
  let ready = false;
  const database = { query: () => { calls += 1; return Promise.resolve({ rows: [{ ready }] }); } };
  for (const Readiness of [SearchReadiness, AuthenticationReadiness]) {
    assert.equal(await new Readiness(database, false).isReady(), false);
    assert.equal(calls, 0);
  }
  assert.equal(await new SearchReadiness(database, true).isReady(), false);
  ready = true;
  assert.equal(await new AuthenticationReadiness(database, true).isReady(), true);
  const broken = { query: () => Promise.reject(new Error("Database unavailable")) };
  await assert.rejects(new SearchReadiness(broken, true).isReady(), /Database unavailable/u);
});
