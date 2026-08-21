import { randomUUID } from "node:crypto";

import Fastify, { type FastifyInstance } from "fastify";

import {
  NoProjectionAvailableError,
  FoodPOIDataUnavailableError,
  UnavailableCandidateSearch,
  type CandidateSearching,
} from "../application/candidate-search.js";
import { InvalidPaginationTokenError } from "../application/signed-pagination.js";
import type { SearchRequest } from "../domain/candidate-search.js";
import {
  BearerTokenAuthenticator,
  type SearchAuthenticating,
} from "./bearer-authentication.js";
import {
  InvalidSearchRequestError,
  validateSearchRequest,
} from "./search-request-validation.js";
import { problemSchema, searchRequestSchema, searchResponseSchema } from "./schemas.js";
import { searchRequestLimits } from "./search-request-limits.js";

interface AppDependencies {
  readonly candidateSearch?: CandidateSearching;
  readonly makeErrorId?: () => string;
  readonly searchAuthenticator?: SearchAuthenticating;
  readonly searchBearerToken?: string;
  readonly maximumConcurrentSearches?: number;
}

export function createApp(dependencies: AppDependencies = {}): FastifyInstance {
  const candidateSearch = dependencies.candidateSearch ?? new UnavailableCandidateSearch();
  const makeErrorId = dependencies.makeErrorId ?? randomUUID;
  const searchAuthenticator =
    dependencies.searchAuthenticator ??
    new BearerTokenAuthenticator(
      dependencies.searchBearerToken ?? requiredEnvironmentValue("SEARCH_API_BEARER_TOKEN"),
    );
  const searchAdmission = new SearchAdmissionController(
    dependencies.maximumConcurrentSearches ?? searchRequestLimits.maximumConcurrentSearches,
  );
  const app = Fastify({
    logger: false,
    bodyLimit: searchRequestLimits.maximumBodyBytes,
    ajv: {
      customOptions: {
        coerceTypes: false,
        removeAdditional: false,
        useDefaults: false,
      },
    },
  });

  app.setErrorHandler((error, request, reply) => {
    const errorId = makeErrorId();

    if (isFastifyValidationError(error) || error instanceof InvalidSearchRequestError) {
      return reply.status(400).type("application/problem+json").send({
        type: "urn:nextstop:error:invalid-search-request",
        title: "Invalid route or criteria",
        status: 400,
        detail: "The request does not match the candidate-search contract.",
        errorId,
      });
    }

    if (isRequestBodyTooLargeError(error)) {
      return reply.status(413).type("application/problem+json").send({
        type: "urn:nextstop:error:request-too-large",
        title: "Request body too large",
        status: 413,
        detail: "The request exceeds the candidate-search body limit.",
        errorId,
      });
    }

    if (error instanceof NoProjectionAvailableError) {
      return reply.status(503).type("application/problem+json").send({
        type: "urn:nextstop:error:projection-unavailable",
        title: "Charging data unavailable",
        status: 503,
        detail: error.message,
        errorId,
      });
    }

    if (error instanceof FoodPOIDataUnavailableError) {
      return reply.status(503).type("application/problem+json").send({
        type: "urn:nextstop:error:food-poi-unavailable",
        title: "Restaurant data unavailable",
        status: 503,
        detail: error.message,
        errorId,
      });
    }

    if (error instanceof InvalidPaginationTokenError) {
      return reply.status(409).type("application/problem+json").send({
        type: "urn:nextstop:error:invalid-pagination-token",
        title: "Invalid candidate snapshot",
        status: 409,
        detail: error.message,
        errorId,
      });
    }

    request.log.error({ errorId, err: error }, "Request failed");
    return reply.status(500).type("application/problem+json").send({
      type: "urn:nextstop:error:internal",
      title: "Internal server error",
      status: 500,
      errorId,
    });
  });

  app.get("/health", () => ({ status: "ok" }));

  app.post<{ Body: SearchRequest }>(
    "/v1/charging-parks/search",
    {
      onRequest: async (request, reply) => {
        if (!searchAuthenticator.isAuthorized(request.headers.authorization)) {
          const errorId = makeErrorId();
          await reply
            .status(401)
            .header("WWW-Authenticate", 'Bearer realm="nextstop-search"')
            .type("application/problem+json")
            .send({
              type: "urn:nextstop:error:unauthorized",
              title: "Authentication required",
              status: 401,
              detail: "Valid API credentials are required.",
              errorId,
            });
        }
      },
      schema: {
        body: searchRequestSchema,
        response: {
          200: searchResponseSchema,
          400: problemSchema,
          401: problemSchema,
          413: problemSchema,
          429: problemSchema,
          409: problemSchema,
          503: problemSchema,
        },
      },
    },
    async (request, reply) => {
      const release = searchAdmission.tryAcquire();
      if (release === undefined) {
        return reply
          .status(429)
          .header("Retry-After", "1")
          .type("application/problem+json")
          .send({
            type: "urn:nextstop:error:search-capacity-exhausted",
            title: "Search capacity exhausted",
            status: 429,
            detail: "Too many candidate searches are already in progress.",
            errorId: makeErrorId(),
          });
      }
      try {
        validateSearchRequest(request.body);
        const response = await candidateSearch.search(request.body);
        return reply.status(200).send(response);
      } finally {
        release();
      }
    },
  );

  return app;
}

class SearchAdmissionController {
  private activeSearches = 0;

  constructor(private readonly maximumConcurrentSearches: number) {
    if (!Number.isSafeInteger(maximumConcurrentSearches) || maximumConcurrentSearches < 1) {
      throw new Error("maximumConcurrentSearches must be a positive integer.");
    }
  }

  tryAcquire(): (() => void) | undefined {
    if (this.activeSearches >= this.maximumConcurrentSearches) {
      return undefined;
    }
    this.activeSearches += 1;
    let released = false;
    return () => {
      if (!released) {
        this.activeSearches -= 1;
        released = true;
      }
    };
  }
}

function requiredEnvironmentValue(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`${name} must be configured.`);
  }
  return value;
}

function isFastifyValidationError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "validation" in error &&
    error.validation !== undefined
  );
}

function isRequestBodyTooLargeError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "FST_ERR_CTP_BODY_TOO_LARGE"
  );
}
