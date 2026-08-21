import { createHash, randomBytes, randomUUID, type UUID } from "node:crypto";

import type { IssuedAccessToken } from "../api/access-token.js";

export type AppAttestPurpose = "attestation" | "assertion";

export interface AppAttestChallengeRequest {
  readonly keyId: string;
  readonly purpose: AppAttestPurpose;
}

export interface AppAttestChallengeResponse {
  readonly challengeId: string;
  readonly clientData: string;
  readonly expiresAt: string;
}

export interface AttestedKey {
  readonly keyIdHash: Buffer;
  readonly publicKeyPEM: string;
  readonly receipt: Buffer;
  readonly environment: "production" | "development";
  readonly signCount: number;
  readonly validationCategory?: number;
  readonly bundleVersion?: string;
  readonly revoked: boolean;
}

export interface VerifiedAttestation {
  readonly publicKeyPEM: string;
  readonly receipt: Buffer;
  readonly environment: "production" | "development";
  readonly validationCategory?: number;
  readonly bundleVersion?: string;
}

export interface AppAttestCryptographicallyVerifying {
  verifyAttestation(input: {
    readonly attestationObject: Buffer;
    readonly clientData: Buffer;
    readonly keyId: string;
  }): VerifiedAttestation;
  verifyAssertion(input: {
    readonly assertionObject: Buffer;
    readonly clientData: Buffer;
    readonly key: AttestedKey;
  }): number;
}

export interface AppAttestAuthenticationRepository {
  deleteExpiredChallenges(now: Date, maximumRows: number): Promise<number>;
  deleteStaleKeys(
    now: Date,
    maximumRows: number,
    excludedKeyIdHash: Buffer,
  ): Promise<number>;
  insertChallenge(input: {
    readonly challengeId: UUID;
    readonly keyIdHash: Buffer;
    readonly purpose: AppAttestPurpose;
    readonly clientData: Buffer;
    readonly createdAt: Date;
    readonly expiresAt: Date;
  }): Promise<void>;
  consumeChallenge(input: {
    readonly challengeId: UUID;
    readonly keyIdHash: Buffer;
    readonly purpose: AppAttestPurpose;
    readonly now: Date;
  }): Promise<Buffer | undefined>;
  insertKey(key: AttestedKey, attestedAt: Date): Promise<boolean>;
  findKey(keyIdHash: Buffer): Promise<AttestedKey | undefined>;
  advanceCounter(input: {
    readonly keyIdHash: Buffer;
    readonly previousSignCount: number;
    readonly nextSignCount: number;
    readonly assertedAt: Date;
  }): Promise<boolean>;
}

export interface AccessTokenIssuing {
  issue(): IssuedAccessToken;
}

export class AppAttestAuthenticationRejectedError extends Error {
  constructor() {
    super("App Attest authentication was rejected.");
    this.name = "AppAttestAuthenticationRejectedError";
  }
}

export class AppAttestKeyNotRegisteredError extends Error {
  constructor() {
    super("The App Attest key is not registered.");
    this.name = "AppAttestKeyNotRegisteredError";
  }
}

export class AppAttestCounterConflictError extends Error {
  constructor() {
    super("The App Attest assertion counter was concurrently advanced.");
    this.name = "AppAttestCounterConflictError";
  }
}

export class StaleAppAttestAssertionCounterError extends Error {
  constructor() {
    super("The App Attest assertion counter did not advance.");
    this.name = "StaleAppAttestAssertionCounterError";
  }
}

export class InvalidAppAttestRequestError extends Error {
  constructor() {
    super("The App Attest request is invalid.");
    this.name = "InvalidAppAttestRequestError";
  }
}

export interface AppAttestAuthenticationServiceOptions {
  readonly now?: () => Date;
  readonly makeChallengeId?: () => string;
  readonly makeClientData?: () => Buffer;
}

export interface AppAttestAuthenticating {
  createChallenge(request: AppAttestChallengeRequest): Promise<AppAttestChallengeResponse>;
  attest(input: {
    readonly keyId: string;
    readonly challengeId: string;
    readonly attestationObject: string;
  }): Promise<IssuedAccessToken>;
  assert(input: {
    readonly keyId: string;
    readonly challengeId: string;
    readonly assertionObject: string;
  }): Promise<IssuedAccessToken>;
}

const challengeLifetimeMilliseconds = 3 * 60 * 1_000;
const challengeCleanupBatchSize = 100;
const keyCleanupBatchSize = 100;

export class AppAttestAuthenticationService implements AppAttestAuthenticating {
  private readonly now: () => Date;
  private readonly makeChallengeId: () => string;
  private readonly makeClientData: () => Buffer;

  constructor(
    private readonly repository: AppAttestAuthenticationRepository,
    private readonly verifier: AppAttestCryptographicallyVerifying,
    private readonly tokenIssuer: AccessTokenIssuing,
    options: AppAttestAuthenticationServiceOptions = {},
  ) {
    this.now = options.now ?? (() => new Date());
    this.makeChallengeId = options.makeChallengeId ?? randomUUID;
    this.makeClientData = options.makeClientData ?? (() => randomBytes(32));
  }

