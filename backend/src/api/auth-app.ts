import { randomUUID } from "node:crypto";

import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";

import {
  AppAttestAuthenticationRejectedError,
  AppAttestCounterConflictError,
  AppAttestKeyNotRegisteredError,
  InvalidAppAttestRequestError,
  type AppAttestAuthenticating,
  type AppAttestPurpose,
} from "../application/app-attest-authentication.js";
import {
  accessTokenResponseSchema,
  appAttestAssertionRequestSchema,
  appAttestAttestationRequestSchema,
  appAttestChallengeRequestSchema,
  appAttestChallengeResponseSchema,
  problemSchema,
} from "./schemas.js";

interface AuthAppDependencies {
  readonly appAttestAuthentication?: AppAttestAuthenticating;
  readonly makeErrorId?: () => string;
  readonly maximumConcurrentAuthentications?: number;
  readonly maximumGlobalChallengesPerMinute?: number;
  readonly maximumGlobalProofsPerMinute?: number;
  readonly nowMilliseconds?: () => number;
}

export function createAuthApp(dependencies: AuthAppDependencies = {}): FastifyInstance {
  const makeErrorId = dependencies.makeErrorId ?? randomUUID;
  const authenticationAdmission = new AdmissionController(
    dependencies.maximumConcurrentAuthentications ?? 2,
  );
  const nowMilliseconds = dependencies.nowMilliseconds ?? Date.now;
  const challengeRateLimit = new FixedWindowRateLimiter(
    dependencies.maximumGlobalChallengesPerMinute ?? 120,
    60_000,
    nowMilliseconds,
  );
  const proofRateLimit = new FixedWindowRateLimiter(
    dependencies.maximumGlobalProofsPerMinute ?? 60,
    60_000,
    nowMilliseconds,
  );
  const app = Fastify({
    logger: false,
    bodyLimit: 192 * 1_024,
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
    if (error instanceof InvalidAppAttestRequestError || isFastifyValidationError(error)) {
      return reply.status(400).type("application/problem+json").send({
        type: "urn:nextstop:error:invalid-app-attest-request",
        title: "Invalid App Attest request",
        status: 400,
        detail: "The request does not match the App Attest contract.",
        errorId,
      });
    }
    if (error instanceof AppAttestKeyNotRegisteredError) {
      return reply.status(404).type("application/problem+json").send({
        type: "urn:nextstop:error:app-attest-key-not-registered",
        title: "App Attest key not registered",
        status: 404,
        detail: "The App Attest key must be registered again.",
        errorId,
      });
    }
    if (error instanceof AppAttestCounterConflictError) {
      return reply.status(409).type("application/problem+json").send({
        type: "urn:nextstop:error:app-attest-counter-conflict",
        title: "App Attest counter conflict",
        status: 409,
        detail: "A newer assertion for this key was already accepted.",
        errorId,
      });
    }
    if (error instanceof AppAttestAuthenticationRejectedError) {
      return reply
        .status(401)
        .header("WWW-Authenticate", 'Bearer realm="nextstop-attestation"')
        .type("application/problem+json")
        .send({
          type: "urn:nextstop:error:app-attest-rejected",
          title: "App authentication rejected",
          status: 401,
          detail: "The app proof could not be verified.",
          errorId,
        });
    }
    if (isRequestBodyTooLargeError(error)) {
      return reply.status(413).type("application/problem+json").send({
        type: "urn:nextstop:error:request-too-large",
        title: "Request body too large",
        status: 413,
        detail: "The request exceeds the endpoint body limit.",
        errorId,
      });
    }
    request.log.error({ errorId, err: error }, "Authentication request failed");
    return reply.status(500).type("application/problem+json").send({
      type: "urn:nextstop:error:internal",
      title: "Internal server error",
      status: 500,
      errorId,
    });
  });

  app.get("/health", () => ({ status: "ok" }));

  app.post<{ Body: { readonly keyId: string; readonly purpose: AppAttestPurpose } }>(
    "/v1/auth/app-attest/challenge",
    {
      bodyLimit: 1_024,
      schema: {
        body: appAttestChallengeRequestSchema,
        response: {
          200: appAttestChallengeResponseSchema,
          400: problemSchema,
          429: problemSchema,
          503: problemSchema,
        },
      },
    },
    async (request, reply) => {
      if (dependencies.appAttestAuthentication === undefined) {
        return authenticationUnavailable(reply, makeErrorId());
      }
      if (!challengeRateLimit.tryConsume("global")) {
        return authenticationRateLimited(reply, makeErrorId());
      }
      return reply
        .status(200)
        .send(await dependencies.appAttestAuthentication.createChallenge(request.body));
    },
  );

  app.post<{
    Body: {
      readonly keyId: string;
      readonly challengeId: string;
      readonly attestationObject: string;
    };
  }>(
    "/v1/auth/app-attest/attest",
    {
      bodyLimit: 192 * 1_024,
      schema: {
        body: appAttestAttestationRequestSchema,
        response: {
          200: accessTokenResponseSchema,
          400: problemSchema,
          401: problemSchema,
          413: problemSchema,
          429: problemSchema,
          503: problemSchema,
        },
      },
    },
    async (request, reply) =>
      withProofAdmission(
        reply,
        proofRateLimit,
        authenticationAdmission,
        makeErrorId,
        dependencies.appAttestAuthentication,
        async (authentication) => authentication.attest(request.body),
      ),
  );

  app.post<{
    Body: {
      readonly keyId: string;
      readonly challengeId: string;
      readonly assertionObject: string;
    };
  }>(
    "/v1/auth/app-attest/assert",
    {
      bodyLimit: 24 * 1_024,
      schema: {
        body: appAttestAssertionRequestSchema,
        response: {
          200: accessTokenResponseSchema,
          400: problemSchema,
          401: problemSchema,
          404: problemSchema,
          409: problemSchema,
          413: problemSchema,
          429: problemSchema,
          503: problemSchema,
        },
      },
    },
    async (request, reply) =>
      withProofAdmission(
        reply,
        proofRateLimit,
        authenticationAdmission,
        makeErrorId,
        dependencies.appAttestAuthentication,
        async (authentication) => authentication.assert(request.body),
      ),
  );

  return app;
}

