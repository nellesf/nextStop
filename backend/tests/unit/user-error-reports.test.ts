import assert from "node:assert/strict";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createApp } from "../../src/api/app.js";
import type { RequestDiagnostic } from "../../src/api/request-diagnostics.js";
import {
  hashReportSecret, InvalidUserErrorReportError, UserErrorReportConflictError, UserErrorReportWithdrawnError,
  UserErrorReports, validateUserErrorReport, type StoredUserErrorReport, type UserErrorReportRepository,
  UserErrorReportAuthorizationError,
} from "../../src/application/user-error-reports.js";

const instant = new Date("2026-09-13T12:00:00.000Z");
const diagnostic = {
  id: randomUUID(), timestamp: "2026-09-11T06:49:15Z", operation: "candidateSearch",
  outcome: "failure", category: "offline", durationMilliseconds: 200, attempt: 1,
  httpStatus: 503, errorDomain: "url", errorCode: -1009,
  serverRequestID: randomUUID(), edgeRequestID: "01234567-89ab-cdef-0123-456789abcdef",
};
const diagnosticContext = { appVersion: "0.1.0", buildVersion: "42", operatingSystemVersion: "26.0.1" };
function submission() {
  return { schemaVersion: 1, reportId: randomUUID(), deletionToken: randomUUID(), consentVersion: "2026-09-13", message: "  Retry fixed the search.  ", includeDiagnostics: false };
}

class MemoryReports implements UserErrorReportRepository {
  readonly records = new Map<string, StoredUserErrorReport>();
  readonly withdrawn = new Set<string>();
  readonly deletionProofs = new Map<string, Buffer>();
  async save(report: StoredUserErrorReport) {
    await Promise.resolve();
    const existing = this.records.get(report.reportId);
    const proof = this.deletionProofs.get(report.reportId);
    if (proof !== undefined && !timingSafeEqual(proof, report.deletionTokenHash)) throw new UserErrorReportConflictError();
    if (existing !== undefined && (!timingSafeEqual(existing.deletionTokenHash, report.deletionTokenHash) || !timingSafeEqual(existing.payloadHash, report.payloadHash))) throw new UserErrorReportConflictError();
    if (this.withdrawn.has(report.reportId)) throw new UserErrorReportWithdrawnError();
    if (existing === undefined) this.records.set(report.reportId, report);
    this.deletionProofs.set(report.reportId, report.deletionTokenHash);
    const value = existing ?? report;
    return { created: existing === undefined, receipt: { reportId: value.reportId, receivedAt: value.receivedAt.toISOString(), expiresAt: value.expiresAt.toISOString() } };
  }
  hasDeletionCapability(id: string, hash: Buffer) {
    const proof = this.deletionProofs.get(id);
    return Promise.resolve(proof !== undefined && timingSafeEqual(proof, hash));
  }
  async delete(id: string, hash: Buffer, _now: Date, mayCreateTombstone = false) {
    await Promise.resolve();
    const proof = this.deletionProofs.get(id);
    if (proof === undefined) {
      if (!mayCreateTombstone) throw new UserErrorReportAuthorizationError();
      this.deletionProofs.set(id, hash);
    } else if (!timingSafeEqual(proof, hash)) {
      if (!mayCreateTombstone) throw new UserErrorReportAuthorizationError();
      return;
    }
    this.withdrawn.add(id);
  }
  purge() { return Promise.resolve(0); }
}

void test("user report validation mirrors the complete iOS allowlist and Unicode bounds", () => {
  const valid = { ...submission(), includeDiagnostics: true, diagnostics: [diagnostic] };
  const result = validateUserErrorReport(valid);
  assert.equal(result.message, "Retry fixed the search.");
  assert.equal(result.diagnostics?.[0]?.timestamp, "2026-09-11T06:49:15.000Z");
  assert.equal(result.diagnostics?.[0]?.edgeRequestID, diagnostic.edgeRequestID);
  assert.equal(validateUserErrorReport({ ...submission(), message: "😀".repeat(5_000) }).message.length, 10_000);
  const invalid = [
    { ...submission(), message: "😀".repeat(5_001) }, { ...submission(), message: " \n" },
    { ...submission(), message: "\ud800" }, { ...submission(), message: "\u0000" },
    { ...submission(), schemaVersion: "1" }, { ...submission(), consentVersion: "unknown" },
    { ...submission(), includeDiagnostics: 1 }, { ...submission(), diagnostics: [] },
    { ...submission(), includeDiagnostics: true }, { ...submission(), includeDiagnostics: true, diagnostics: [] },
    { ...valid, diagnostics: Array(201).fill(diagnostic) }, { ...valid, diagnostics: [diagnostic, diagnostic] },
    { ...valid, destination: "PRIVATE" }, { ...valid, reportId: "private" },
  ];
  for (const value of invalid) assert.throws(() => validateUserErrorReport(value), InvalidUserErrorReportError);
  for (const [key, value] of Object.entries({
    rawError: "PRIVATE", operation: "private", outcome: "private", category: "private", durationMilliseconds: 300_001,
    attempt: 4, httpStatus: 600, errorDomain: "PRIVATE", errorCode: -10_001,
    serverRequestID: "PRIVATE", edgeRequestID: "PRIVATE", timestamp: "2026-02-30T12:00:00Z",
  })) assert.throws(() => validateUserErrorReport({ ...valid, diagnostics: [{ ...diagnostic, [key]: value }] }), InvalidUserErrorReportError);
});