  async createChallenge(
    request: AppAttestChallengeRequest,
  ): Promise<AppAttestChallengeResponse> {
    const keyId = decodeKeyId(request.keyId);
    if (request.purpose !== "attestation" && request.purpose !== "assertion") {
      throw new InvalidAppAttestRequestError();
    }
    const now = this.validNow();
    const clientData = this.makeClientData();
    if (clientData.length !== 32) {
      throw new Error("App Attest client-data generator must return exactly 32 bytes.");
    }
    const challengeId = parseUUID(this.makeChallengeId());
    const expiresAt = new Date(now.getTime() + challengeLifetimeMilliseconds);
    await this.repository.insertChallenge({
      challengeId,
      keyIdHash: hashKeyId(keyId),
      purpose: request.purpose,
      clientData,
      createdAt: now,
      expiresAt,
    });
    await this.repository.deleteExpiredChallenges(now, challengeCleanupBatchSize);
    await this.repository.deleteStaleKeys(now, keyCleanupBatchSize, hashKeyId(keyId));
    return {
      challengeId,
      clientData: clientData.toString("base64url"),
      expiresAt: expiresAt.toISOString(),
    };
  }

  async attest(input: {
    readonly keyId: string;
    readonly challengeId: string;
    readonly attestationObject: string;
  }): Promise<IssuedAccessToken> {
    const keyId = decodeKeyId(input.keyId);
    const keyIdHash = hashKeyId(keyId);
    const challengeId = parseUUID(input.challengeId);
    const attestationObject = decodeBase64Object(input.attestationObject, 131_072);
    const now = this.validNow();
    const clientData = await this.repository.consumeChallenge({
      challengeId,
      keyIdHash,
      purpose: "attestation",
      now,
    });
    if (clientData === undefined) {
      throw new AppAttestAuthenticationRejectedError();
    }

    let verified: VerifiedAttestation;
    try {
      verified = this.verifier.verifyAttestation({
        attestationObject,
        clientData,
        keyId: input.keyId,
      });
    } catch {
      throw new AppAttestAuthenticationRejectedError();
    }
    const stored = await this.repository.insertKey(
      {
        keyIdHash,
        publicKeyPEM: verified.publicKeyPEM,
        receipt: verified.receipt,
        environment: verified.environment,
        signCount: 0,
        ...(verified.validationCategory === undefined
          ? {}
          : { validationCategory: verified.validationCategory }),
        ...(verified.bundleVersion === undefined
          ? {}
          : { bundleVersion: verified.bundleVersion }),
        revoked: false,
      },
      now,
    );
    if (!stored) {
      throw new AppAttestAuthenticationRejectedError();
    }
    return this.tokenIssuer.issue();
  }

  async assert(input: {
    readonly keyId: string;
    readonly challengeId: string;
    readonly assertionObject: string;
  }): Promise<IssuedAccessToken> {
    const keyId = decodeKeyId(input.keyId);
    const keyIdHash = hashKeyId(keyId);
    const challengeId = parseUUID(input.challengeId);
    const assertionObject = decodeBase64Object(input.assertionObject, 16_384);
    const now = this.validNow();
    const clientData = await this.repository.consumeChallenge({
      challengeId,
      keyIdHash,
      purpose: "assertion",
      now,
    });
    if (clientData === undefined) {
      throw new AppAttestAuthenticationRejectedError();
    }
    const key = await this.repository.findKey(keyIdHash);
    if (key === undefined || key.revoked) {
      throw new AppAttestKeyNotRegisteredError();
    }
    let nextSignCount: number;
    try {
      nextSignCount = this.verifier.verifyAssertion({
        assertionObject,
        clientData,
        key,
      });
    } catch (error) {
      if (error instanceof StaleAppAttestAssertionCounterError) {
        throw new AppAttestCounterConflictError();
      }
      throw new AppAttestAuthenticationRejectedError();
    }
    const advanced = await this.repository.advanceCounter({
      keyIdHash,
      previousSignCount: key.signCount,
      nextSignCount,
      assertedAt: now,
    });
    if (!advanced) {
      throw new AppAttestCounterConflictError();
    }
    return this.tokenIssuer.issue();
  }

  private validNow(): Date {
    const now = this.now();
    if (!Number.isFinite(now.getTime())) {
      throw new Error("App Attest clock returned an invalid date.");
    }
    return now;
  }
}

function decodeKeyId(value: string): Buffer {
  if (value.length < 40 || value.length > 64 || !/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) {
    throw new InvalidAppAttestRequestError();
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.length !== 32 || decoded.toString("base64") !== value) {
    throw new InvalidAppAttestRequestError();
  }
  return decoded;
}

function decodeBase64Object(value: string, maximumBytes: number): Buffer {
  if (value.length === 0 || value.length > Math.ceil((maximumBytes * 4) / 3) + 4) {
    throw new InvalidAppAttestRequestError();
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) {
    throw new InvalidAppAttestRequestError();
  }
  const decoded = Buffer.from(value, "base64");
  if (
    decoded.length === 0 ||
    decoded.length > maximumBytes ||
    decoded.toString("base64") !== value
  ) {
    throw new InvalidAppAttestRequestError();
  }
  return decoded;
}

function hashKeyId(keyId: Buffer): Buffer {
  return createHash("sha256").update(keyId).digest();
}

function parseUUID(value: string): UUID {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(value)) {
    throw new InvalidAppAttestRequestError();
  }
  return value as UUID;
}
