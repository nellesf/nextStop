import { gatewayOrigin } from "../api/cloud-gateway.js";

/** Metadata credentials stay in memory and are never forwarded from public callers. */
export class CloudIdentityTokens {
  private readonly cache = new Map<string, { token: string; expires: number }>();
  private readonly pending = new Map<string, Promise<string>>();
  constructor(private readonly transport: typeof fetch = fetch, private readonly now: () => number = Date.now) {}
  async get(origin: string): Promise<string> {
    const audience = gatewayOrigin(origin);
    const cached = this.cache.get(audience);
    if (cached !== undefined && cached.expires > this.now() + 60_000) return cached.token;
    const existing = this.pending.get(audience);
    if (existing !== undefined) return existing;
    const request = this.load(audience).finally(() => { this.pending.delete(audience); });
    this.pending.set(audience, request);
    return request;
  }
  private async load(audience: string): Promise<string> {
    const target = new URL("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity");
    target.searchParams.set("audience", audience);
    target.searchParams.set("format", "full");
    const response = await this.transport(target, { headers: { "Metadata-Flavor": "Google" },
      redirect: "error", signal: AbortSignal.timeout(2_000) });
    if (!response.ok || response.body === null) throw new Error("Identity credential unavailable.");
    const reader = response.body.getReader();
    let token = "";
    try {
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        token += Buffer.from(next.value).toString("ascii");
        if (token.length > 8192) throw new Error("Invalid identity credential.");
      }
    } finally { await reader.cancel(); }
    const payload = token.split(".")[1];
    if (payload === undefined || !/^[A-Za-z0-9_.-]+$/u.test(token)) throw new Error("Invalid identity credential.");
    const claims: unknown = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    if (typeof claims !== "object" || claims === null || !("exp" in claims) || !("aud" in claims) ||
        claims.aud !== audience || typeof claims.exp !== "number" || !Number.isSafeInteger(claims.exp) ||
        claims.exp * 1000 <= this.now() + 60_000) throw new Error("Invalid identity credential.");
    this.cache.set(audience, { token, expires: claims.exp * 1000 });
    return token;
  }
}