void test("submission hashes secrets, fixes retention, and omits logs unless explicitly selected", async () => {
  const repository = new MemoryReports();
  const reports = new UserErrorReports(repository, () => instant);
  const body = submission();
  const result = await reports.submit(body);
  assert.equal(result.receipt.expiresAt, "2026-10-13T12:00:00.000Z");
  const saved = [...repository.records.values()][0];
  assert.ok(saved);
  assert.equal(saved.deletionTokenHash.length, 32);
  assert.deepEqual(saved.deletionTokenHash, hashReportSecret(String(body.deletionToken)));
  assert.equal("diagnostics" in saved.payload, false);
  assert.equal("diagnosticContext" in saved.payload, false);
  assert.equal("deletionToken" in saved, false);
  assert.equal(JSON.stringify(saved).includes(String(body.deletionToken)), false);
  const retry = await reports.submit({ ...body, message: "Retry fixed the search." });
  assert.equal(retry.created, false);
  assert.deepEqual(retry.receipt, result.receipt);
  await assert.rejects(reports.submit({ ...body, message: "Changed" }), UserErrorReportConflictError);
});

void test("software context is optional, allowlisted, bounded, and requires the current log consent", () => {
  const withLogs = { ...submission(), includeDiagnostics: true, diagnostics: [diagnostic] };
  for (const consentVersion of ["2026-09-13", "2026-09-14"]) {
    assert.equal("diagnosticContext" in validateUserErrorReport({ ...withLogs, consentVersion }), false);
    assert.equal("diagnosticContext" in validateUserErrorReport({ ...submission(), consentVersion }), false);
  }
  const valid = { ...withLogs, consentVersion: "2026-09-14", diagnosticContext };
  assert.deepEqual(validateUserErrorReport(valid).diagnosticContext, diagnosticContext);
  assert.equal(validateUserErrorReport({ ...valid, diagnosticContext: { ...diagnosticContext, buildVersion: "999999999.999999999.999999999" } }).diagnosticContext?.buildVersion, "999999999.999999999.999999999");
  for (const context of [
    null, [], {}, { appVersion: "1.0", buildVersion: "42" },
    { ...diagnosticContext, deviceId: "PRIVATE" },
    { ...diagnosticContext, deviceModel: "iPhone17,1" },
  ]) assert.throws(() => validateUserErrorReport({ ...valid, diagnosticContext: context }), InvalidUserErrorReportError);
  for (const key of Object.keys(diagnosticContext)) {
    for (const value of ["", "1.", ".1", "1..2", "1.2.3.4", "1.0-beta", "26.0 (Build secret)", "1\n", " 1", "１", "-1", "1234567890", "1".repeat(30), 26]) {
      assert.throws(() => validateUserErrorReport({ ...valid, diagnosticContext: { ...diagnosticContext, [key]: value } }), InvalidUserErrorReportError);
    }
  }
  assert.throws(() => validateUserErrorReport({ ...withLogs, diagnosticContext }), InvalidUserErrorReportError);
  assert.throws(() => validateUserErrorReport({ ...submission(), consentVersion: "2026-09-14", diagnosticContext }), InvalidUserErrorReportError);
});