async function withProofAdmission(
  reply: FastifyReply,
  rateLimit: FixedWindowRateLimiter,
  admission: AdmissionController,
  makeErrorId: () => string,
  authentication: AppAttestAuthenticating | undefined,
  operation: (authentication: AppAttestAuthenticating) => Promise<unknown>,
): Promise<FastifyReply> {
  if (authentication === undefined) {
    return authenticationUnavailable(reply, makeErrorId());
  }
  if (!rateLimit.tryConsume("global")) {
    return authenticationRateLimited(reply, makeErrorId());
  }
  const release = admission.tryAcquire();
  if (release === undefined) {
    return authenticationRateLimited(reply, makeErrorId());
  }
  try {
    return reply.status(200).send(await operation(authentication));
  } finally {
    release();
  }
}

class AdmissionController {
  private activeOperations = 0;

  constructor(private readonly maximumConcurrentOperations: number) {
    if (!Number.isSafeInteger(maximumConcurrentOperations) || maximumConcurrentOperations < 1) {
      throw new Error("maximumConcurrentAuthentications must be a positive integer.");
    }
  }

  tryAcquire(): (() => void) | undefined {
    if (this.activeOperations >= this.maximumConcurrentOperations) {
      return undefined;
    }
    this.activeOperations += 1;
    let released = false;
    return () => {
      if (!released) {
        this.activeOperations -= 1;
        released = true;
      }
    };
  }
}

class FixedWindowRateLimiter {
  private readonly windows = new Map<string, { count: number; startedAt: number }>();

  constructor(
    private readonly maximumRequests: number,
    private readonly windowMilliseconds: number,
    private readonly now: () => number,
  ) {}

  tryConsume(key: string): boolean {
    const now = this.now();
    if (!Number.isFinite(now)) {
      return false;
    }
    const current = this.windows.get(key);
    if (current === undefined || now - current.startedAt >= this.windowMilliseconds) {
      if (this.windows.size >= 10_000) {
        this.removeExpired(now);
        if (this.windows.size >= 10_000) {
          return false;
        }
      }
      this.windows.set(key, { count: 1, startedAt: now });
      return true;
    }
    if (current.count >= this.maximumRequests) {
      return false;
    }
    current.count += 1;
    return true;
  }

  private removeExpired(now: number): void {
    for (const [key, window] of this.windows) {
      if (now - window.startedAt >= this.windowMilliseconds) {
        this.windows.delete(key);
      }
    }
  }
}

function authenticationUnavailable(reply: FastifyReply, errorId: string): FastifyReply {
  return reply.status(503).type("application/problem+json").send({
    type: "urn:nextstop:error:app-attest-unavailable",
    title: "App authentication unavailable",
    status: 503,
    detail: "App Attest is not configured on this environment.",
    errorId,
  });
}

function authenticationRateLimited(reply: FastifyReply, errorId: string): FastifyReply {
  return reply
    .status(429)
    .header("Retry-After", "60")
    .type("application/problem+json")
    .send({
      type: "urn:nextstop:error:authentication-rate-limited",
      title: "Authentication capacity exhausted",
      status: 429,
      detail: "Too many authentication requests were received.",
      errorId,
    });
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
