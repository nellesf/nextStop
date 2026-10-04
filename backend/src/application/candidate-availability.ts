import { createHmac, timingSafeEqual } from "node:crypto";
import { minimumPowerOptions, type MinimumPowerKW, type ParkAvailability } from "../domain/candidate-search.js";

export const availabilityLimits = {
  maximumCandidates: 50, maximumOperators: 20, maximumBodyBytes: 131_072,
  contextLifetimeSeconds: 3_600, maximumAgeSeconds: 300, refreshAfterSeconds: 60,
} as const;

export interface AvailabilityContext {
  readonly projectionId: string;
  readonly candidateKind: "park" | "campus";
  readonly minimumPowerKW: MinimumPowerKW;
  readonly expiresAt: number;
}
export interface AvailabilitySelection { readonly id: string; readonly operatorNames: readonly string[] }
export interface AvailabilityRequest {
  readonly context: string;
  readonly candidates: readonly AvailabilitySelection[];
}
export interface AvailabilityResponse {
  readonly context: string;
  readonly generatedAt: string;
  readonly expiresAt: string;
  readonly refreshPending: boolean;
  readonly retryAfterSeconds?: number;
  readonly candidates: readonly (AvailabilitySelection & { readonly availability: ParkAvailability })[];
}
export interface AvailabilityReading {
  read(context: AvailabilityContext, candidates: readonly AvailabilitySelection[], now: Date): Promise<{
    readonly candidates: AvailabilityResponse["candidates"];
    readonly needsSwissRefresh: boolean;
  }>;
}
export interface LiveRefreshSignaling { signal(): Promise<boolean> }
export interface CandidateAvailabilityReading { read(request: AvailabilityRequest): Promise<AvailabilityResponse> }
export class InvalidAvailabilityContextError extends Error {
  constructor() { super("Availability context or selection is invalid or expired."); this.name = "InvalidAvailabilityContextError"; }
}

/** Separate token purpose: never accepts a pagination or access token. Contains no route or user identifier. */
export class AvailabilityContextCodec {
  constructor(private readonly secret: string) {
    if (Buffer.byteLength(secret) < 32) throw new Error("Availability signing key must have at least 32 bytes.");
  }
  encode(context: AvailabilityContext): string {
    const body = Buffer.from(JSON.stringify({ kind: "availability", version: 1, ...context })).toString("base64url");
    return `${body}.${this.sign(body).toString("base64url")}`;
  }
  decode(token: string, now: Date): AvailabilityContext {
    try {
      if (token.length > 1_024) throw new InvalidAvailabilityContextError();
      const [body, signature, extra] = token.split(".");
      if (body === undefined || signature === undefined || extra !== undefined) throw new InvalidAvailabilityContextError();
      const actual = Buffer.from(signature, "base64url"), expected = this.sign(body);
      if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) throw new InvalidAvailabilityContextError();
      const value: unknown = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
      if (typeof value !== "object" || value === null || !("kind" in value) || value.kind !== "availability" ||
          !("version" in value) || value.version !== 1 || !("projectionId" in value) ||
          typeof value.projectionId !== "string" || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/iu.test(value.projectionId) ||
          !("candidateKind" in value) || (value.candidateKind !== "park" && value.candidateKind !== "campus") ||
          !("minimumPowerKW" in value) || !minimumPowerOptions.includes(value.minimumPowerKW as MinimumPowerKW) ||
          !("expiresAt" in value) || typeof value.expiresAt !== "number" || !Number.isSafeInteger(value.expiresAt) ||
          value.expiresAt <= now.getTime() || value.expiresAt > now.getTime() + availabilityLimits.contextLifetimeSeconds * 1_000) {
        throw new InvalidAvailabilityContextError();
      }
      return { projectionId: value.projectionId, candidateKind: value.candidateKind,
        minimumPowerKW: value.minimumPowerKW as MinimumPowerKW, expiresAt: value.expiresAt };
    } catch { throw new InvalidAvailabilityContextError(); }
  }
  private sign(body: string): Buffer { return createHmac("sha256", this.secret).update("nextstop-availability-v1:").update(body).digest(); }
}

export class CandidateAvailability implements CandidateAvailabilityReading {
  constructor(private readonly codec: AvailabilityContextCodec, private readonly repository: AvailabilityReading,
    private readonly refresh: LiveRefreshSignaling, private readonly now: () => Date = () => new Date()) {}
  async read(request: AvailabilityRequest): Promise<AvailabilityResponse> {
    const now = this.now(), context = this.codec.decode(request.context, now);
    if (request.candidates.length < 1 || request.candidates.length > availabilityLimits.maximumCandidates ||
        new Set(request.candidates.map(({ id }) => id)).size !== request.candidates.length ||
        request.candidates.some(({ operatorNames }) => operatorNames.length < 1 ||
          operatorNames.length > availabilityLimits.maximumOperators || new Set(operatorNames).size !== operatorNames.length)) {
      throw new InvalidAvailabilityContextError();
    }
    const result = await this.repository.read(context, request.candidates, now);
    // Only this secondary request waits for a bounded internal acknowledgement, never provider I/O.
    const refreshPending = result.needsSwissRefresh ? await this.refresh.signal().catch(() => false) : false;
    return { context: request.context, generatedAt: now.toISOString(), expiresAt: new Date(context.expiresAt).toISOString(),
      refreshPending, ...(refreshPending ? { retryAfterSeconds: 2 } : {}), candidates: result.candidates };
  }
}

export class HTTPRefreshSignal implements LiveRefreshSignaling {
  private readonly url: string;
  constructor(url: string, private readonly token: string, private readonly fetcher: typeof fetch = fetch) {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" || parsed.username !== "" || parsed.password !== "" ||
        parsed.hostname !== "worker" || parsed.port !== "8091" || parsed.pathname !== "/refresh" || parsed.search !== "" || parsed.hash !== "") {
      throw new Error("LIVE_REFRESH_URL must be the private worker endpoint.");
    }
    if (Buffer.byteLength(token) < 32) throw new Error("LIVE_REFRESH_TOKEN must have at least 32 bytes.");
    this.url = parsed.toString();
  }
  async signal(): Promise<boolean> {
    const response = await this.fetcher(this.url, { method: "POST", redirect: "error", signal: AbortSignal.timeout(1_000),
      headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json" },
      body: JSON.stringify({ providerId: "ich_tanke_strom" }) });
    await response.body?.cancel();
    return response.status === 202;
  }
}