void test("context is part of the immutable report payload and canonical retry hash", async () => {
  const repository = new MemoryReports();
  const reports = new UserErrorReports(repository, () => instant);
  const body = { ...submission(), consentVersion: "2026-09-14", includeDiagnostics: true, diagnostics: [diagnostic], diagnosticContext };
  const first = await reports.submit(body);
  const saved = repository.records.get(body.reportId);
  assert.ok(saved);
  assert.deepEqual(saved.payload.diagnosticContext, diagnosticContext);
  const retry = await reports.submit({ ...body, diagnosticContext: { operatingSystemVersion: "26.0.1", buildVersion: "42", appVersion: "0.1.0" } });
  assert.equal(retry.created, false);
  assert.deepEqual(retry.receipt, first.receipt);
  await assert.rejects(reports.submit({ ...body, diagnosticContext: { ...diagnosticContext, buildVersion: "43" } }), UserErrorReportConflictError);
});

void test("location and destination failures accept only the extended fixed error allowlist", () => {
  for (const operation of ["location", "destinationSearch"]) {
    const value = { ...submission(), includeDiagnostics: true, diagnostics: [{ ...diagnostic, operation, errorDomain: "coreLocation", errorCode: 0 }] };
    assert.equal(validateUserErrorReport(value).diagnostics?.[0]?.operation, operation);
    assert.equal(validateUserErrorReport(value).diagnostics?.[0]?.errorDomain, "coreLocation");
    assert.throws(() => validateUserErrorReport({ ...value, diagnostics: [{ ...value.diagnostics[0], latitude: 49.5 }] }), InvalidUserErrorReportError);
  }
});

void test("report API requires explicit authenticated POST, supports deletion without auth, and never exposes contents", async (context) => {
  const repository = new MemoryReports();
  const records: RequestDiagnostic[] = [];
  let now = 0;
  const app = createApp({ userErrorReports: new UserErrorReports(repository, () => instant), reportAuthenticator: { isAuthorized: (header) => header === "Bearer accepted" }, reportNowMilliseconds: () => now, diagnostics: { sink: (record) => records.push(record) } });
  context.after(() => app.close());
  const body = { ...submission(), consentVersion: "2026-09-14", message: "PRIVATE_LOCATION PRIVATE_ROUTE PRIVATE_TEXT", includeDiagnostics: true, diagnostics: [diagnostic], diagnosticContext };
  const request = () => app.inject({ method: "POST", url: "/v1/error-reports", headers: { authorization: "Bearer accepted" }, payload: body });
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", payload: body })).statusCode, 401);
  const created = await request();
  assert.equal(created.statusCode, 201);
  assert.deepEqual(Object.keys(created.json()).sort(), ["expiresAt", "receivedAt", "reportId"]);
  assert.equal((await request()).statusCode, 200);
  assert.equal((await app.inject({ method: "GET", url: "/v1/error-reports" })).statusCode, 404);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: randomUUID() } })).statusCode, 401);
  assert.equal(repository.withdrawn.size, 0);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: body.deletionToken } })).statusCode, 204);
  assert.equal((await request()).statusCode, 410);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: body.deletionToken } })).statusCode, 204);
  for (let index = 0; index < 7; index += 1) await request();
  assert.equal((await request()).statusCode, 429);
  now = 60_000;
  assert.equal((await request()).statusCode, 410);
  assert.doesNotMatch(JSON.stringify(records), /PRIVATE_|accepted/u);
  assert.equal(JSON.stringify(records).includes(String(body.deletionToken)), false);
  assert.equal(JSON.stringify(records).includes(String(body.reportId)), false);
  assert.ok(records.some((record) => record.route === "user_error_report"));
});

