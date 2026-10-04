import { isIP } from "node:net";
import { randomUUID } from "node:crypto";
import Fastify, { type FastifyInstance } from "fastify";
import { GatewayAdmission, type GatewayAdmissionClass } from "./gateway-admission.js";

type Backend = "api" | "auth";
type AdmissionClass = Extract<GatewayAdmissionClass, "api" | "auth" | "reports">;
const maximumHeaderBytes = 16 * 1024;
const maximumHeaderFields = 64;
const maximumURLLength = 256;
interface GatewayRoute { readonly path: string; readonly targetPath?: string; readonly backend: Backend;
  readonly methods: readonly ("GET" | "POST" | "DELETE")[]; readonly limit: number; readonly admission: AdmissionClass }
const routes: readonly GatewayRoute[] = [
  { path: "/ready", backend: "api", methods: ["GET"], limit: 0, admission: "api" },
  { path: "/ready/auth", targetPath: "/ready", backend: "auth", methods: ["GET"], limit: 0, admission: "auth" },
  { path: "/v1/charging-parks/search", backend: "api", methods: ["POST"], limit: 512 * 1024, admission: "api" },
  { path: "/v1/charging-parks/availability", backend: "api", methods: ["POST"], limit: 128 * 1024, admission: "api" },
  { path: "/v1/error-reports", backend: "api", methods: ["POST", "DELETE"], limit: 128 * 1024, admission: "reports" },
  ...["challenge", "attest", "assert"].map((suffix): GatewayRoute => ({
    path: `/v1/auth/app-attest/${suffix}`, backend: "auth", methods: ["POST"], limit: 512 * 1024, admission: "auth",
  })),
];

export interface GatewayDependencies {
  readonly origins: Readonly<Record<Backend, string>>;
  readonly audiences?: Readonly<Record<Backend, string>>;
  readonly identityToken: (origin: string) => Promise<string>;
  readonly fetch?: typeof fetch;
  readonly now?: () => number;
}

/** Exact, operator-configured Cloud Run destinations. Never use a caller's host/path as an upstream. */
export function gatewayOrigin(value: string): string {
  const url = new URL(value);
  if (url.protocol !== "https:" || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)?\.run\.app$/u.test(url.hostname) ||
      url.port !== "" || url.username !== "" || url.password !== "" || url.pathname !== "/" ||
      url.search !== "" || url.hash !== "") throw new Error("Invalid private Cloud Run origin.");
  return url.origin;
}

/** Direct Cloud Run ingress appends the peer address. Untrusted prefixes are never used. */
export function gatewayClientAddress(forwarded: string | string[] | undefined, peer: string): string {
  const last = typeof forwarded === "string" ? forwarded.slice(forwarded.lastIndexOf(",") + 1).trim() : undefined;
  return last !== undefined && isIP(last) !== 0 ? last : peer;
}

function boundedHeaders(headers: readonly string[]): boolean {
  if (headers.length > maximumHeaderFields * 2) return false;
  let bytes = 0;
  for (const value of headers) {
    bytes += Buffer.byteLength(value) + 2;
    if (bytes > maximumHeaderBytes) return false;
  }
  return true;
}

