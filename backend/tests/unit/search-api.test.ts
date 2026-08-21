import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import {
  FoodPOIDataUnavailableError,
  type CandidateSearching,
} from "../../src/application/candidate-search.js";
import { InvalidPaginationTokenError } from "../../src/application/signed-pagination.js";
import { createApp } from "../../src/api/app.js";
import { BearerTokenAuthenticator } from "../../src/api/bearer-authentication.js";
import type { SearchRequest, SearchResponse } from "../../src/domain/candidate-search.js";

const searchBearerToken = "test-only-search-bearer-token-0000000000000001";
const authorizedHeaders = { authorization: `Bearer ${searchBearerToken}` } as const;

const validRequest = {
  requestId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
  route: {
    type: "LineString",
    coordinates: [
      [11.5756, 48.1372],
      [11.9, 49.1],
      [12.2, 50.1],
      [12.6, 51.1],
      [13.0, 52.1],
      [13.3694, 52.5251],
    ],
  },
  criteria: {
    distanceRangeMeters: { minimum: 50_000, maximum: 100_000 },
    minimumChargingPoints: 4,
    minimumPowerKW: 100,
    foodChain: null,
  },
} as const satisfies SearchRequest;

const emptyResponse: SearchResponse = {
  snapshotToken: "snapshot-1",
  nextCursor: null,
  generatedAt: "2026-08-14T08:00:00.000Z",
  candidates: [],
  attributions: [],
  coverage: {
    status: "complete",
    activeSources: ["bundesnetzagentur"],
    unavailableSources: [],
    projectionUpdatedAt: "2026-08-14T07:30:00.000Z",
  },
};

void test("valid request reaches the candidate-search application port", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: validRequest,
  });

  assert.equal(response.statusCode, 200);
  assert.equal(candidateSearch.requests.length, 1);
  assert.deepEqual(candidateSearch.requests[0], validRequest);
  assert.deepEqual(response.json(), emptyResponse);
});

void test("profile and destination fields are rejected instead of stripped", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, makeErrorId: randomUUID, searchBearerToken });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: {
      ...validRequest,
      profileName: "must stay local",
      destinationText: "must also stay local",
    },
  });

  assert.equal(response.statusCode, 400);
  assert.equal(response.headers["content-type"], "application/problem+json; charset=utf-8");
  assert.equal(candidateSearch.requests.length, 0);
  assert.doesNotMatch(response.body, /must stay local/u);
});

void test("removed availability filter is rejected instead of silently applied", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: {
      ...validRequest,
      criteria: { ...validRequest.criteria, minimumAvailablePoints: 4 },
    },
  });

  assert.equal(response.statusCode, 400);
  assert.equal(candidateSearch.requests.length, 0);
});

void test("degenerate route is rejected by semantic validation", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: {
      ...validRequest,
      route: {
        type: "LineString",
        coordinates: [
          [11.5756, 48.1372],
          [11.5756, 48.1372],
        ],
      },
    },
  });

  assert.equal(response.statusCode, 400);
  assert.equal(candidateSearch.requests.length, 0);
});

void test("missing charging projection returns an honest retryable 503", async (context) => {
  const app = createApp({
    makeErrorId: () => "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    searchBearerToken,
  });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: validRequest,
  });

  assert.equal(response.statusCode, 503);
  assert.match(response.body, /Charging data unavailable/u);
  assert.match(response.body, /aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/u);
});

void test("invalid snapshot is reported as a conflict without token details", async (context) => {
  const app = createApp({
    candidateSearch: {
      search: () => Promise.reject(new InvalidPaginationTokenError()),
    },
    makeErrorId: () => "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    searchBearerToken,
  });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: validRequest,
  });

  assert.equal(response.statusCode, 409);
  assert.match(response.body, /Invalid candidate snapshot/u);
});

void test("missing requested OSM projection is a retryable 503, not no matches", async (context) => {
  const app = createApp({
    candidateSearch: {
      search: () => Promise.reject(new FoodPOIDataUnavailableError()),
    },
    makeErrorId: () => "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    searchBearerToken,
  });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: { ...validRequest, criteria: { ...validRequest.criteria, foodChain: "mcdonalds" } },
  });

  assert.equal(response.statusCode, 503);
  assert.match(response.body, /Restaurant data unavailable/u);
});

