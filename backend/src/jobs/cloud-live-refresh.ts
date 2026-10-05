import Fastify, { type FastifyInstance } from "fastify";
import { OAuth2Client } from "google-auth-library";
import type { SearchAuthenticating } from "../api/bearer-authentication.js";
import type { CloudLiveRefreshConfiguration } from "../application/cloud-tasks-refresh-signal.js";
import type { LiveRefreshLease, LiveRefreshLeasing } from "../persistence/live-refresh-control.js";

/** No background promise: Cloud Tasks receives success only after publication and lease completion. */
export class CloudLiveRefresh {
  constructor(private readonly control: LiveRefreshLeasing,
    private readonly refresh: (lease: LiveRefreshLease) => Promise<unknown>) {}

  async run(): Promise<"completed" | "retry"> {
    const claim = await this.control.acquire();
    if (claim.lease === undefined) return claim.pending || claim.retryable === true ? "retry" : "completed";
    let success = false;
    try {
      await this.refresh(claim.lease);
      success = true;
    } finally { await this.control.finish(claim.lease, success); }
    return "completed";
  }
}

interface TaskTokenVerifying {
  verifyIdToken(options: { readonly idToken: string; readonly audience: string }): Promise<{
    getPayload(): { readonly email?: string; readonly email_verified?: boolean } | undefined;
  }>;
}

/** Cloud Run IAM is mandatory; this also verifies the fixed task identity and audience in the application. */
export class GoogleTaskAuthenticator implements SearchAuthenticating {
  constructor(private readonly configuration: Pick<CloudLiveRefreshConfiguration, "audience" | "serviceAccount">,
    private readonly verifier: TaskTokenVerifying = new OAuth2Client({ transporterOptions: {
      timeout: 2_000, retry: false, retryConfig: { retry: 0, noResponseRetries: 0, totalTimeout: 2_000 },
    } })) {}
  async isAuthorized(authorization: string | undefined): Promise<boolean> {
    if (authorization === undefined || authorization.length > 8_192 || !authorization.startsWith("Bearer ")) return false;
    try {
      const ticket = await this.verifier.verifyIdToken({ idToken: authorization.slice(7), audience: this.configuration.audience });
      const payload = ticket.getPayload();
      return payload?.email_verified === true && payload.email === this.configuration.serviceAccount;
    } catch { return false; }
  }
}

export function createCloudLiveRefreshApp(controller: CloudLiveRefresh, authenticator: SearchAuthenticating,
  failure: () => void = () => {}): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: 128, requestTimeout: 5_000,
    ajv: { customOptions: { removeAdditional: false, coerceTypes: false, useDefaults: false } } });
  app.setErrorHandler((_error, _request, reply) => reply.status(400).send({ status: "rejected" }));
  app.get("/health", () => ({ status: "ok" }));
  app.post("/refresh", {
    onRequest: async (request, reply) => {
      if (!await authenticator.isAuthorized(request.headers.authorization)) return reply.status(401).send({ status: "rejected" });
    },
    schema: { body: { type: "object", additionalProperties: false, required: ["providerId"],
      properties: { providerId: { const: "ich_tanke_strom", type: "string" } } } },
  }, async (_request, reply) => {
    try {
      if (await controller.run() === "completed") return reply.status(204).send();
    } catch { failure(); }
    // Never acknowledge busy leases, failed fetches, fencing failures or failed
    // lease cleanup as success. The queue's bounded backoff controls retries.
    return reply.status(503).header("Retry-After", "60").send({ status: "retry" });
  });
  return app;
}
