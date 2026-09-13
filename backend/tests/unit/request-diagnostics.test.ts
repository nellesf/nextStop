import assert from "node:assert/strict";
import test from "node:test";

import { createApp } from "../../src/api/app.js";
import { createAuthApp } from "../../src/api/auth-app.js";
import type {
  DiagnosticErrorCategory,
  RequestDiagnostic,
  RequestDiagnosticOptions,
} from "../../src/api/request-diagnostics.js";
import {
  AppAttestAuthenticationRejectedError,
  AppAttestCounterConflictError,
  AppAttestKeyNotRegisteredError,
  type AppAttestAuthenticating,
} from "../../src/application/app-attest-authentication.js";
import {
  FoodPOIDataUnavailableError,
  NoProjectionAvailableError,
} from "../../src/application/candidate-search.js";
import { InvalidPaginationTokenError } from "../../src/application/signed-pagination.js";
import type { SearchRequest, SearchResponse } from "../../src/domain/candidate-search.js";

const sentinel = "PRIVATE_SENTINEL_DO_NOT_LOG";
const incomingRequestId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const serverRequestId = "11111111-2222-4333-8444-555555555555";
const instant = "2026-09-11T06:49:15.000Z";
const allowed = { isAuthorized: () => true };
const validRequest = {
  requestId: incomingRequestId,
  route: {
    type: "LineString",
    coordinates: [[11.47072, 49.66416], [11.7, 50.5]],
  },
  criteria: {
    distanceRangeMeters: { minimum: 100_000, maximum: 150_000 },
    minimumChargingPoints: 8,
    minimumPowerKW: 200,
    foodChain: null,
  },
  page: { snapshotToken: sentinel, cursor: sentinel },
} as const satisfies SearchRequest;
const emptyResponse: SearchResponse = {
  snapshotToken: sentinel,
  nextCursor: null,
  generatedAt: instant,
  candidates: [],
  attributions: [],
  coverage: {
    status: "complete",
    activeSources: [sentinel],
    unavailableSources: [],
    projectionUpdatedAt: instant,
  },
};

void test("completion logs contain only allowlisted fields and a server-generated correlation ID", async (context) => {
  const capture = diagnosticCapture();
  const app = createApp({
    candidateSearch: { search: () => Promise.resolve(emptyResponse) },
    searchAuthenticator: allowed,
    makeRequestId: () => serverRequestId,
    diagnostics: capture.options,
  });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: `/v1/charging-parks/search?destination=${sentinel}`,
    remoteAddress: "192.0.2.179",
    headers: {
      authorization: `Bearer ${sentinel}`,
      cookie: sentinel,
      "user-agent": sentinel,
      "request-id": incomingRequestId,
      "x-request-id": incomingRequestId,
      "x-forwarded-for": "192.0.2.180",
    },
    payload: validRequest,
  });

  assert.equal(response.statusCode, 200);
  assert.equal(response.headers["x-request-id"], serverRequestId);
  assert.deepEqual(capture.records, [{
    event: "http_request_completed",
    timestamp: instant,
    service: "candidate_api",
    route: "charging_park_search",
    requestId: serverRequestId,
    status: 200,
    durationMs: 13,
    errorCategory: "none",
  }]);
  assertPrivateValuesAbsent(capture.records);
});

void test("every completed request receives a fresh UUID even with a supplied header", async (context) => {
  const capture = diagnosticCapture();
  const app = createApp({ diagnostics: capture.options });
  context.after(async () => app.close());
  const first = await app.inject({ method: "GET", url: "/health", headers: { "x-request-id": incomingRequestId } });
  const second = await app.inject({ method: "GET", url: "/health", headers: { "x-request-id": incomingRequestId } });

  assert.notEqual(first.headers["x-request-id"], incomingRequestId);
  assert.notEqual(first.headers["x-request-id"], second.headers["x-request-id"]);
  for (const record of capture.records) {
    assert.match(record.requestId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u);
  }
});

