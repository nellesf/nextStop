import { createHmac, timingSafeEqual } from "node:crypto";

export interface SnapshotPayload {
  readonly kind: "snapshot";
  readonly version: 1;
  readonly projectionId: string;
  readonly requestFingerprint: string;
}

export interface CursorPayload {
  readonly kind: "cursor";
  readonly version: 1;
  readonly projectionId: string;
  readonly requestFingerprint: string;
  readonly lowerBoundMeters: number;
  readonly parkId: string;
}

export class InvalidPaginationTokenError extends Error {
  constructor() {
    super("The pagination token is invalid or does not belong to this search.");
    this.name = "InvalidPaginationTokenError";
  }
}

export class SignedPaginationCodec {
  private readonly secret: Buffer;

  constructor(secret: string) {
    this.secret = Buffer.from(secret, "utf8");
    if (this.secret.byteLength < 32) {
      throw new Error("SNAPSHOT_SIGNING_KEY must contain at least 32 UTF-8 bytes.");
    }
  }

  encode(payload: SnapshotPayload | CursorPayload): string {
    const encodedPayload = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
    return `${encodedPayload}.${this.sign(encodedPayload)}`;
  }

  decodeSnapshot(token: string): SnapshotPayload {
    const value = this.decode(token);
    if (
      value.kind !== "snapshot" ||
      !isUUID(value.projectionId) ||
      !isFingerprint(value.requestFingerprint)
    ) {
      throw new InvalidPaginationTokenError();
    }
    return value;
  }

  decodeCursor(token: string): CursorPayload {
    const value = this.decode(token);
    if (
      value.kind !== "cursor" ||
      !isUUID(value.projectionId) ||
      !isFingerprint(value.requestFingerprint) ||
      !Number.isSafeInteger(value.lowerBoundMeters) ||
      value.lowerBoundMeters < 0 ||
      !isUUID(value.parkId)
    ) {
      throw new InvalidPaginationTokenError();
    }
    return value;
  }

  private decode(token: string): SnapshotPayload | CursorPayload {
    const [encodedPayload, encodedSignature, extra] = token.split(".");
    if (encodedPayload === undefined || encodedSignature === undefined || extra !== undefined) {
      throw new InvalidPaginationTokenError();
    }
    const actualSignature = Buffer.from(encodedSignature, "base64url");
    const expectedSignature = Buffer.from(this.sign(encodedPayload), "base64url");
    if (
      actualSignature.byteLength !== expectedSignature.byteLength ||
      !timingSafeEqual(actualSignature, expectedSignature)
    ) {
      throw new InvalidPaginationTokenError();
    }
    try {
      const parsed: unknown = JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8"));
      if (!isTokenObject(parsed) || parsed.version !== 1) {
        throw new InvalidPaginationTokenError();
      }
      return parsed;
    } catch (error) {
      if (error instanceof InvalidPaginationTokenError) {
        throw error;
      }
      throw new InvalidPaginationTokenError();
    }
  }

  private sign(value: string): string {
    return createHmac("sha256", this.secret).update(value).digest("base64url");
  }
}

function isTokenObject(value: unknown): value is SnapshotPayload | CursorPayload {
  return (
    typeof value === "object" &&
    value !== null &&
    "kind" in value &&
    (value.kind === "snapshot" || value.kind === "cursor") &&
    "version" in value &&
    value.version === 1 &&
    "projectionId" in value &&
    typeof value.projectionId === "string" &&
    "requestFingerprint" in value &&
    typeof value.requestFingerprint === "string"
  );
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
    value,
  );
}

function isFingerprint(value: string): boolean {
  return /^[0-9a-f]{64}$/u.test(value);
}
