import assert from "node:assert/strict";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createApp } from "../../src/api/app.js";
import type { RequestDiagnostic } from "../../src/api/request-diagnostics.js";
import {
  hashReportSecret, InvalidUserErrorReportError, UserErrorReportConflictError, UserErrorReportWithdrawnError,
  UserErrorReports, validateUserErrorReport, type StoredUserErrorReport, type UserErrorReportRepository,
} from "../../src/application/user-error-reports.js";

const instant = new Date("2026-09-13T12:00:00.000Z");
const diagnostic = {
  id: randomUUID(), timestamp: "2026-09-11T06:49:15Z", operation: "candidateSearch",
  outcome: "failure", category: "offline", durationMilliseconds: 200, attempt: 1,
  httpStatus: 503, errorDomain: "url", errorCode: -1009,
  serverRequestID: randomUUID(), edgeRequestID: "01234567-89ab-cdef-0123-456789abcdef",
};
function submission() {
  return { schemaVersion: 1, reportId: randomUUID(), deletionToken: randomUUID(), consentVersion: "2026-09-13", message: "  Retry fixed the search.  ", includeDiagnostics: false };
}

class MemoryReports implements UserErrorReportRepository {
  readonly records = new Map<string, StoredUserErrorReport>();
  readonly withdrawn = new Set<string>();
  async save(report: StoredUserErrorReport) {
    await Promise.resolve();
    const existing = this.records.get(report.reportId);
    if (existing !== undefined && (!timingSafeEqual(existing.deletionTokenHash, report.deletionTokenHash) || !timingSafeEqual(existing.payloadHash, report.payloadHash))) throw new UserErrorReportConflictError();
    if (this.withdrawn.has(report.reportId)) throw new UserErrorReportWithdrawnError();
    if (existing === undefined) this.records.set(report.reportId, report);
    const value = existing ?? report;
    return { created: existing === undefined, receipt: { reportId: value.reportId, receivedAt: value.receivedAt.toISOString(), expiresAt: value.expiresAt.toISOString() } };
  }
  async delete(id: string, hash: Buffer) {
    await Promise.resolve();
    const existing = this.records.get(id);
    if (existing !== undefined && timingSafeEqual(existing.deletionTokenHash, hash)) this.withdrawn.add(id);
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
  assert.equal("deletionToken" in saved, false);
  assert.equal(JSON.stringify(saved).includes(String(body.deletionToken)), false);
  const retry = await reports.submit({ ...body, message: "Retry fixed the search." });
  assert.equal(retry.created, false);
  assert.deepEqual(retry.receipt, result.receipt);
  await assert.rejects(reports.submit({ ...body, message: "Changed" }), UserErrorReportConflictError);
});

void test("report API requires explicit authenticated POST, supports deletion without auth, and never exposes contents", async (context) => {
  const repository = new MemoryReports();
  const records: RequestDiagnostic[] = [];
  let now = 0;
  const app = createApp({ userErrorReports: new UserErrorReports(repository, () => instant), reportAuthenticator: { isAuthorized: (header) => header === "Bearer accepted" }, reportNowMilliseconds: () => now, diagnostics: { sink: (record) => records.push(record) } });
  context.after(() => app.close());
  const body = { ...submission(), message: "PRIVATE_LOCATION PRIVATE_ROUTE PRIVATE_TEXT", includeDiagnostics: true, diagnostics: [diagnostic] };
  const request = () => app.inject({ method: "POST", url: "/v1/error-reports", headers: { authorization: "Bearer accepted" }, payload: body });
  assert.equal((await app.inject({ method: "POST", url: "/v1/error-reports", payload: body })).statusCode, 401);
  const created = await request();
  assert.equal(created.statusCode, 201);
  assert.deepEqual(Object.keys(created.json()).sort(), ["expiresAt", "receivedAt", "reportId"]);
  assert.equal((await request()).statusCode, 200);
  assert.equal((await app.inject({ method: "GET", url: "/v1/error-reports" })).statusCode, 404);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: randomUUID() } })).statusCode, 204);
  assert.equal(repository.withdrawn.size, 0);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: body.deletionToken } })).statusCode, 204);
  assert.equal((await request()).statusCode, 410);
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/error-reports", payload: { reportId: body.reportId, deletionToken: body.deletionToken } })).statusCode, 204);
  for (let index = 0; index < 6; index += 1) await request();
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
