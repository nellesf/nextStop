import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  AppAttestAuthenticationRejectedError,
  AppAttestCounterConflictError,
  AppAttestAuthenticationService,
  StaleAppAttestAssertionCounterError,
  type AppAttestAuthenticationRepository,
  type AppAttestCryptographicallyVerifying,
  type AttestedKey,
} from "../../src/application/app-attest-authentication.js";

const rawKeyId = Buffer.alloc(32, 7);
const keyId = rawKeyId.toString("base64");
const challengeId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const clientData = Buffer.alloc(32, 9);
const token = {
  accessToken: "signed-token",
  tokenType: "Bearer" as const,
  expiresInSeconds: 900,
};

void test("challenge is bound to a hashed key, purpose and three-minute expiry", async () => {
  const repository = new InMemoryRepository();
  const service = makeService(repository);

  const response = await service.createChallenge({ keyId, purpose: "attestation" });

  assert.deepEqual(response, {
    challengeId,
    clientData: clientData.toString("base64url"),
    expiresAt: "2026-08-21T12:03:00.000Z",
  });
  assert.equal(repository.challenges.length, 1);
  assert.equal(repository.challenges[0]?.keyIdHash.equals(createHash("sha256").update(rawKeyId).digest()), true);
  assert.notEqual(repository.challenges[0]?.keyIdHash.toString("utf8"), keyId);
  assert.equal(repository.cleanupCalls, 1);
  assert.equal(repository.keyCleanupCalls, 1);
  assert.equal(repository.lastExcludedKeyHash?.equals(repository.challenges[0]?.keyIdHash ?? Buffer.alloc(0)), true);
});

void test("attestation consumes its challenge once and stores no raw key ID", async () => {
  const repository = new InMemoryRepository();
  const verifier = new VerifierStub();
  const service = makeService(repository, verifier);
  await service.createChallenge({ keyId, purpose: "attestation" });

  assert.deepEqual(
    await service.attest({
      keyId,
      challengeId,
      attestationObject: Buffer.from("attestation").toString("base64"),
    }),
    token,
  );
  assert.equal(verifier.attestationClientData?.equals(clientData), true);
  assert.equal(repository.keys.size, 1);
  await assert.rejects(
    service.attest({
      keyId,
      challengeId,
      attestationObject: Buffer.from("attestation").toString("base64"),
    }),
    AppAttestAuthenticationRejectedError,
  );
});

void test("expired and wrong-purpose challenges fail closed and are consumed", async () => {
  const repository = new InMemoryRepository();
  let now = new Date("2026-08-21T12:00:00.000Z");
  const service = makeService(repository, new VerifierStub(), () => now);
  await service.createChallenge({ keyId, purpose: "attestation" });
  now = new Date("2026-08-21T12:03:00.000Z");
  await assert.rejects(
    service.attest({
      keyId,
      challengeId,
      attestationObject: Buffer.from("attestation").toString("base64"),
    }),
    AppAttestAuthenticationRejectedError,
  );

  now = new Date("2026-08-21T12:04:00.000Z");
  await service.createChallenge({ keyId, purpose: "assertion" });
  await assert.rejects(
    service.attest({
      keyId,
      challengeId,
      attestationObject: Buffer.from("attestation").toString("base64"),
    }),
    AppAttestAuthenticationRejectedError,
  );
});

void test("parallel assertions cannot both advance the same stored counter", async () => {
  const repository = new InMemoryRepository();
  const verifier = new VerifierStub();
  const firstService = makeService(repository, verifier);
  await firstService.createChallenge({ keyId, purpose: "attestation" });
  await firstService.attest({
    keyId,
    challengeId,
    attestationObject: Buffer.from("attestation").toString("base64"),
  });

  const serviceA = makeService(
    repository,
    verifier,
    undefined,
    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeee1",
  );
  const serviceB = makeService(
    repository,
    verifier,
    undefined,
    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeee2",
  );
  await serviceA.createChallenge({ keyId, purpose: "assertion" });
  await serviceB.createChallenge({ keyId, purpose: "assertion" });

  const results = await Promise.allSettled([
    serviceA.assert({
      keyId,
      challengeId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeee1",
      assertionObject: Buffer.from("assertion").toString("base64"),
    }),
    serviceB.assert({
      keyId,
      challengeId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeee2",
      assertionObject: Buffer.from("assertion").toString("base64"),
    }),
  ]);

  assert.equal(results.filter(({ status }) => status === "fulfilled").length, 1);
  assert.equal(results.filter(({ status }) => status === "rejected").length, 1);
  assert.equal([...repository.keys.values()][0]?.signCount, 1);
});

