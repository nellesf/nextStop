import Fastify, { type FastifyInstance } from "fastify";
import type { AccessTokenCodec } from "./access-token.js";

/** Deployed as an IAM-only service with no public invocation grant. */
export function createSimulatorTokenApp(codec: AccessTokenCodec, now: () => number = Date.now): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: 1, requestTimeout: 5_000 });
  let window = 0;
  let count = 0;
  app.setErrorHandler((_error, _request, reply) => reply.status(400).send({ status: "rejected" }));
  app.get("/health", () => ({ status: "ok" }));
  app.post("/token", async (request, reply) => {
    reply.header("Cache-Control", "no-store");
    if (request.url !== "/token" || request.headers.origin !== undefined || request.body !== undefined) {
      return reply.status(400).send({ status: "rejected" });
    }
    const current = Math.floor(now() / 60_000);
    if (window !== current) { window = current; count = 0; }
    if (++count > 30) return reply.status(429).header("Retry-After", "60").send({ status: "retry" });
    return codec.issue({ client: "simulator" });
  });
  return app;
}
