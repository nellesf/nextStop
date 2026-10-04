import assert from "node:assert/strict";
import test from "node:test";
import { AvailabilityContextCodec, CandidateAvailability, HTTPRefreshSignal, InvalidAvailabilityContextError,
  type AvailabilityContext, type AvailabilityRequest, type AvailabilityResponse } from "../../src/application/candidate-availability.js";
import { createApp } from "../../src/api/app.js";
import { DemandLiveRefresh, createLiveRefreshApp } from "../../src/jobs/demand-live-refresh.js";
import type { LiveRefreshLease } from "../../src/persistence/live-refresh-control.js";

const now = new Date("2026-10-04T10:00:00Z");
const secret = "unit-test-only-signing-key-at-least-32-bytes";
const bearer = "unit-test-only-bearer-key-at-least-32-bytes";
const codec = new AvailabilityContextCodec(secret);
const context: AvailabilityContext = { projectionId: "10000000-0000-4000-8000-000000000001",
  candidateKind: "campus", minimumPowerKW: 150, expiresAt: now.getTime() + 3_600_000 };
const request: AvailabilityRequest = { context: codec.encode(context), candidates: [
  { id: "20000000-0000-4000-8000-000000000002", operatorNames: ["Visible Operator"] },
] };
const response: AvailabilityResponse = { context: request.context, generatedAt: now.toISOString(),
  expiresAt: new Date(context.expiresAt).toISOString(), refreshPending: false,
  candidates: request.candidates.map((candidate) => ({ ...candidate,
    availability: { knownAvailable: 0, knownUnavailable: 0, unknown: 2, total: 2, complete: false } })) };

void test("availability context binds projection, power, kind, purpose and one-hour lifetime", () => {
  assert.deepEqual(codec.decode(request.context, now), context);
  assert.throws(() => codec.decode(`${request.context}tampered`, now), InvalidAvailabilityContextError);
  assert.throws(() => codec.decode(request.context, new Date(context.expiresAt)), InvalidAvailabilityContextError);
  assert.throws(() => codec.decode(codec.encode({ ...context, expiresAt: now.getTime() + 3_600_001 }), now), InvalidAvailabilityContextError);
  assert.throws(() => codec.decode(codec.encode({ ...context, candidateKind: "park" }).replace(/.$/u, "!"), now), InvalidAvailabilityContextError);
  assert.throws(() => new AvailabilityContextCodec("short"));
  assert.doesNotMatch(Buffer.from(request.context.split(".")[0] ?? "", "base64url").toString(), /route|latitude|longitude|user|profile/u);
});

void test("DE-only and fresh cache never signal; cold Swiss cache signals separately and tolerates outage", async () => { await Promise.resolve();
  let signals = 0;
  let needsSwissRefresh = false;
  const reader = new CandidateAvailability(codec, { read: () => Promise.resolve({ candidates: response.candidates, needsSwissRefresh }) },
    { signal: async () => { await Promise.resolve(); signals += 1; return true; } }, () => now);
  assert.equal((await reader.read(request)).refreshPending, false);
  assert.equal(signals, 0);
  needsSwissRefresh = true;
  const pending = await reader.read(request);
  assert.equal(pending.refreshPending, true);
  assert.equal(pending.retryAfterSeconds, 2);
  assert.deepEqual(pending.candidates, response.candidates);
  assert.equal(signals, 1);
  const offline = new CandidateAvailability(codec, { read: () => Promise.resolve({ candidates: response.candidates, needsSwissRefresh: true }) },
    { signal: async () => { await Promise.resolve(); throw new Error("private URL and credential must never escape"); } }, () => now);
  assert.deepEqual(await offline.read(request), response);
  await assert.rejects(reader.read({ ...request, candidates: [...request.candidates, ...request.candidates] }), InvalidAvailabilityContextError);
});

void test("private refresh client has a fixed Docker destination, only provider body and bounded request", async () => { await Promise.resolve();
  let calls = 0;
  const signal = new HTTPRefreshSignal("http://worker:8091/refresh", secret, async (url, options) => { await Promise.resolve();
    calls += 1;
    assert.equal(url, "http://worker:8091/refresh");
    assert.equal(options?.body, '{"providerId":"ich_tanke_strom"}');
    assert.equal(options?.redirect, "error");
    assert.ok(options?.signal);
    return new Response(null, { status: 202 });
  });
  assert.equal(await signal.signal(), true);
  assert.equal(calls, 1);
  for (const url of ["https://example.com/refresh", "http://worker:8091/refresh?token=x", "http://worker:8091/private", "http://user:secret@worker:8091/refresh"]) {
    assert.throws(() => new HTTPRefreshSignal(url, secret));
  }
});

