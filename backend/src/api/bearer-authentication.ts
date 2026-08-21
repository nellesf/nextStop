import { createHash, timingSafeEqual } from "node:crypto";

const minimumBearerTokenBytes = 32;

export interface SearchAuthenticating {
  isAuthorized(authorizationHeader: string | undefined): boolean;
}

export class BearerTokenAuthenticator implements SearchAuthenticating {
  private readonly expectedDigest: Buffer;

  constructor(token: string) {
    if (Buffer.byteLength(token, "utf8") < minimumBearerTokenBytes || /\s/u.test(token)) {
      throw new Error(
        `SEARCH_API_BEARER_TOKEN must contain at least ${String(minimumBearerTokenBytes)} bytes and no whitespace.`,
      );
    }
    this.expectedDigest = digest(token);
  }

  isAuthorized(authorizationHeader: string | undefined): boolean {
    const token = bearerToken(authorizationHeader);
    const suppliedDigest = digest(token ?? "");
    return token !== undefined && timingSafeEqual(suppliedDigest, this.expectedDigest);
  }
}

function bearerToken(authorizationHeader: string | undefined): string | undefined {
  const match = authorizationHeader?.match(/^Bearer ([^\s]+)$/iu);
  return match?.[1];
}

function digest(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}
