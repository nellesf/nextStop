import { performance } from "node:perf_hooks";
import { InvalidUserErrorReportError, UserErrorReportCapacityError, UserErrorReportConflictError, UserErrorReportWithdrawnError } from "../application/user-error-reports.js";

import type { FastifyInstance, FastifyRequest } from "fastify";

import {
  AppAttestAuthenticationRejectedError,
  AppAttestCounterConflictError,
  AppAttestKeyNotRegisteredError,
  InvalidAppAttestRequestError,
} from "../application/app-attest-authentication.js";
import {
  FoodPOIDataUnavailableError,
  NoProjectionAvailableError,
} from "../application/candidate-search.js";
import { InvalidPaginationTokenError } from "../application/signed-pagination.js";
import { InvalidSearchRequestError } from "./search-request-validation.js";

export type DiagnosticService = "candidate_api" | "auth_api";
export type DiagnosticRoute =
  | "health"
  | "charging_park_search"
  | "user_error_report"
  | "app_attest_challenge"
  | "app_attest_attestation"
  | "app_attest_assertion"
  | "unknown";
export type DiagnosticErrorCategory =
  | "none"
  | "invalid_request"
  | "body_too_large"
  | "unauthorized"
  | "not_found"
  | "conflict"
  | "capacity_limited"
  | "unavailable"
  | "projection_unavailable"
  | "food_projection_unavailable"
  | "snapshot_invalid"
  | "app_attest_key_missing"
  | "app_attest_counter_conflict"
  | "database_query_canceled"
  | "database_timeout"
  | "database_connection"
  | "database_capacity"
  | "dependency_connection"
  | "unexpected";

export interface RequestDiagnostic {
  readonly event: "http_request_completed";
  readonly timestamp: string;
  readonly service: DiagnosticService;
  readonly route: DiagnosticRoute;
  readonly requestId: string;
  readonly status: number;
  readonly durationMs: number;
  readonly errorCategory: DiagnosticErrorCategory;
}

export interface RequestDiagnosticOptions {
  readonly sink?: (record: RequestDiagnostic) => void;
  readonly now?: () => Date;
  readonly monotonicMilliseconds?: () => number;
}

interface RequestState {
  readonly startedAt: number;
  errorCategory?: DiagnosticErrorCategory;
}

export function installRequestDiagnostics(
  app: FastifyInstance,
  service: DiagnosticService,
  options: RequestDiagnosticOptions = {},
): { readonly recordError: (request: FastifyRequest, error: unknown) => void } {
  const now = options.now ?? (() => new Date());
  const monotonicMilliseconds = options.monotonicMilliseconds ?? (() => performance.now());
  const requests = new WeakMap<FastifyRequest, RequestState>();

  app.addHook("onRequest", async (request, reply) => {
    requests.set(request, { startedAt: monotonicMilliseconds() });
    reply.header("X-Request-ID", request.id);
  });
  app.addHook("onResponse", async (request, reply) => {
    const state = requests.get(request);
    if (state === undefined) {
      return;
    }
    requests.delete(request);
    // Construct an allowlist record; never serialize request, reply, or error objects.
    const elapsed = monotonicMilliseconds() - state.startedAt;
    const record: RequestDiagnostic = {
      event: "http_request_completed",
      timestamp: now().toISOString(),
      service,
      route: diagnosticRoute(request.routeOptions.url),
      requestId: request.id,
      status: reply.statusCode,
      durationMs: Number.isFinite(elapsed) ? Math.max(0, Math.round(elapsed)) : 0,
      errorCategory: state.errorCategory ?? categoryForStatus(reply.statusCode),
    };
    try {
      options.sink?.(record);
    } catch {
      // Diagnostics must not change an HTTP outcome or serialize a sink failure.
    }
  });

  return {
    recordError(request, error) {
      const state = requests.get(request);
      if (state !== undefined) {
        state.errorCategory = categoryForError(error);
      }
    },
  };
}

export function writeRequestDiagnostic(record: RequestDiagnostic): void {
  process.stdout.write(`${JSON.stringify(record)}\n`);
}

function diagnosticRoute(route: string | undefined): DiagnosticRoute {
  switch (route) {
    case "/health":
      return "health";
    case "/v1/charging-parks/search":
      return "charging_park_search";
    case "/v1/error-reports":
      return "user_error_report";
    case "/v1/auth/app-attest/challenge":
      return "app_attest_challenge";
    case "/v1/auth/app-attest/attest":
      return "app_attest_attestation";
    case "/v1/auth/app-attest/assert":
      return "app_attest_assertion";
    default:
      return "unknown";
  }
}

function categoryForStatus(status: number): DiagnosticErrorCategory {
  if (status < 400) {
    return "none";
  }
  switch (status) {
    case 400:
    case 415:
      return "invalid_request";
    case 401:
    case 403:
      return "unauthorized";
    case 404:
      return "not_found";
    case 409:
      return "conflict";
    case 413:
      return "body_too_large";
    case 429:
      return "capacity_limited";
    case 503:
      return "unavailable";
    default:
      return "unexpected";
  }
}

function categoryForError(error: unknown): DiagnosticErrorCategory {
  if (error instanceof InvalidUserErrorReportError) return "invalid_request";
  if (error instanceof UserErrorReportConflictError || error instanceof UserErrorReportWithdrawnError) return "conflict";
  if (error instanceof UserErrorReportCapacityError) return "capacity_limited";
  if (error instanceof NoProjectionAvailableError) {
    return "projection_unavailable";
  }
  if (error instanceof FoodPOIDataUnavailableError) {
    return "food_projection_unavailable";
  }
  if (error instanceof InvalidPaginationTokenError) {
    return "snapshot_invalid";
  }
  if (error instanceof AppAttestKeyNotRegisteredError) {
    return "app_attest_key_missing";
  }
  if (error instanceof AppAttestCounterConflictError) {
    return "app_attest_counter_conflict";
  }
  if (error instanceof AppAttestAuthenticationRejectedError) {
    return "unauthorized";
  }
  if (error instanceof InvalidSearchRequestError || error instanceof InvalidAppAttestRequestError) {
    return "invalid_request";
  }
  if (typeof error !== "object" || error === null) {
    return "unexpected";
  }
  if ("validation" in error && error.validation !== undefined) {
    return "invalid_request";
  }
  const code = "code" in error ? error.code : undefined;
  switch (code) {
    case "FST_ERR_CTP_BODY_TOO_LARGE":
      return "body_too_large";
    case "FST_ERR_CTP_INVALID_JSON_BODY":
    case "FST_ERR_CTP_EMPTY_JSON_BODY":
    case "FST_ERR_CTP_INVALID_MEDIA_TYPE":
      return "invalid_request";
    case "57014":
      return "database_query_canceled";
    case "08000":
    case "08001":
    case "08003":
    case "08004":
    case "08006":
    case "08007":
    case "08P01":
    case "57P01":
    case "57P02":
    case "57P03":
      return "database_connection";
    case "53300":
      return "database_capacity";
    case "ECONNREFUSED":
    case "ECONNRESET":
    case "ETIMEDOUT":
    case "EHOSTUNREACH":
    case "ENETUNREACH":
      return "dependency_connection";
    default:
      // node-postgres's client-side query deadline currently has no error code.
      // Match its fixed library message without ever including message text in output.
      return "message" in error && error.message === "Query read timeout"
        ? "database_timeout"
        : "unexpected";
  }
}
