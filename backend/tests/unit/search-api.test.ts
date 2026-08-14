import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import type { CandidateSearching } from "../../src/application/candidate-search.js";
import { createApp } from "../../src/api/app.js";
import type { SearchRequest, SearchResponse } from "../../src/domain/candidate-search.js";

const validRequest = {
  requestId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
  route: {
    type: "LineString",
    coordinates: [
      [11.5756, 48.1372],
      [13.3694, 52.5251],
    ],
  },
  criteria: {
    distanceRangeMeters: { minimum: 50_000, maximum: 100_000 },
    minimumChargingPoints: 4,
    minimumAvailablePoints: null,
    minimumPowerKW: 100,
    foodChain: null,
  },
} as const satisfies SearchRequest;

const emptyResponse: SearchResponse = {
  snapshotToken: "snapshot-1",
  nextCursor: null,
  generatedAt: "2026-08-14T08:00:00.000Z",
  candidates: [],
  coverage: {
    status: "complete",
    activeSources: ["bundesnetzagentur"],
    unavailableSources: [],
    projectionUpdatedAt: "2026-08-14T07:30:00.000Z",
  },
};

void test("valid request reaches the candidate-search application port", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    payload: validRequest,
  });

  assert.equal(response.statusCode, 200);
  assert.equal(candidateSearch.requests.length, 1);
  assert.deepEqual(candidateSearch.requests[0], validRequest);
  assert.deepEqual(response.json(), emptyResponse);
});

void test("profile and destination fields are rejected instead of stripped", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch, makeErrorId: randomUUID });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
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

void test("degenerate route is rejected by semantic validation", async (context) => {
  const candidateSearch = new CandidateSearchStub(emptyResponse);
  const app = createApp({ candidateSearch });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
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
  });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/charging-parks/search",
    payload: validRequest,
  });

  assert.equal(response.statusCode, 503);
  assert.match(response.body, /Charging data unavailable/u);
  assert.match(response.body, /aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/u);
});

class CandidateSearchStub implements CandidateSearching {
  readonly requests: SearchRequest[] = [];

  constructor(private readonly response: SearchResponse) {}

  search(request: SearchRequest): Promise<SearchResponse> {
    this.requests.push(request);
    return Promise.resolve(this.response);
  }
}