void test("availability endpoint authenticates, rejects private fields and bounds body/selection", async (t) => {
  let calls = 0;
  const app = createApp({ searchBearerToken: bearer, candidateAvailability: { read: async () => { await Promise.resolve(); calls += 1; return response; } } });
  t.after(() => app.close());
  const send = (payload: object, authorized = true) => app.inject({ method: "POST", url: "/v1/charging-parks/availability",
    headers: authorized ? { authorization: `Bearer ${bearer}` } : {}, payload });
  assert.equal((await send(request, false)).statusCode, 401);
  assert.equal((await send({ ...request, route: { private: true } })).statusCode, 400);
  assert.equal((await send({ ...request, candidates: Array.from({ length: 51 }, () => request.candidates[0]) })).statusCode, 400);
  assert.equal((await send({ ...request, context: "x".repeat(270_000) })).statusCode, 413);
  assert.equal(calls, 0);
  const valid = await send(request);
  assert.equal(valid.statusCode, 200);
  assert.equal(valid.headers["cache-control"], "no-store");
  assert.deepEqual(valid.json(), response);
  assert.equal(calls, 1);
});

void test("availability has bounded admission independent of search and redacts failed context/database details", async (t) => {
  let resolve: (() => void) | undefined;
  const waiting = new Promise<void>((done) => { resolve = done; });
  let active = 0;
  const app = createApp({ searchBearerToken: bearer, candidateAvailability: { read: async () => { await Promise.resolve(); active += 1; await waiting; return response; } } });
  t.after(() => app.close());
  const send = () => app.inject({ method: "POST", url: "/v1/charging-parks/availability", headers: { authorization: `Bearer ${bearer}` }, payload: request });
  const first = send(), second = send();
  while (active !== 2) await new Promise((done) => setImmediate(done));
  assert.equal((await send()).statusCode, 429);
  resolve?.();
  assert.deepEqual((await Promise.all([first, second])).map(({ statusCode }) => statusCode), [200, 200]);
  for (const [error, status] of [[new InvalidAvailabilityContextError(), 409], [new Error("secret SQL route credential"), 503]] as const) {
    const failed = createApp({ searchBearerToken: bearer, candidateAvailability: { read: async () => { await Promise.resolve(); throw error; } } });
    const result = await failed.inject({ method: "POST", url: "/v1/charging-parks/availability", headers: { authorization: `Bearer ${bearer}` }, payload: request });
    assert.equal(result.statusCode, status);
    assert.doesNotMatch(result.body, /secret SQL route credential/u);
    await failed.close();
  }
});

void test("worker demand acknowledges before download finishes and coalesces concurrent requests", async (t) => {
  let finish: (() => void) | undefined;
  const blocked = new Promise<void>((done) => { finish = done; });
  let acquisitions = 0, downloads = 0, releases = 0;
  const lease: LiveRefreshLease = { providerId: "ich_tanke_strom", owner: "10000000-0000-4000-8000-000000000003" };
  const controller = new DemandLiveRefresh({ acquire: async () => { await Promise.resolve(); acquisitions += 1; return { lease, pending: true }; },
    finish: async (_lease, success) => { await Promise.resolve(); assert.equal(success, true); releases += 1; } }, async () => { await Promise.resolve(); downloads += 1; await blocked; });
  const app = createLiveRefreshApp(controller, secret);
  t.after(() => app.close());
  const send = (payload: object, authorized = true) => app.inject({ method: "POST", url: "/refresh", payload,
    headers: authorized ? { authorization: `Bearer ${secret}` } : {} });
  assert.equal((await send({ providerId: "ich_tanke_strom" }, false)).statusCode, 401);
  assert.equal((await send({ providerId: "ich_tanke_strom", route: "private" })).statusCode, 400);
  assert.equal(downloads, 0);
  assert.equal((await send({ providerId: "ich_tanke_strom" })).statusCode, 202);
  assert.equal((await send({ providerId: "ich_tanke_strom" })).statusCode, 202);
  assert.equal(acquisitions, 1); assert.equal(downloads, 1); assert.equal(releases, 0);
  finish?.(); await controller.stop();
  assert.equal(releases, 1);
  assert.equal((await send({ providerId: "ich_tanke_strom" })).statusCode, 204);
});

void test("failed worker refresh records cooldown and cannot turn failure into unhandled rejection", async () => { await Promise.resolve();
  let failed = false, finished = false;
  const lease: LiveRefreshLease = { providerId: "ich_tanke_strom", owner: "10000000-0000-4000-8000-000000000003" };
  const controller = new DemandLiveRefresh({ acquire: () => Promise.resolve({ lease, pending: true }),
    finish: async (_lease, success) => { await Promise.resolve(); assert.equal(success, false); finished = true; } },
  async () => { await Promise.resolve(); throw new Error("upstream secret data"); }, () => { failed = true; });
  assert.equal(await controller.request(), true);
  await controller.stop();
  assert.equal(failed, true); assert.equal(finished, true);
});

void test("availability completion diagnostics expose only route classification, status and timing", async (t) => {
  const logs: unknown[] = [];
  const app = createApp({ searchBearerToken: bearer, diagnostics: { sink: (value) => { logs.push(value); } },
    candidateAvailability: { read: () => Promise.resolve(response) } });
  t.after(() => app.close());
  const result = await app.inject({ method: "POST", url: "/v1/charging-parks/availability",
    headers: { authorization: `Bearer ${bearer}` }, payload: request });
  assert.equal(result.statusCode, 200);
  const output = JSON.stringify(logs);
  assert.match(output, /charging_park_availability/u);
  for (const privateValue of [bearer, request.context, request.candidates[0]?.id, "Visible Operator"]) {
    if (privateValue !== undefined) assert.equal(output.includes(privateValue), false);
  }
});