void test("malformed, rejected, oversized, and unknown routes never expose input", async (context) => {
  const capture = diagnosticCapture();
  const app = createApp({ searchAuthenticator: allowed, diagnostics: capture.options });
  context.after(async () => app.close());
  const invalid = await app.inject({
    method: "POST", url: "/v1/charging-parks/search",
    payload: { ...validRequest, destinationText: sentinel },
  });
  const malformed = await app.inject({
    method: "POST", url: "/v1/charging-parks/search",
    headers: { "content-type": "application/json" }, payload: `{${sentinel}`,
  });
  const oversized = await app.inject({
    method: "POST", url: "/v1/charging-parks/search",
    payload: { privateData: sentinel.repeat(25_000) },
  });
  const unknown = await app.inject({ method: "GET", url: `/${sentinel}?route=${sentinel}` });

  assert.equal(invalid.statusCode, 400);
  assert.equal(malformed.statusCode, 500, "Diagnostics preserve existing malformed-JSON status behavior");
  assert.equal(oversized.statusCode, 413);
  assert.equal(unknown.statusCode, 404);
  assert.deepEqual(capture.records.map((record) => record.errorCategory), [
    "invalid_request", "invalid_request", "body_too_large", "not_found",
  ]);
  assert.equal(capture.records.at(-1)?.route, "unknown");
  assertPrivateValuesAbsent(capture.records);
});

void test("search and database failures log only fixed categories", async (context) => {
  const failures: readonly [Error, number, DiagnosticErrorCategory][] = [
    [new NoProjectionAvailableError(), 503, "projection_unavailable"],
    [new FoodPOIDataUnavailableError(), 503, "food_projection_unavailable"],
    [new InvalidPaginationTokenError(), 409, "snapshot_invalid"],
    [Object.assign(new Error(sentinel), { code: "57014", detail: sentinel, query: sentinel }), 500, "database_query_canceled"],
    [Object.assign(new Error(sentinel), { code: "08006" }), 500, "database_connection"],
    [Object.assign(new Error(sentinel), { code: "57P01" }), 500, "database_connection"],
    [Object.assign(new Error(sentinel), { code: "53300" }), 500, "database_capacity"],
    [Object.assign(new Error(sentinel), { code: "ECONNRESET" }), 500, "dependency_connection"],
    [new Error("Query read timeout"), 500, "database_timeout"],
    [Object.assign(new Error(sentinel), { code: sentinel, stack: sentinel }), 500, "unexpected"],
  ];
  for (const [error, status, category] of failures) {
    const capture = diagnosticCapture();
    const app = createApp({
      candidateSearch: { search: () => Promise.reject(error) },
      searchAuthenticator: allowed,
      diagnostics: capture.options,
    });
    context.after(async () => app.close());
    const response = await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: validRequest });
    assert.equal(response.statusCode, status);
    assert.equal(capture.records[0]?.errorCategory, category);
    assertPrivateValuesAbsent(capture.records);
  }
});

void test("unauthorized and capacity responses are logged without credentials or request contents", async (context) => {
  const capture = diagnosticCapture();
  const denied = createApp({ diagnostics: capture.options });
  context.after(async () => denied.close());
  const unauthorized = await denied.inject({
    method: "POST", url: "/v1/charging-parks/search",
    headers: { authorization: `Bearer ${sentinel}` }, payload: validRequest,
  });
  assert.equal(unauthorized.statusCode, 401);
  assert.equal(capture.records[0]?.errorCategory, "unauthorized");

  let release: ((response: SearchResponse) => void) | undefined;
  let started: (() => void) | undefined;
  const startedPromise = new Promise<void>((resolve) => { started = resolve; });
  const app = createApp({
    searchAuthenticator: allowed,
    maximumConcurrentSearches: 1,
    diagnostics: capture.options,
    candidateSearch: { search: () => new Promise((resolve) => { release = resolve; started?.(); }) },
  });
  context.after(async () => app.close());
  const first = app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: validRequest }).then((response) => response);
  await startedPromise;
  const capacity = await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: validRequest });
  assert.equal(capacity.statusCode, 429);
  assert.equal(capture.records.at(-1)?.errorCategory, "capacity_limited");
  release?.(emptyResponse);
  assert.equal((await first).statusCode, 200);
  assert.equal(capture.records.at(-1)?.errorCategory, "none");
  assertPrivateValuesAbsent(capture.records);
});

