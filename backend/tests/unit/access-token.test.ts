import assert from "node:assert/strict";
import test from "node:test";

import {
  AccessTokenAuthenticator,
  AccessTokenCodec,
} from "../../src/api/access-token.js";
import { mintDevelopmentAccessToken } from "../../src/jobs/mint-development-access-token.js";

const signingKey = "unit-test-search-access-token-key-00000000000000000001";
const otherSigningKey = "unit-test-other-access-token-key-00000000000000000002";
const tokenId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

void test("issues a strict 15-minute search token and rejects tampering or expiry", () => {
  let now = new Date("2026-08-21T12:00:00.000Z");
  const codec = new AccessTokenCodec(signingKey, {
    now: () => now,
    makeTokenId: () => tokenId,
  });
  const issued = codec.issue();

  assert.deepEqual(
    { tokenType: issued.tokenType, expiresInSeconds: issued.expiresInSeconds },
    { tokenType: "Bearer", expiresInSeconds: 900 },
  );
  assert.equal(codec.verify(issued.accessToken), true);
  assert.equal(new AccessTokenCodec(otherSigningKey, { now: () => now }).verify(issued.accessToken), false);
  assert.equal(codec.verify(`${issued.accessToken.slice(0, -1)}x`), false);
  assert.equal(codec.verify(`${issued.accessToken}.extra`), false);

  const payload = decodePayload(issued.accessToken);
  assert.deepEqual(payload, {
    iss: "https://api.nextstop.tech",
    aud: "nextstop-search",
    iat: 1_787_313_600,
    nbf: 1_787_313_600,
    exp: 1_787_314_500,
    jti: tokenId,
  });

  now = new Date("2026-08-21T12:15:00.000Z");
  assert.equal(codec.verify(issued.accessToken), false);
});

void test("bearer authenticator accepts only a canonical signed token", () => {
  const codec = new AccessTokenCodec(signingKey, {
    now: () => new Date("2026-08-21T12:00:00.000Z"),
    makeTokenId: () => tokenId,
  });
  const authenticator = new AccessTokenAuthenticator(codec);
  const token = codec.issue().accessToken;

  assert.equal(authenticator.isAuthorized(`Bearer ${token}`), true);
  assert.equal(authenticator.isAuthorized(`bearer ${token}`), true);
  assert.equal(authenticator.isAuthorized(`Bearer ${token} `), false);
  assert.equal(authenticator.isAuthorized(undefined), false);
});

void test("development mint output is machine-readable and explicitly simulator-scoped", () => {
  const output = mintDevelopmentAccessToken(signingKey);
  const parsed = JSON.parse(output) as {
    readonly accessToken: string;
    readonly tokenType: string;
    readonly expiresInSeconds: number;
  };

  assert.equal(parsed.tokenType, "Bearer");
  assert.equal(parsed.expiresInSeconds, 900);
  assert.equal(decodePayload(parsed.accessToken).client, "simulator");
  assert.equal(decodePayload(parsed.accessToken).environment, "development");
  assert.equal(new AccessTokenCodec(signingKey).verify(parsed.accessToken), true);
});

void test("access-token signing keys fail closed when too short", () => {
  assert.throws(() => new AccessTokenCodec("short"), /at least 32 bytes/u);
});

function decodePayload(token: string): Record<string, unknown> {
  const encoded = token.split(".")[1];
  assert.ok(encoded);
  return JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as Record<
    string,
    unknown
  >;
}
