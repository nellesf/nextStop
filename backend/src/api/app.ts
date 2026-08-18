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
  InvalidSearchRequestError,
  validateSearchRequest,
} from "./search-request-validation.js";
import { problemSchema, searchRequestSchema, searchResponseSchema } from "./schemas.js";

interface AppDependencies {
  readonly candidateSearch?: CandidateSearching;
  readonly makeErrorId?: () => string;
}

export function createApp(dependencies: AppDependencies = {}): FastifyInstance {
  const candidateSearch = dependencies.candidateSearch ?? new UnavailableCandidateSearch();
  const makeErrorId = dependencies.makeErrorId ?? randomUUID;
  const app = Fastify({
    logger: false,
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
      schema: {
        body: searchRequestSchema,
        response: {
          200: searchResponseSchema,
          400: problemSchema,
          409: problemSchema,
          503: problemSchema,
        },
      },
    },
    async (request, reply) => {
      validateSearchRequest(request.body);
      const response = await candidateSearch.search(request.body);
      return reply.status(200).send(response);
    },
  );

  return app;
}

function isFastifyValidationError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "validation" in error &&
    error.validation !== undefined
  );
}