void test("an already-stale verified counter is reported as a conflict", async () => {
  const repository = new InMemoryRepository();
  const verifier = new VerifierStub();
  const service = makeService(repository, verifier);
  await service.createChallenge({ keyId, purpose: "attestation" });
  await service.attest({
    keyId,
    challengeId,
    attestationObject: Buffer.from("attestation").toString("base64"),
  });
  await service.createChallenge({ keyId, purpose: "assertion" });
  verifier.assertionError = new StaleAppAttestAssertionCounterError();

  await assert.rejects(
    service.assert({
      keyId,
      challengeId,
      assertionObject: Buffer.from("assertion").toString("base64"),
    }),
    AppAttestCounterConflictError,
  );
});

class VerifierStub implements AppAttestCryptographicallyVerifying {
  attestationClientData: Buffer | undefined;
  assertionError: Error | undefined;

  verifyAttestation(input: Parameters<AppAttestCryptographicallyVerifying["verifyAttestation"]>[0]) {
    this.attestationClientData = input.clientData;
    return {
      publicKeyPEM: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
      receipt: Buffer.from("receipt"),
      environment: "production" as const,
    };
  }

  verifyAssertion(): number {
    if (this.assertionError !== undefined) {
      throw this.assertionError;
    }
    return 1;
  }
}

class InMemoryRepository implements AppAttestAuthenticationRepository {
  readonly challenges: Array<{
    readonly challengeId: string;
    readonly keyIdHash: Buffer;
    readonly purpose: "attestation" | "assertion";
    readonly clientData: Buffer;
    readonly createdAt: Date;
    readonly expiresAt: Date;
  }> = [];
  readonly keys = new Map<string, AttestedKey>();
  cleanupCalls = 0;
  keyCleanupCalls = 0;
  lastExcludedKeyHash: Buffer | undefined;

  deleteExpiredChallenges(now: Date): Promise<number> {
    this.cleanupCalls += 1;
    let deleted = 0;
    for (let index = this.challenges.length - 1; index >= 0; index -= 1) {
      if ((this.challenges[index]?.expiresAt.getTime() ?? Number.POSITIVE_INFINITY) <= now.getTime()) {
        this.challenges.splice(index, 1);
        deleted += 1;
      }
    }
    return Promise.resolve(deleted);
  }

  deleteStaleKeys(
    _now: Date,
    _maximumRows: number,
    excludedKeyIdHash: Buffer,
  ): Promise<number> {
    this.keyCleanupCalls += 1;
    this.lastExcludedKeyHash = excludedKeyIdHash;
    return Promise.resolve(0);
  }

  insertChallenge(input: Parameters<AppAttestAuthenticationRepository["insertChallenge"]>[0]): Promise<void> {
    this.challenges.push(input);
    return Promise.resolve();
  }

  consumeChallenge(input: Parameters<AppAttestAuthenticationRepository["consumeChallenge"]>[0]): Promise<Buffer | undefined> {
    const index = this.challenges.findIndex(
      (challenge) =>
        challenge.challengeId === input.challengeId &&
        challenge.keyIdHash.equals(input.keyIdHash) &&
        challenge.purpose === input.purpose &&
        challenge.expiresAt.getTime() > input.now.getTime(),
    );
    if (index < 0) {
      return Promise.resolve(undefined);
    }
    const [challenge] = this.challenges.splice(index, 1);
    return Promise.resolve(challenge?.clientData);
  }

  insertKey(key: AttestedKey): Promise<boolean> {
    const id = key.keyIdHash.toString("hex");
    if (this.keys.has(id)) {
      return Promise.resolve(false);
    }
    this.keys.set(id, key);
    return Promise.resolve(true);
  }

  findKey(keyIdHash: Buffer): Promise<AttestedKey | undefined> {
    const key = this.keys.get(keyIdHash.toString("hex"));
    return Promise.resolve(key === undefined ? undefined : { ...key });
  }

  advanceCounter(input: Parameters<AppAttestAuthenticationRepository["advanceCounter"]>[0]): Promise<boolean> {
    const id = input.keyIdHash.toString("hex");
    const key = this.keys.get(id);
    if (
      key === undefined ||
      key.signCount !== input.previousSignCount ||
      input.nextSignCount <= key.signCount
    ) {
      return Promise.resolve(false);
    }
    this.keys.set(id, { ...key, signCount: input.nextSignCount });
    return Promise.resolve(true);
  }
}

function makeService(
  repository: InMemoryRepository,
  verifier = new VerifierStub(),
  now: (() => Date) | undefined = () => new Date("2026-08-21T12:00:00.000Z"),
  id = challengeId,
): AppAttestAuthenticationService {
  return new AppAttestAuthenticationService(
    repository,
    verifier,
    { issue: () => token },
    {
      ...(now === undefined ? {} : { now }),
      makeChallengeId: () => id,
      makeClientData: () => Buffer.from(clientData),
    },
  );
}
