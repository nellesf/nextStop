import type { FastifyInstance } from "fastify";

export interface ReadinessChecking {
  isReady(): Promise<boolean>;
}

export function installReadiness(app: FastifyInstance, check?: ReadinessChecking, release?: string): void {
  if (release !== undefined && !/^sha256:[0-9a-f]{64}$/u.test(release)) {
    throw new Error("RELEASE_IMAGE_DIGEST must be an immutable SHA-256 image digest.");
  }
  let draining = false;
  app.addHook("preClose", (done) => { draining = true; done(); });
  app.get("/ready", async (_request, reply) => {
    let ready = false;
    try {
      ready = !draining && check !== undefined && await check.isReady() && !draining;
    } catch {
      // Never disclose SQL, configuration, credentials, or provider data.
    }
    return reply.code(ready ? 200 : 503).header("Cache-Control", "no-store")
      .send({ status: ready ? "ready" : "not_ready", ...(release === undefined ? {} : { release }) });
  });
}
