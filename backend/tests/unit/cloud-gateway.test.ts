import assert from "node:assert/strict";
import test from "node:test";
import { createCloudGateway, gatewayClientAddress, gatewayOrigin } from "../../src/api/cloud-gateway.js";
import { CloudIdentityTokens } from "../../src/runtime/cloud-identity-tokens.js";
import { createSimulatorTokenApp } from "../../src/api/simulator-token-app.js";
import { AccessTokenCodec } from "../../src/api/access-token.js";

const origins = { api: "https://nextstop-api-353471052580.europe-west1.run.app",
  auth: "https://nextstop-auth-353471052580.europe-west1.run.app" };
const identityToken = () => Promise.resolve("service-identity");

void test("gateway pins private revision targets but authenticates to the base service, preserving app authorization only", async (t) => {
  const revision = origins.api.replace("https://", "https://r-0123456789ab---");
  const app = createCloudGateway({ origins: { ...origins, api: revision }, audiences: origins,
    identityToken: (audience) => { assert.equal(audience, origins.api); return identityToken(); },
    fetch: (url, init) => {
      assert.equal(url, `${revision}/v1/charging-parks/search`);
      assert.equal(init?.method, "POST"); assert.equal(init.redirect, "error");
      assert.deepEqual(init.headers, { "X-Serverless-Authorization": "Bearer service-identity", Accept: "application/json",
        Authorization: "Bearer app-token", "Content-Type": "application/json" });
      assert.ok(Buffer.isBuffer(init.body)); assert.equal(init.body.toString(), '{"route":"synthetic"}');
      return Promise.resolve(new Response('{"result":[]}', { status: 200, headers: { "content-type": "application/json",
        "set-cookie": "never-forward", "x-request-id": "synthetic" } }));
    } });
  t.after(() => app.close());
  const reply = await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: { route: "synthetic" },
    headers: { authorization: "Bearer app-token", "x-serverless-authorization": "spoof", cookie: "private",
      "x-forwarded-for": "spoof, 192.0.2.1", "x-cloud-trace-context": "private" } });
  assert.equal(reply.statusCode, 200); assert.deepEqual(reply.json(), { result: [] });
  assert.equal(reply.headers["set-cookie"], undefined); assert.equal(reply.headers["cache-control"], "no-store");
  assert.equal(reply.headers["x-request-id"], "synthetic");
});

void test("gateway rejects alternate targets, injected paths, compressed and excessive bodies before contacting private services", async (t) => {
  let calls = 0;
  const app = createCloudGateway({ origins, identityToken, fetch: () => { calls += 1; return Promise.resolve(new Response("{}")); } });
  t.after(() => app.close());
  for (const [url, code] of [["/v1/charging-parks/search?url=https://private",400],["/v1/unknown",404]] as const) {
    assert.equal((await app.inject({ method: "POST", url, payload: {} })).statusCode, code);
  }
  assert.equal((await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: {},
    headers: { "content-encoding": "gzip" } })).statusCode, 400);
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", payload: { text: "x".repeat(128*1024) } })).statusCode, 413);
  assert.equal(calls, 0);
  for (const target of ["http://nextstop-api.run.app", "https://attacker.example", `${origins.api}/private`,
    `${origins.api}?secret`, "https://user:pass@nextstop-api.run.app"]) assert.throws(() => gatewayOrigin(target));
  assert.throws(() => createCloudGateway({ origins, audiences: { api: origins.auth, auth: origins.auth }, identityToken }));
});

void test("gateway separates ingress budgets and ignores spoofed forwarded prefixes", async (t) => {
  let now = 0;
  const app = createCloudGateway({ origins, identityToken, now: () => now,
    fetch: () => Promise.resolve(new Response("{}", { status: 200 })) });
  t.after(() => app.close());
  for (let i=0;i<5;i++) assert.equal((await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: {},
    headers: { "x-forwarded-for": `192.0.2.${i}, 198.51.100.2` } })).statusCode, 200);
  assert.equal((await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: {},
    headers: { "x-forwarded-for": "203.0.113.2, 198.51.100.2" } })).statusCode, 429);
  assert.equal((await app.inject({ method: "POST", url: "/v1/auth/app-attest/challenge", payload: {},
    headers: { "x-forwarded-for": "198.51.100.2" } })).statusCode, 200);
  now=1000;
  assert.equal((await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: {},
    headers: { "x-forwarded-for": "198.51.100.2" } })).statusCode, 200);
  assert.equal(gatewayClientAddress("spoof, 2001:db8::1", "peer"), "2001:db8::1");
  assert.equal(gatewayClientAddress("invalid", "peer"), "peer");
});

