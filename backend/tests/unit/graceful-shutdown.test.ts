import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";

import { drainHTTPApplication } from "../../src/runtime/graceful-shutdown.js";

void test("HTTP drain completes accepted requests before closing database resources", async () => {
  const app = Fastify();
  let releaseRequest: () => void = () => undefined;
  const waiting = new Promise<void>((resolve) => { releaseRequest = resolve; });
  let reportStarted: () => void = () => undefined;
  const started = new Promise<void>((resolve) => { reportStarted = resolve; });
  const order: string[] = [];
  app.get("/in-flight", async () => {
    reportStarted();
    await waiting;
    order.push("response");
    return { ok: true };
  });
  app.addHook("onClose", (_instance, done) => { order.push("pool-close"); done(); });
  const response = app.inject({ method: "GET", url: "/in-flight" });
  await started;
  const draining = drainHTTPApplication(app);
  assert.deepEqual(order, []);
  releaseRequest();
  assert.equal((await response).statusCode, 200);
  await draining;
  assert.deepEqual(order, ["response", "pool-close"]);
});
