import assert from "node:assert/strict";
import test from "node:test";

import { createAuthApp } from "../../src/api/auth-app.js";
import {
  AppAttestAuthenticationRejectedError,
  AppAttestCounterConflictError,
  AppAttestKeyNotRegisteredError,
  type AppAttestAuthenticating,
} from "../../src/application/app-attest-authentication.js";

const keyId = Buffer.alloc(32, 4).toString("base64");
const challengeId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const token = {
  accessToken: "signed-access-token",
  tokenType: "Bearer" as const,
  expiresInSeconds: 900,
};
void test("App Attest endpoints expose the agreed request and response contract", async (context) => {
  const authentication = new AuthenticationStub();
  const app = createAuthApp({
    appAttestAuthentication: authentication,
  });
  context.after(async () => app.close());

  const challenge = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/challenge",
    payload: { keyId, purpose: "attestation" },
  });
  assert.equal(challenge.statusCode, 200);
  assert.deepEqual(challenge.json(), {
    challengeId,
    clientData: Buffer.alloc(32, 8).toString("base64url"),
    expiresAt: "2026-08-21T12:03:00.000Z",
  });

  const attestation = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/attest",
    payload: {
      keyId,
      challengeId,
      attestationObject: Buffer.from("attestation").toString("base64"),
    },
  });
  assert.equal(attestation.statusCode, 200);
  assert.deepEqual(attestation.json(), token);

  const assertion = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/assert",
    payload: {
      keyId,
      challengeId,
      assertionObject: Buffer.from("assertion").toString("base64"),
    },
  });
  assert.equal(assertion.statusCode, 200);
  assert.deepEqual(assertion.json(), token);
});

void test("App Attest is fail-closed with an explicit 503 when not configured", async (context) => {
  const app = createAuthApp();
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/challenge",
    payload: { keyId, purpose: "assertion" },
  });

  assert.equal(response.statusCode, 503);
  assert.match(response.body, /not configured/u);
});

void test("invalid proofs are rejected generically without cryptographic detail", async (context) => {
  const authentication = new AuthenticationStub();
  authentication.assertionError = new AppAttestAuthenticationRejectedError();
  const app = createAuthApp({
    appAttestAuthentication: authentication,
    makeErrorId: () => challengeId,
  });
  context.after(async () => app.close());

  const response = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/assert",
    payload: {
      keyId,
      challengeId,
      assertionObject: Buffer.from("assertion").toString("base64"),
    },
  });

  assert.equal(response.statusCode, 401);
  assert.equal(response.headers["www-authenticate"], 'Bearer realm="nextstop-attestation"');
  assert.doesNotMatch(response.body, /signature|counter|challenge/iu);
});

void test("missing keys and counter races have actionable, distinct statuses", async (context) => {
  const authentication = new AuthenticationStub();
  const app = createAuthApp({
    appAttestAuthentication: authentication,
    makeErrorId: () => challengeId,
  });
  context.after(async () => app.close());
  const payload = {
    keyId,
    challengeId,
    assertionObject: Buffer.from("assertion").toString("base64"),
  };

  authentication.assertionError = new AppAttestKeyNotRegisteredError();
  const missing = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/assert",
    payload,
  });
  assert.equal(missing.statusCode, 404);
  assert.match(missing.body, /key-not-registered/u);

  authentication.assertionError = new AppAttestCounterConflictError();
  const conflict = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/assert",
    payload,
  });
  assert.equal(conflict.statusCode, 409);
  assert.match(conflict.body, /counter-conflict/u);
});

void test("authentication process enforces global rate and proof concurrency limits", async (context) => {
  const authentication = new AuthenticationStub();
  let releaseFirst: (() => void) | undefined;
  authentication.attestationResult = new Promise((resolve) => {
    releaseFirst = () => resolve(token);
  });
  const app = createAuthApp({
    appAttestAuthentication: authentication,
    maximumConcurrentAuthentications: 1,
    maximumGlobalChallengesPerMinute: 12,
    maximumGlobalProofsPerMinute: 6,
  });
  context.after(async () => app.close());
  const payload = {
    keyId,
    challengeId,
    attestationObject: Buffer.from("attestation").toString("base64"),
  };

  const first = app.inject({ method: "POST", url: "/v1/auth/app-attest/attest", payload });
  await waitUntil(() => authentication.attestationCalls === 1);
  const second = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/attest",
    payload,
  });
  assert.equal(second.statusCode, 429);
  releaseFirst?.();
  assert.equal((await first).statusCode, 200);

  for (let request = 0; request < 12; request += 1) {
    const allowed = await app.inject({
      method: "POST",
      url: "/v1/auth/app-attest/challenge",
      payload: { keyId, purpose: "assertion" },
    });
    assert.equal(allowed.statusCode, 200);
  }
  const limited = await app.inject({
    method: "POST",
    url: "/v1/auth/app-attest/challenge",
    payload: { keyId, purpose: "assertion" },
  });
  assert.equal(limited.statusCode, 429);
  assert.equal(limited.headers["retry-after"], "60");
});

class AuthenticationStub implements AppAttestAuthenticating {
  assertionError: Error | undefined;
  attestationResult: Promise<typeof token> = Promise.resolve(token);
  attestationCalls = 0;

  createChallenge() {
    return Promise.resolve({
      challengeId,
      clientData: Buffer.alloc(32, 8).toString("base64url"),
      expiresAt: "2026-08-21T12:03:00.000Z",
    });
  }

  attest(): Promise<typeof token> {
    this.attestationCalls += 1;
    return this.attestationResult;
  }

  assert(): Promise<typeof token> {
    return this.assertionError === undefined
      ? Promise.resolve(token)
      : Promise.reject(this.assertionError);
  }
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error("Timed out waiting for authentication invocation.");
}