void test("App Attest logs preserve outcomes without key IDs, challenges, proofs, or issued tokens", async (context) => {
  const capture = diagnosticCapture();
  const keyId = Buffer.alloc(32, 6).toString("base64");
  const proof = Buffer.from(sentinel).toString("base64");
  let failure: Error | undefined;
  const authentication: AppAttestAuthenticating = {
    createChallenge: () => Promise.resolve({ challengeId: incomingRequestId, clientData: sentinel, expiresAt: instant }),
    attest: () => Promise.resolve({ accessToken: sentinel, tokenType: "Bearer", expiresInSeconds: 900 }),
    assert: () => failure === undefined
      ? Promise.resolve({ accessToken: sentinel, tokenType: "Bearer", expiresInSeconds: 900 })
      : Promise.reject(failure),
  };
  const app = createAuthApp({ appAttestAuthentication: authentication, diagnostics: capture.options });
  context.after(async () => app.close());
  const payload = { keyId, challengeId: incomingRequestId, assertionObject: proof };
  const success = await app.inject({ method: "POST", url: "/v1/auth/app-attest/assert", payload });
  assert.equal(success.statusCode, 200);
  const cases: readonly [Error, number, DiagnosticErrorCategory][] = [
    [new AppAttestAuthenticationRejectedError(), 401, "unauthorized"],
    [new AppAttestKeyNotRegisteredError(), 404, "app_attest_key_missing"],
    [new AppAttestCounterConflictError(), 409, "app_attest_counter_conflict"],
    [Object.assign(new Error(sentinel), { code: "57014" }), 500, "database_query_canceled"],
  ];
  for (const [error, status, category] of cases) {
    failure = error;
    const response = await app.inject({ method: "POST", url: "/v1/auth/app-attest/assert", payload });
    assert.equal(response.statusCode, status);
    assert.equal(capture.records.at(-1)?.errorCategory, category);
  }
  assert.ok(capture.records.every((record) => record.service === "auth_api" && record.route === "app_attest_assertion"));
  assertPrivateValuesAbsent(capture.records, [keyId, proof]);
});

void test("authentication rate limits and missing configuration have safe completion categories", async (context) => {
  const capture = diagnosticCapture();
  const unavailable = createAuthApp({ diagnostics: capture.options });
  const limited = createAuthApp({
    diagnostics: capture.options,
    maximumGlobalChallengesPerMinute: 1,
    appAttestAuthentication: {
      createChallenge: () => Promise.resolve({ challengeId: incomingRequestId, clientData: Buffer.alloc(32, 8).toString("base64url"), expiresAt: instant }),
      attest: () => Promise.reject(new Error(sentinel)),
      assert: () => Promise.reject(new Error(sentinel)),
    },
  });
  context.after(async () => { await unavailable.close(); await limited.close(); });
  const payload = { keyId: Buffer.alloc(32, 7).toString("base64"), purpose: "assertion" };
  const missing = await unavailable.inject({ method: "POST", url: "/v1/auth/app-attest/challenge", payload });
  assert.equal(missing.statusCode, 503);
  const first = await limited.inject({ method: "POST", url: "/v1/auth/app-attest/challenge", payload });
  assert.equal(first.statusCode, 200);
  const capacity = await limited.inject({ method: "POST", url: "/v1/auth/app-attest/challenge", payload });
  assert.equal(capacity.statusCode, 429);
  assert.deepEqual(capture.records.map((record) => record.errorCategory), ["unavailable", "none", "capacity_limited"]);
  assertPrivateValuesAbsent(capture.records);
});

void test("diagnostic sink failures cannot replace a successful response", async (context) => {
  const app = createApp({ diagnostics: { sink: () => { throw new Error(sentinel); } } });
  context.after(async () => app.close());
  assert.equal((await app.inject({ method: "GET", url: "/health" })).statusCode, 200);
});

function diagnosticCapture(): { records: RequestDiagnostic[]; options: RequestDiagnosticOptions } {
  const records: RequestDiagnostic[] = [];
  let monotonic = 0;
  return {
    records,
    options: {
      sink: (record) => { records.push(record); },
      now: () => new Date(instant),
      monotonicMilliseconds: () => { monotonic += 12.6; return monotonic; },
    },
  };
}

function assertPrivateValuesAbsent(records: readonly RequestDiagnostic[], extra: readonly string[] = []): void {
  const output = JSON.stringify(records);
  for (const value of [sentinel, incomingRequestId, "49.66416", "11.47072", "192.0.2.179", "192.0.2.180", ...extra]) {
    assert.equal(output.includes(value), false, `Sensitive sentinel appeared in a diagnostic: ${value}`);
  }
}
