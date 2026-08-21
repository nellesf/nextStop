import assert from "node:assert/strict";
import test from "node:test";

import {
  expiryFromMintStart,
  responseWithRemainingLifetime,
} from "./token-cache.mjs";

const response = {
  accessToken: "simulator-token",
  tokenType: "Bearer",
  expiresInSeconds: 900,
};

void test("cached responses expose only their remaining whole-second lifetime", () => {
  const cachedToken = { response, expiresAt: 1_000_000 };

  assert.deepEqual(responseWithRemainingLifetime(cachedToken, 694_001), {
    ...response,
    expiresInSeconds: 305,
  });
  assert.equal(response.expiresInSeconds, 900);
});

void test("cached responses never extend the lifetime declared by the minter", () => {
  assert.deepEqual(
    responseWithRemainingLifetime(
      { response, expiresAt: 2_000_000 },
      500_000,
    ),
    response,
  );
});

void test("tokens at the refresh margin are reminted rather than served", () => {
  const cachedToken = { response, expiresAt: 1_000_000 };

  assert.equal(responseWithRemainingLifetime(cachedToken, 939_001), undefined);
  assert.equal(responseWithRemainingLifetime(cachedToken, 939_000)?.expiresInSeconds, 61);
});

void test("mint command latency is deducted from the broker's conservative expiry", () => {
  assert.equal(expiryFromMintStart(100_000, 900), 1_000_000);
});