void test("upstream failures stay retryable and private; oversized replies are rejected", async (t) => {
  for (const transport of [() => Promise.reject(new Error("private route and secret")),
    () => Promise.resolve(new Response("x".repeat(8*1024*1024+1)))]) {
    const app = createCloudGateway({ origins, identityToken, fetch: transport }); t.after(() => app.close());
    const reply = await app.inject({ method: "POST", url: "/v1/charging-parks/search", payload: {} });
    assert.equal(reply.statusCode, 502); assert.doesNotMatch(reply.body, /private|route|secret/u);
  }
});

void test("metadata identities are coalesced, cached by audience and refreshed before expiration", async () => {
  let now = 0, calls = 0;
  const tokens = new CloudIdentityTokens((url, init) => {
    calls += 1; assert.ok(url instanceof URL);
    assert.equal(url.hostname, "metadata.google.internal");
    assert.deepEqual(init?.headers, { "Metadata-Flavor": "Google" });
    const claims = Buffer.from(JSON.stringify({ aud: url.searchParams.get("audience"), exp: Math.floor(now/1000)+120 })).toString("base64url");
    return Promise.resolve(new Response(`header.${claims}.signature`));
  }, () => now);
  const [a,b] = await Promise.all([tokens.get(origins.api),tokens.get(origins.api)]);
  assert.equal(a,b); assert.equal(calls,1); await tokens.get(origins.api); assert.equal(calls,1);
  await tokens.get(origins.auth); assert.equal(calls,2); now=61_000; await tokens.get(origins.api); assert.equal(calls,3);
  await assert.rejects(tokens.get("https://private.example")); assert.equal(calls,3);
});

void test("metadata failure never caches malformed or wrong-audience tokens", async () => {
  for (const body of ["private-error", "x".repeat(8193), "header."+Buffer.from(JSON.stringify({ aud: origins.auth, exp: 3600 })).toString("base64url")+".signature"]) {
    let calls = 0;
    const tokens = new CloudIdentityTokens(() => { calls+=1; return Promise.resolve(new Response(body)); }, () => 0);
    await assert.rejects(tokens.get(origins.api)); await assert.rejects(tokens.get(origins.api)); assert.equal(calls,2);
  }
});

void test("IAM-only simulator broker issues bounded simulator tokens and rejects browser/body requests", async (t) => {
  const codec = new AccessTokenCodec("synthetic-key-long-enough-for-testing");
  const app = createSimulatorTokenApp(codec, () => 0); t.after(() => app.close());
  for (const request of [{ method: "POST" as const, url: "/token?x=1" },
    { method: "POST" as const, url: "/token", headers: { origin: "https://browser.example" } },
    { method: "POST" as const, url: "/token", payload: {} }]) {
    assert.equal((await app.inject(request)).statusCode, 400);
  }
  const first = await app.inject({ method: "POST", url: "/token" });
  assert.equal(first.statusCode, 200); assert.equal(first.headers["cache-control"], "no-store");
  const result = first.json<{ accessToken: string }>(); assert.ok(codec.verify(result.accessToken));
  const claims: unknown = JSON.parse(Buffer.from(result.accessToken.split(".")[1]!,"base64url").toString());
  assert.ok(typeof claims === "object" && claims !== null && "client" in claims);
  assert.equal(claims.client, "simulator");
  for(let i=1;i<30;i++) assert.equal((await app.inject({ method: "POST", url: "/token" })).statusCode,200);
  assert.equal((await app.inject({ method: "POST", url: "/token" })).statusCode,429);
});
