import { randomUUID } from "node:crypto";

import type { FastifyInstance, FastifyRequest } from "fastify";

import {
  InvalidUserErrorReportError,
  UserErrorReportCapacityError,
  UserErrorReportAuthorizationError,
  UserErrorReportConflictError,
  UserErrorReportWithdrawnError,
  userErrorReportLimits,
  type UserErrorReports,
} from "../application/user-error-reports.js";
import {
  RejectingSearchAuthenticator,
  type SearchAuthenticating,
} from "./bearer-authentication.js";

export interface UserErrorReportAPIDependencies {
  readonly reports?: UserErrorReports;
  readonly authenticator?: SearchAuthenticating;
  readonly nowMilliseconds?: () => number;
  readonly recordError: (request: FastifyRequest, error: unknown) => void;
}

export function registerUserErrorReports(
  app: FastifyInstance,
  dependencies: UserErrorReportAPIDependencies,
): void {
  const authenticator = dependencies.authenticator ?? new RejectingSearchAuthenticator();
  const now = dependencies.nowMilliseconds ?? Date.now;
  const rates = new Map<string, { startedAt: number; count: number }>();
  let active = 0;

  function admit(method: string): void {
    const time = now();
    const maximum = method === "POST" ? 10 : 30;
    const prior = rates.get(method);
    const rate = prior === undefined || time - prior.startedAt >= 60_000 || time < prior.startedAt
      ? { startedAt: time, count: 0 } : prior;
    rates.set(method, rate);
    if (rate.count >= maximum) throw new ReportAdmissionError();
    rate.count += 1;
  }

  app.setErrorHandler((error, request, reply) => {
    // Expected rejection is classified from its response status. Do not label
    // invalid capabilities or exhausted admission as unexpected server failures.
    if (error instanceof UserErrorReportAuthorizationError) {
      return reply.status(401).header("WWW-Authenticate", 'Bearer realm="nextstop-reports"')
        .type("application/problem+json").send(problem(401, "unauthorized"));
    }
    if (error instanceof ReportAdmissionError) {
      return reply.status(429).header("Retry-After", "60")
        .type("application/problem+json").send(problem(429, "error-report-rate-limited"));
    }
    dependencies.recordError(request, error);
    const code = typeof error === "object" && error !== null && "code" in error
      ? error.code : undefined;
    let status: number;
    let category: string;
    if (code === "FST_ERR_CTP_BODY_TOO_LARGE") {
      status = 413;
      category = "request-too-large";
    } else if (
      error instanceof InvalidUserErrorReportError
      || code === "FST_ERR_CTP_INVALID_JSON_BODY"
      || code === "FST_ERR_CTP_EMPTY_JSON_BODY"
      || code === "FST_ERR_CTP_INVALID_MEDIA_TYPE"
    ) {
      status = 400;
      category = "invalid-error-report";
    } else if (error instanceof UserErrorReportConflictError) {
      status = 409;
      category = "error-report-conflict";
    } else if (error instanceof UserErrorReportWithdrawnError) {
      status = 410;
      category = "error-report-withdrawn";
    } else if (error instanceof UserErrorReportCapacityError) {
      status = 503;
      category = "error-report-capacity";
    } else {
      status = 503;
      category = "error-report-unavailable";
    }
    return reply.status(status).type("application/problem+json").send(problem(status, category));
  });

  app.route<{ Body: unknown }>({
    method: ["POST", "DELETE"],
    url: "/v1/error-reports",
    bodyLimit: userErrorReportLimits.maximumBodyBytes,
    onRequest: async (request, reply) => {
      if (request.method !== "POST") return;
      if (!(await authenticator.isAuthorized(request.headers.authorization))) {
        await reply.status(401).header("WWW-Authenticate", 'Bearer realm="nextstop-reports"')
          .type("application/problem+json").send(problem(401, "unauthorized"));
        return;
      }
      // The proxy retains its per-IP ingress limit. Rejected credentials do not
      // consume the application's separate allowance for legitimate submissions.
      admit("POST");
    },
    handler: async (request, reply) => {
      if (active >= 4) {
        return reply.status(429).header("Retry-After", "1")
          .type("application/problem+json").send(problem(429, "error-report-rate-limited"));
      }
      if (dependencies.reports === undefined) {
        return reply.status(503).type("application/problem+json")
          .send(problem(503, "error-report-unavailable"));
      }
      active += 1;
      try {
        if (request.method === "DELETE") {
          await dependencies.reports.delete(request.body, {
            authenticated: await authenticator.isAuthorized(request.headers.authorization),
            onAuthorized: () => admit("DELETE"),
          });
          return reply.status(204).send();
        }
        const result = await dependencies.reports.submit(request.body);
        return reply.status(result.created ? 201 : 200).send(result.receipt);
      } finally {
        active -= 1;
      }
    },
  });
}

class ReportAdmissionError extends Error {}

function problem(status: number, category: string): object {
  return {
    type: `urn:nextstop:error:${category}`,
    title: "Error report request could not be completed",
    status,
    errorId: randomUUID(),
  };
}
