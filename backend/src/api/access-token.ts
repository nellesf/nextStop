import {
  createHmac,
  randomUUID,
  timingSafeEqual,
  type UUID,
} from "node:crypto";

import { bearerToken, type SearchAuthenticating } from "./bearer-authentication.js";

const tokenLifetimeSeconds = 15 * 60;
const maximumTokenLength = 2_048;
const permittedFutureClockSkewSeconds = 30;
const issuer = "https://api.nextstop.tech";
const audience = "nextstop-search";
const tokenHeader = { alg: "HS256", typ: "JWT" } as const;

interface AccessTokenClaims {
  readonly iss: string;
  readonly aud: string;
  readonly iat: number;
  readonly nbf: number;
  readonly exp: number;
  readonly jti: string;
  readonly client?: "simulator";
  readonly environment?: "development";
}

export interface IssuedAccessToken {
  readonly accessToken: string;
  readonly tokenType: "Bearer";
  readonly expiresInSeconds: number;
}

export interface AccessTokenCodecOptions {
  readonly now?: () => Date;
  readonly makeTokenId?: () => UUID;
}

export class AccessTokenCodec {
  private readonly signingKey: Buffer;
  private readonly now: () => Date;
  private readonly makeTokenId: () => UUID;

  constructor(signingKey: string, options: AccessTokenCodecOptions = {}) {
    if (Buffer.byteLength(signingKey, "utf8") < 32 || /\s/u.test(signingKey)) {
      throw new Error(
        "SEARCH_ACCESS_TOKEN_SIGNING_KEY must contain at least 32 bytes and no whitespace.",
      );
    }
    this.signingKey = Buffer.from(signingKey, "utf8");
    this.now = options.now ?? (() => new Date());
    this.makeTokenId = options.makeTokenId ?? randomUUID;
  }

  issue(options: { readonly client?: "simulator" } = {}): IssuedAccessToken {
    const issuedAt = epochSeconds(this.now());
    const claims: AccessTokenClaims = {
      iss: issuer,
      aud: audience,
      iat: issuedAt,
      nbf: issuedAt,
      exp: issuedAt + tokenLifetimeSeconds,
      jti: this.makeTokenId(),
      ...(options.client === undefined
        ? {}
        : { client: options.client, environment: "development" as const }),
    };
    const encodedHeader = encodeJSON(tokenHeader);
    const encodedClaims = encodeJSON(claims);
    const signedContent = `${encodedHeader}.${encodedClaims}`;
    const signature = createHmac("sha256", this.signingKey)
      .update(signedContent, "ascii")
      .digest("base64url");
    return {
      accessToken: `${signedContent}.${signature}`,
      tokenType: "Bearer",
      expiresInSeconds: tokenLifetimeSeconds,
    };
  }

  verify(token: string): boolean {
    if (token.length === 0 || token.length > maximumTokenLength) {
      return false;
    }
    const segments = token.split(".");
    if (segments.length !== 3) {
      return false;
    }
    const [encodedHeader, encodedClaims, encodedSignature] = segments;
    if (
      encodedHeader === undefined ||
      encodedClaims === undefined ||
      encodedSignature === undefined ||
      !isCanonicalBase64URL(encodedHeader) ||
      !isCanonicalBase64URL(encodedClaims) ||
      !isCanonicalBase64URL(encodedSignature)
    ) {
      return false;
    }

    const suppliedSignature = Buffer.from(encodedSignature, "base64url");
    const expectedSignature = createHmac("sha256", this.signingKey)
      .update(`${encodedHeader}.${encodedClaims}`, "ascii")
      .digest();
    if (
      suppliedSignature.length !== expectedSignature.length ||
      !timingSafeEqual(suppliedSignature, expectedSignature)
    ) {
      return false;
    }

    const header = decodeJSONObject(encodedHeader);
    const claims = decodeJSONObject(encodedClaims);
    if (header === undefined || claims === undefined) {
      return false;
    }
    if (
      !hasExactKeys(header, ["alg", "typ"]) ||
      header.alg !== "HS256" ||
      header.typ !== "JWT" ||
      !hasExactKeys(
        claims,
        claims.client === undefined
          ? ["aud", "exp", "iat", "iss", "jti", "nbf"]
          : ["aud", "client", "environment", "exp", "iat", "iss", "jti", "nbf"],
      )
    ) {
      return false;
    }
    if (
      claims.iss !== issuer ||
      claims.aud !== audience ||
      !isEpochSecond(claims.iat) ||
      !isEpochSecond(claims.nbf) ||
      !isEpochSecond(claims.exp) ||
      typeof claims.jti !== "string" ||
      !isUUID(claims.jti) ||
      (claims.client !== undefined &&
        (claims.client !== "simulator" || claims.environment !== "development")) ||
      (claims.client === undefined && claims.environment !== undefined)
    ) {
      return false;
    }

    const currentTime = epochSeconds(this.now());
    return (
      claims.nbf === claims.iat &&
      claims.exp - claims.iat === tokenLifetimeSeconds &&
      claims.iat <= currentTime + permittedFutureClockSkewSeconds &&
      claims.iat >= currentTime - tokenLifetimeSeconds &&
      claims.nbf <= currentTime + permittedFutureClockSkewSeconds &&
      claims.exp > currentTime
    );
  }
}

export class AccessTokenAuthenticator implements SearchAuthenticating {
  constructor(private readonly codec: AccessTokenCodec) {}

  isAuthorized(authorizationHeader: string | undefined): boolean {
    const token = bearerToken(authorizationHeader);
    return token !== undefined && this.codec.verify(token);
  }
}

function encodeJSON(value: object): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function decodeJSONObject(value: string): Record<string, unknown> | undefined {
  try {
    const parsed: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return undefined;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

function isCanonicalBase64URL(value: string): boolean {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) {
    return false;
  }
  const decoded = Buffer.from(value, "base64url");
  return decoded.length > 0 && decoded.toString("base64url") === value;
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actualKeys = Object.keys(value).toSorted();
  return actualKeys.length === keys.length && actualKeys.every((key, index) => key === keys[index]);
}

function isEpochSecond(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(
    value,
  );
}

function epochSeconds(date: Date): number {
  const milliseconds = date.getTime();
  if (!Number.isFinite(milliseconds)) {
    throw new Error("Access-token clock returned an invalid date.");
  }
  return Math.floor(milliseconds / 1_000);
}