void test("report endpoints reject malformed, oversized, or enriched requests with safe fixed errors", async (context) => {
  const records: RequestDiagnostic[] = [];
  const app = createApp({ userErrorReports: new UserErrorReports(new MemoryReports()), reportAuthenticator: { isAuthorized: () => true }, diagnostics: { sink: (record) => records.push(record) } });
  context.after(() => app.close());
  for (const payload of [{ ...submission(), location: "PRIVATE" }, { ...submission(), diagnostics: [] }, { ...submission(), includeDiagnostics: true, diagnostics: [{ ...diagnostic, url: "PRIVATE" }] }]) {
    const response = await app.inject({ method: "POST", url: "/v1/error-reports", payload });
    assert.equal(response.statusCode, 400);
    assert.doesNotMatch(response.body, /PRIVATE/u);
  }
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", headers: { "content-type": "application/json" }, payload: "{" })).statusCode, 400);
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", payload: { ...submission(), message: "x".repeat(131_072) } })).statusCode, 413);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: randomUUID(), deletionToken: randomUUID(), extra: "PRIVATE" } })).statusCode, 400);
  assert.doesNotMatch(JSON.stringify(records), /PRIVATE/u);
});

void test("unauthenticated submissions and deletion probes cannot spend authorized admission or storage", async (context) => {
  const repository = new MemoryReports();
  const records: RequestDiagnostic[] = [];
  const app = createApp({ userErrorReports: new UserErrorReports(repository, () => instant), reportAuthenticator: { isAuthorized: (header) => header === "Bearer accepted" }, diagnostics: { sink: (record) => records.push(record) } });
  context.after(() => app.close());
  const body = submission();
  for (let index = 0; index < 40; index += 1) {
    const response = await app.inject({ method: "POST", url: "/v1/error-reports", headers: { authorization: "Bearer PRIVATE_REJECTED" }, payload: body });
    assert.equal(response.statusCode, 401);
  }
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", headers: { authorization: "Bearer accepted" }, payload: body })).statusCode, 201);
  for (let index = 0; index < 40; index += 1) {
    const unknown = await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: randomUUID(), deletionToken: randomUUID() } });
    const incorrect = await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: randomUUID() } });
    assert.equal(unknown.statusCode, 401);
    assert.equal(incorrect.statusCode, 401);
    const withoutRandomID = (response: typeof unknown) => ({ ...response.json<Record<string, unknown>>(), errorId: undefined });
    assert.deepEqual(withoutRandomID(unknown), withoutRandomID(incorrect));
    assert.equal(unknown.headers["www-authenticate"], incorrect.headers["www-authenticate"]);
  }
  assert.equal(repository.deletionProofs.size, 1);
  assert.equal(repository.withdrawn.size, 0);
  const proof = { reportId: body.reportId, deletionToken: body.deletionToken };
  // A stored deletion capability remains sufficient even with an expired bearer.
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", headers: { authorization: "Bearer expired" }, payload: proof })).statusCode, 204);
  for (let index = 0; index < 29; index += 1) {
    assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: proof })).statusCode, 204);
  }
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: proof })).statusCode, 429);
  assert.ok(records.filter((record) => record.status === 401).every((record) => record.errorCategory === "unauthorized"));
  assert.ok(records.some((record) => record.status === 429 && record.errorCategory === "capacity_limited"));
  assert.doesNotMatch(JSON.stringify(records), /PRIVATE_REJECTED|accepted/u);
  assert.equal(JSON.stringify(records).includes(body.deletionToken), false);
});

void test("only authenticated withdrawal can allocate unknown replay protection", async (context) => {
  const repository = new MemoryReports();
  const app = createApp({ userErrorReports: new UserErrorReports(repository, () => instant), reportAuthenticator: { isAuthorized: (header) => header === "Bearer accepted" } });
  context.after(() => app.close());
  const body = submission();
  const proof = { reportId: body.reportId, deletionToken: body.deletionToken };
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: proof })).statusCode, 401);
  assert.equal(repository.deletionProofs.size, 0);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", headers: { authorization: "Bearer accepted" }, payload: proof })).statusCode, 204);
  assert.equal(repository.deletionProofs.size, 1);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: proof })).statusCode, 204);
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", headers: { authorization: "Bearer accepted" }, payload: body })).statusCode, 410);
});

void test("error report deployment retains the candidate read-only boundary and private operational access", async () => {
  const roles = await readFile(new URL("../../../deploy/gcp-vm/database-roles.sql", import.meta.url), "utf8");
  const compose = await readFile(new URL("../../../deploy/gcp-vm/compose.yaml", import.meta.url), "utf8");
  const nginx = await readFile(new URL("../../../deploy/gcp-vm/nginx-https.conf", import.meta.url), "utf8");
  assert.match(roles, /CREATE ROLE nextstop_support LOGIN NOSUPERUSER/u);
  assert.match(roles, /GRANT SELECT, INSERT, UPDATE, DELETE ON nextstop.user_error_reports TO nextstop_support/u);
  assert.match(roles, /nextstop_api SET default_transaction_read_only = on/u);
  assert.match(roles, /nextstop_support grants do not match the error-report contract/u);
  assert.match(compose, /SUPPORT_DATABASE_URL: postgresql:\/\/nextstop_support:/u);
  assert.match(compose, /log_parameter_max_length_on_error=0/u);
  assert.match(nginx, /location = \/v1\/error-reports \{\s*limit_except POST DELETE \{ deny all; \}\s*client_max_body_size 128k/u);
});