export function createCloudGateway(dependencies: GatewayDependencies): FastifyInstance {
  const origins = { api: gatewayOrigin(dependencies.origins.api), auth: gatewayOrigin(dependencies.origins.auth) };
  const audiences = { api: gatewayOrigin(dependencies.audiences?.api ?? origins.api),
    auth: gatewayOrigin(dependencies.audiences?.auth ?? origins.auth) };
  for (const backend of ["api", "auth"] as const) {
    const host = new URL(origins[backend]).hostname;
    const audienceHost = new URL(audiences[backend]).hostname;
    if (host !== audienceHost && !host.endsWith(`---${audienceHost}`)) {
      throw new Error("Revision origin and service audience must identify the same Cloud Run service.");
    }
  }
  const transport = dependencies.fetch ?? fetch;
  const admission = new GatewayAdmission(dependencies.now ?? Date.now);
  const app = Fastify({ logger: false, bodyLimit: 512 * 1024, requestTimeout: 10_000,
    http: { maxHeaderSize: maximumHeaderBytes, headersTimeout: 10_000 },
    routerOptions: {
      // All public routes reject query strings, so never parse attacker-supplied query objects.
      querystringParser: () => ({}),
      onBadUrl: (_path, request, response) => {
        // Router-level malformed URLs bypass Fastify's normal onRequest hook.
        const address = gatewayClientAddress(request.headers["x-forwarded-for"], request.socket.remoteAddress ?? "unknown");
        const status = admission.allows(address, "invalid") ? 400 : 429;
        response.writeHead(status, { "Content-Type": "application/problem+json", "Cache-Control": "no-store",
          ...(status === 429 ? { "Retry-After": "5" } : {}) });
        response.end(JSON.stringify(problem(status)));
      },
    },
  });
  app.removeAllContentTypeParsers();
  app.addContentTypeParser("application/json", { parseAs: "buffer" }, (_request, body, done) => done(null, body));
  app.addHook("onRequest", async (request, reply) => {
    reply.header("Cache-Control", "no-store").header("X-Content-Type-Options", "nosniff")
      .header("Referrer-Policy", "no-referrer").header("Strict-Transport-Security", "max-age=31536000")
      .header("X-Edge-Request-ID", randomUUID());
    const route = routes.find((candidate) => candidate.path === request.routeOptions.url);
    const health = request.routeOptions.url === "/health";
    const exactPath = request.url === (health ? "/health" : route?.path);
    const bodyless = health || route?.limit === 0;
    const unexpectedBody = bodyless && (request.headers["transfer-encoding"] !== undefined ||
      (request.headers["content-length"] !== undefined && request.headers["content-length"] !== "0"));
    const invalid = !exactPath || unexpectedBody || request.headers["content-encoding"] !== undefined ||
      request.url.length > maximumURLLength || !boundedHeaders(request.raw.rawHeaders);
    // Public callers must not be able to exhaust Cloud Run's own liveness probe
    // and force a restart (which would also reset every admission budget).
    // Only this exact bodyless, bounded request does no DB/identity/upstream work.
    if (health && !invalid) return;
    const group = invalid ? "invalid" : route?.admission ?? "invalid";
    const address = gatewayClientAddress(request.headers["x-forwarded-for"], request.ip);
    if (!admission.allows(address, group)) {
      return reply.status(429).header("Retry-After", group === "reports" ? "60" : "5").send(problem(429));
    }
    // Reject unknown/invalid routes before buffering or parsing their request body.
    if (invalid) {
      const status = route !== undefined || health || request.url.length > maximumURLLength ? 400 : 404;
      return reply.status(status).send(problem(status));
    }
  });
  app.setErrorHandler((error, _request, reply) => {
    const status = typeof error === "object" && error !== null && "statusCode" in error &&
      [400, 413, 415].includes(Number(error.statusCode)) ? Number(error.statusCode) : 502;
    return reply.status(status).type("application/problem+json").send(problem(status));
  });
  app.setNotFoundHandler((_request, reply) => reply.status(404).send(problem(404)));
  app.get("/health", () => ({ status: "ok" }));
  let active = 0;
  for (const route of routes) app.route({ method: [...route.methods], url: route.path, bodyLimit: Math.max(1, route.limit),
    handler: async (request, reply) => {
      if (active >= 32) return reply.status(429).header("Retry-After", "5").send(problem(429));
      active += 1;
      const controller = new AbortController();
      const cancel = () => { controller.abort(); };
      request.raw.once("aborted", cancel);
      try {
        const origin = origins[route.backend];
        const token = await dependencies.identityToken(audiences[route.backend]);
        const headers: Record<string, string> = { "X-Serverless-Authorization": `Bearer ${token}`, "Accept": "application/json" };
        // Drop all caller forwarding, IAM, tracing, cookie and hop-by-hop headers.
        if (request.headers.authorization !== undefined) headers.Authorization = request.headers.authorization;
        if (request.headers["content-type"] !== undefined) headers["Content-Type"] = request.headers["content-type"];
        const body = request.body === undefined ? undefined : Buffer.isBuffer(request.body) ? request.body : undefined;
        const response = await transport(`${origin}${route.targetPath ?? route.path}`, { method: request.method,
          headers, ...(body === undefined ? {} : { body }), redirect: "error",
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(55_000)]) });
        const payload = await boundedResponse(response, 8 * 1024 * 1024);
        for (const name of ["content-type", "retry-after", "www-authenticate", "x-request-id"]) {
          const value = response.headers.get(name);
          if (value !== null) reply.header(name, value);
        }
        return reply.status(response.status).send(payload);
      } catch {
        // No URLs, routes, headers, identifiers or provider data enter logs.
        return reply.status(502).type("application/problem+json").send(problem(502));
      } finally { active -= 1; request.raw.removeListener("aborted", cancel); }
    },
  });
  return app;
}

async function boundedResponse(response: Response, maximum: number): Promise<Buffer> {
  if (response.body === null) return Buffer.alloc(0);
  const chunks: Uint8Array[] = [];
  const reader = response.body.getReader();
  let size = 0;
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      const value: unknown = next.value;
      if (!(value instanceof Uint8Array)) throw new Error("Invalid upstream reply.");
      size += value.byteLength;
      if (size > maximum) throw new Error("Upstream response too large.");
      chunks.push(value);
    }
    return Buffer.concat(chunks, size);
  } finally { await reader.cancel(); }
}

function problem(status: number): object {
  return { type: `urn:nextstop:error:${status === 429 ? "rate-limited" : "gateway-request-failed"}`,
    title: "Request could not be completed", status, errorId: randomUUID() };
}
