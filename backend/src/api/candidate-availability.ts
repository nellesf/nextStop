import type { FastifyInstance } from "fastify";
import { availabilityLimits, InvalidAvailabilityContextError, type AvailabilityRequest,
  type CandidateAvailabilityReading } from "../application/candidate-availability.js";
import type { SearchAuthenticating } from "./bearer-authentication.js";
import { availabilityRequestSchema, availabilityResponseSchema, problemSchema } from "./schemas.js";

export function registerCandidateAvailability(app: FastifyInstance, reader: CandidateAvailabilityReading,
  authenticator: SearchAuthenticating): void {
  let active = 0;
  app.post<{ Body: AvailabilityRequest }>("/v1/charging-parks/availability", {
    bodyLimit: availabilityLimits.maximumBodyBytes,
    onRequest: async (request, reply) => {
      reply.header("Cache-Control", "no-store");
      if (!(await authenticator.isAuthorized(request.headers.authorization))) {
        await reply.status(401).header("WWW-Authenticate", 'Bearer realm="nextstop-search"')
          .type("application/problem+json").send({ type: "urn:nextstop:error:unauthorized", title: "Authentication required", status: 401, errorId: request.id });
      }
    },
    schema: { body: availabilityRequestSchema,
      response: { 200: availabilityResponseSchema, 400: problemSchema, 401: problemSchema,
        409: problemSchema, 413: problemSchema, 429: problemSchema, 503: problemSchema } },
  }, async (request, reply) => {
    if (active >= 2) return reply.status(429).header("Retry-After", "2").type("application/problem+json").send({
      type: "urn:nextstop:error:availability-capacity", title: "Availability capacity exhausted", status: 429, errorId: request.id });
    active += 1;
    try { return reply.status(200).header("Cache-Control", "no-store").send(await reader.read(request.body)); }
    catch (error) {
      if (error instanceof InvalidAvailabilityContextError) return reply.status(409).type("application/problem+json").send({
        type: "urn:nextstop:error:availability-context", title: "Availability context unavailable", status: 409, errorId: request.id });
      return reply.status(503).type("application/problem+json").send({ type: "urn:nextstop:error:availability-unavailable", title: "Availability unavailable", status: 503, errorId: request.id });
    } finally { active -= 1; }
  });
}
