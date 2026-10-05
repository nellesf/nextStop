import { timingSafeEqual } from "node:crypto";
import Fastify, { type FastifyInstance } from "fastify";
import type { LiveRefreshLease, LiveRefreshLeasing } from "../persistence/live-refresh-control.js";

export class DemandLiveRefresh {
  private active: Promise<void> | undefined;
  private stopping = false;
  constructor(private readonly control: LiveRefreshLeasing, private readonly refresh: (lease: LiveRefreshLease) => Promise<unknown>,
    private readonly failure: () => void = () => {}) {}
  async request(): Promise<boolean> {
    if (this.stopping) return false;
    if (this.active !== undefined) return true;
    const claim = await this.control.acquire();
    if (claim.lease !== undefined) {
      const lease = claim.lease;
      this.active = this.run(lease).finally(() => { this.active = undefined; });
    }
    return claim.pending;
  }
  async stop(): Promise<void> { this.stopping = true; await this.active; }
  private async run(lease: LiveRefreshLease): Promise<void> {
    let success = false;
    try { await this.refresh(lease); success = true; } catch { this.failure(); }
    finally { await this.control.finish(lease, success).catch(() => this.failure()); }
  }
}

/** Docker-internal only. No provider selection, candidate IDs, routes or arbitrary URLs are accepted. */
export function createLiveRefreshApp(controller: DemandLiveRefresh, token: string): FastifyInstance {
  if (Buffer.byteLength(token) < 32) throw new Error("LIVE_REFRESH_TOKEN must have at least 32 bytes.");
  const expected = Buffer.from(`Bearer ${token}`);
  const app = Fastify({ logger: false, bodyLimit: 128, requestTimeout: 2_000,
    ajv: { customOptions: { removeAdditional: false, coerceTypes: false, useDefaults: false } } });
  app.setErrorHandler((_error, _request, reply) => reply.status(400).send({ status: "rejected" }));
  app.post("/refresh", {
    onRequest: (request, reply, done) => {
      const actual = Buffer.from(request.headers.authorization ?? "");
      if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) void reply.status(401).send({ status: "rejected" });
      done();
    },
    schema: { body: { type: "object", additionalProperties: false, required: ["providerId"],
      properties: { providerId: { const: "ich_tanke_strom", type: "string" } } } },
  }, async (_request, reply) => {
    try { return reply.status(await controller.request() ? 202 : 204).send(); }
    catch { return reply.status(503).send({ status: "unavailable" }); }
  });
  return app;
}