void test("health remains public while search requires a bearer token", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  const health = await app.inject({ method: "GET", url: "/health" });
  const search = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    payload: validRequest,
  });

  assert.equal(health.statusCode, 200);
  assert.equal(search.statusCode, 401);
  assert.equal(search.headers["www-authenticate"], 'Bearer realm="nextstop-search"');
  assert.equal(candidateSearch.requests.length, 0);
});

void test("malformed and incorrect bearer credentials are rejected identically", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  for (const authorization of ["Basic abc", "Bearer wrong-token", "Bearer token with-space"]) {
    const response = await app.inject({
      method: "POST",
      url: "/v1/charging-parks/search",
      headers: { authorization },
      payload: validRequest,
    });
    assert.equal(response.statusCode, 401);
    assert.match(response.body, /Authentication required/u);
  }
  assert.equal(candidateSearch.requests.length, 0);
});

void test("server bearer credentials fail closed when unusable", () => {
  assert.throws(() => new BearerTokenAuthenticator("short"), /at least 32 bytes/u);
  assert.throws(
    () => new BearerTokenAuthenticator("valid-length-token-with-forbidden whitespace"),
    /no whitespace/u,
  );
});

void test("routes outside Europe and excessive route geometry are rejected", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  const routes: readonly SearchRequest["route"]["coordinates"][] = [
    [[-73.9857, 40.7484], [-73.98, 40.75]],
    [[11.5756, 48.1372], [15.5, 48.1372]],
    Array.from({ length: 40 }, (_, index) => [index % 2 === 0 ? 5 : 7, 50] as const),
    Array.from(
      { length: 8_001 },
      (_, index) => [11.5756 + (index % 2) * 0.0001, 48.1372] as const,
    ),
  ];
  for (const coordinates of routes) {
    const response = await app.inject({
      method: "POST",
      url: "/v1/charging-parks/search",
      headers: authorizedHeaders,
      payload: { ...validRequest, route: { type: "LineString", coordinates } },
    });
    assert.equal(response.statusCode, 400);
  }
  assert.equal(candidateSearch.requests.length, 0);
});

void test("oversized request bodies are rejected before candidate search", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, searchBearerToken });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: { ...authorizedHeaders, "content-type": "application/json" },
    payload: JSON.stringify({ ...validRequest, padding: "x".repeat(600_000) }),
  });

  assert.equal(response.statusCode, 413);
  assert.match(response.body, /Request body too large/u);
  assert.equal(candidateSearch.requests.length, 0);
});

void test("concurrent search admission returns retry metadata and releases capacity", async (context) => {
  let releaseFirst: (() => void) | undefined;
  const firstSearch = new Promise<SearchResponse>((resolve) => {
    releaseFirst = () => resolve(emptyResponse);
  });
  let invocationCount = 0;
  const app = createApp({
    candidateSearch: {
      search: () => {
        invocationCount += 1;
        return invocationCount === 1 ? firstSearch : Promise.resolve(emptyResponse);
      },
    },
    searchBearerToken,
    maximumConcurrentSearches: 1,
  });
  context.after(async () => app.close());

  const firstResponse = app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: validRequest,
  });
  await waitUntil(() => invocationCount === 1);
  const rejectedResponse = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: validRequest,
  });
  assert.equal(rejectedResponse.statusCode, 429);
  assert.equal(rejectedResponse.headers["retry-after"], "1");

  releaseFirst?.();
  assert.equal((await firstResponse).statusCode, 200);
  const afterRelease = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    headers: authorizedHeaders,
    payload: validRequest,
  });
  assert.equal(afterRelease.statusCode, 200);
});

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error("Timed out waiting for search invocation.");
}

class CandidateSearchStub implements CandidateSearching {
  readonly requests: SearchRequest[] = [];

  constructor(private readonly response: SearchResponse) {}

  search(request: SearchRequest): Promise<SearchResponse> {
    this.requests.push(request);
    return Promise.resolve(this.response);
  }
}
