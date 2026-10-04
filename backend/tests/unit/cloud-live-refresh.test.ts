import assert from "node:assert/strict";
import test from "node:test";
import { CloudTasksRefreshSignal, cloudLiveRefreshConfiguration, cloudLiveRefreshLimits,
  type LiveTaskCreating } from "../../src/application/cloud-tasks-refresh-signal.js";
import { CloudLiveRefresh, createCloudLiveRefreshApp, GoogleTaskAuthenticator } from "../../src/jobs/cloud-live-refresh.js";
import type { LiveRefreshLease, LiveRefreshLeasing } from "../../src/persistence/live-refresh-control.js";

const environment = {
  LIVE_REFRESH_TASK_QUEUE: "projects/nextstop-testing/locations/europe-west3/queues/swiss-live",
  LIVE_REFRESH_TASK_TARGET: "https://nextstop-live-test-ew.a.run.app/refresh",
  LIVE_REFRESH_TASK_SERVICE_ACCOUNT: "nextstop-task@nextstop-testing.iam.gserviceaccount.com",
};
const configuration = cloudLiveRefreshConfiguration(environment);
const lease: LiveRefreshLease = { providerId: "ich_tanke_strom", owner: "10000000-0000-4000-8000-000000000003" };
const authorized = { isAuthorized: () => Promise.resolve(true) };
const payload = { providerId: "ich_tanke_strom" };

void test("cloud task destination is fixed HTTPS, and invoker/queue must share their configured project", () => {
  assert.equal(configuration.audience, "https://nextstop-live-test-ew.a.run.app");
  for (const target of ["http://nextstop-live-test-ew.a.run.app/refresh", "https://example.org/refresh",
    "https://user:secret@nextstop-live-test-ew.a.run.app/refresh", `${configuration.target}?url=private`,
    `${configuration.target}#secret`, "https://nextstop-live-test-ew.a.run.app/search"]) {
    assert.throws(() => cloudLiveRefreshConfiguration({ ...environment, LIVE_REFRESH_TASK_TARGET: target }));
  }
  assert.throws(() => cloudLiveRefreshConfiguration({ ...environment, LIVE_REFRESH_TASK_SERVICE_ACCOUNT: "nextstop-task@other-project.iam.gserviceaccount.com" }));
  assert.throws(() => cloudLiveRefreshConfiguration({ ...environment, LIVE_REFRESH_TASK_QUEUE: `${configuration.queue}/../other` }));
});

void test("separate API instances enqueue identical provider-only tasks in a minute, with IAM audience and finite dispatch", async () => {
  const requests: Parameters<LiveTaskCreating["createTask"]>[0][] = [];
  let closed = 0;
  const client: LiveTaskCreating = {
    createTask: (request, options) => {
      assert.deepEqual(options, { timeout: 1_000, retry: null });
      requests.push(request); return Promise.resolve({});
    },
    close: () => { closed += 1; return Promise.resolve(); },
  };
  const now = Date.parse("2026-10-04T10:00:00Z");
  const first = new CloudTasksRefreshSignal(configuration, client, () => now);
  assert.equal(await first.signal(), true);
  assert.equal(await new CloudTasksRefreshSignal(configuration, client, () => now + 59_999).signal(), true);
  assert.equal(await new CloudTasksRefreshSignal(configuration, client, () => now + 60_000).signal(), true);
  assert.equal(requests[0]?.task?.name, requests[1]?.task?.name);
  assert.notEqual(requests[0]?.task?.name, requests[2]?.task?.name);
  for (const request of requests) {
    assert.equal(request.parent, configuration.queue);
    assert.equal(request.responseView, "BASIC");
    assert.match(request.task?.name ?? "", /\/tasks\/[a-f0-9]{64}$/u);
    const http = request.task?.httpRequest;
    assert.ok(http);
    assert.equal(http.url, configuration.target);
    assert.equal(http.httpMethod, "POST");
    assert.deepEqual(http.oidcToken, { serviceAccountEmail: configuration.serviceAccount, audience: configuration.audience });
    assert.ok(Buffer.isBuffer(http.body));
    assert.deepEqual(JSON.parse(http.body.toString()), payload);
    assert.deepEqual(request.task?.dispatchDeadline, { seconds: 300 });
    assert.doesNotMatch(http.body.toString(), /candidate|route|profile|key|token|operator/u);
  }
  await first.close(); assert.equal(closed, 1);
});

void test("only ALREADY_EXISTS counts as accepted; credential/permission/provider errors remain private", async () => {
  for (const [code, expected] of [[6, true], [7, false], [8, false], [14, false]] as const) {
    const signal = new CloudTasksRefreshSignal(configuration, {
      createTask: () => Promise.reject(Object.assign(new Error("private credential and task body"), { code })), close: () => Promise.resolve(),
    });
    assert.equal(await signal.signal(), expected);
  }
});

void test("enqueue has an overall deadline even when lazy client initialization never completes", async () => {
  let cancelled = false;
  const waiting = Object.assign(new Promise<never>(() => {}), { cancel: () => { cancelled = true; } });
  const signal = new CloudTasksRefreshSignal(configuration, { createTask: () => waiting, close: () => Promise.resolve() });
  const started = performance.now();
  assert.equal(await signal.signal(), false);
  assert.equal(cancelled, true);
  assert.ok(performance.now() - started < cloudLiveRefreshLimits.enqueueMilliseconds + 1_500);
});

void test("task authentication verifies exact audience and verified service identity, and fails closed", async () => {
  let calls = 0;
  const verifier = { verifyIdToken: (input: { idToken: string; audience: string }) => {
    calls += 1; assert.equal(input.idToken, "synthetic-token"); assert.equal(input.audience, configuration.audience);
    return Promise.resolve({ getPayload: () => ({ email: configuration.serviceAccount, email_verified: true }) });
  } };
  const auth = new GoogleTaskAuthenticator(configuration, verifier);
  assert.equal(await auth.isAuthorized(undefined), false);
  assert.equal(await auth.isAuthorized("Basic synthetic-token"), false);
  assert.equal(await auth.isAuthorized(`Bearer ${"x".repeat(8_192)}`), false);
  assert.equal(calls, 0);
  assert.equal(await auth.isAuthorized("Bearer synthetic-token"), true);
  assert.equal(calls, 1);
  for (const claims of [{ email: "other@example.org", email_verified: true },
    { email: configuration.serviceAccount, email_verified: false }, {}]) {
    const invalid = new GoogleTaskAuthenticator(configuration, { verifyIdToken: () => Promise.resolve({ getPayload: () => claims }) });
    assert.equal(await invalid.isAuthorized("Bearer synthetic-token"), false);
  }
  assert.equal(await new GoogleTaskAuthenticator(configuration, {
    verifyIdToken: () => Promise.reject(new Error("private verification detail")),
  }).isAuthorized("Bearer synthetic-token"), false);
});

void test("private task HTTP does not acknowledge until both provider publication and lease finish complete", async (t) => {
  const started = Promise.withResolvers<void>(), download = Promise.withResolvers<void>();
  const finishing = Promise.withResolvers<void>(), finish = Promise.withResolvers<void>();
  let acquires = 0, acknowledged = false;
  const controller = new CloudLiveRefresh({
    acquire: () => { acquires += 1; return Promise.resolve({ lease, pending: true }); },
    finish: async (actual, success) => {
      assert.deepEqual(actual, lease); assert.equal(success, true); finishing.resolve(); await finish.promise;
    },
  }, async (actual) => { assert.deepEqual(actual, lease); started.resolve(); await download.promise; });
  const app = createCloudLiveRefreshApp(controller, { isAuthorized: (header) => Promise.resolve(header === "Bearer synthetic") });
  t.after(() => app.close());
  assert.equal((await app.inject({ method: "POST", url: "/refresh", payload })).statusCode, 401);
  assert.equal((await app.inject({ method: "POST", url: "/refresh", headers: { authorization: "Bearer synthetic" },
    payload: { ...payload, route: "private" } })).statusCode, 400);
  assert.equal(acquires, 0);
  const response = app.inject({ method: "POST", url: "/refresh", headers: { authorization: "Bearer synthetic" }, payload })
    .then((result) => { acknowledged = true; return result; });
  await started.promise; assert.equal(acknowledged, false);
  download.resolve(); await finishing.promise; assert.equal(acknowledged, false);
  finish.resolve(); assert.equal((await response).statusCode, 204);
  assert.equal(acquires, 1);
});

void test("busy/crashed worker leases and failed-attempt cooldown remain retryable; successful cooldown needs no download", async (t) => {
  let downloads = 0;
  for (const [claim, status] of [
    [{ pending: true }, 503], [{ pending: false, retryable: true }, 503], [{ pending: false, retryable: false }, 204],
  ] as const) {
    const control: LiveRefreshLeasing = { acquire: () => Promise.resolve(claim), finish: () => Promise.resolve() };
    const app = createCloudLiveRefreshApp(new CloudLiveRefresh(control, () => { downloads += 1; return Promise.resolve(); }), authorized);
    t.after(() => app.close());
    const response = await app.inject({ method: "POST", url: "/refresh", payload });
    assert.equal(response.statusCode, status);
    if (status === 503) assert.equal(response.headers["retry-after"], "60");
  }
  assert.equal(downloads, 0);
});

void test("publication/fencing failure and failed lease cleanup never acknowledge a task or disclose error details", async (t) => {
  for (const failPublish of [true, false]) {
    let failures = 0, finishes = 0;
    const app = createCloudLiveRefreshApp(new CloudLiveRefresh({
      acquire: () => Promise.resolve({ lease, pending: true }),
      finish: (_lease, success) => {
        finishes += 1; assert.equal(success, !failPublish);
        return failPublish ? Promise.resolve() : Promise.reject(new Error("private SQL connection"));
      },
    }, () => failPublish ? Promise.reject(new Error("LiveRefreshLeaseLost private SQL")) : Promise.resolve()),
    authorized, () => { failures += 1; });
    t.after(() => app.close());
    const response = await app.inject({ method: "POST", url: "/refresh", payload });
    assert.equal(response.statusCode, 503); assert.equal(finishes, 1); assert.equal(failures, 1);
    assert.doesNotMatch(response.body, /private|SQL|LeaseLost/u);
  }
});
