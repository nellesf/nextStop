import { createHash } from "node:crypto";

export const userErrorReportLimits = {
  maximumBodyBytes: 128 * 1_024,
  maximumMessageCharacters: 5_000,
  maximumDiagnostics: 200,
  maximumReports: 1_000,
  maximumStoredBytes: 128 * 1_024 * 1_024,
  retentionMilliseconds: 30 * 24 * 60 * 60 * 1_000,
  purgeIntervalMilliseconds: 15 * 60 * 1_000,
} as const;

export interface AppDiagnosticEvent {
  readonly id: string;
  readonly timestamp: string;
  readonly operation: "candidateSearch" | "route" | "candidateDistance" | "authentication" | "placeLookup" | "mapsLaunch";
  readonly outcome: "failure" | "retryScheduled" | "recovered";
  readonly category: "networkTimeout" | "networkLost" | "offline" | "connection" | "http" | "invalidResponse" | "authentication" | "noRoute" | "invalidRoute" | "throttled" | "unknown";
  readonly durationMilliseconds: number;
  readonly attempt: number;
  readonly httpStatus?: number;
  readonly errorDomain?: "url" | "mapKit" | "routePlanning" | "unknown";
  readonly errorCode?: number;
  readonly serverRequestID?: string;
  readonly edgeRequestID?: string;
}

export interface UserErrorReportPayload {
  readonly schemaVersion: 1;
  readonly consentVersion: "2026-09-13";
  readonly message: string;
  readonly includeDiagnostics: boolean;
  readonly diagnostics?: readonly AppDiagnosticEvent[];
}

export interface UserErrorReportSubmission extends UserErrorReportPayload {
  readonly reportId: string;
  readonly deletionToken: string;
}

export interface UserErrorReportReceipt {
  readonly reportId: string;
  readonly receivedAt: string;
  readonly expiresAt: string;
}

export interface StoredUserErrorReport {
  readonly reportId: string;
  readonly deletionTokenHash: Buffer;
  readonly payloadHash: Buffer;
  readonly payload: UserErrorReportPayload;
  readonly payloadBytes: number;
  readonly receivedAt: Date;
  readonly expiresAt: Date;
}

export interface UserErrorReportRepository {
  save(report: StoredUserErrorReport): Promise<{ readonly created: boolean; readonly receipt: UserErrorReportReceipt }>;
  delete(reportId: string, deletionTokenHash: Buffer, now: Date): Promise<void>;
  purge(now: Date): Promise<number>;
}

export class InvalidUserErrorReportError extends Error {}
export class UserErrorReportConflictError extends Error {}
export class UserErrorReportWithdrawnError extends Error {}
export class UserErrorReportCapacityError extends Error {}

export function hashReportSecret(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}

export class UserErrorReports {
  constructor(
    private readonly repository: UserErrorReportRepository,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async submit(value: unknown): Promise<{ readonly created: boolean; readonly receipt: UserErrorReportReceipt }> {
    const submission = validateUserErrorReport(value);
    const { reportId, deletionToken, ...payload } = submission;
    const encodedPayload = JSON.stringify(payload);
    const receivedAt = this.now();
    return this.repository.save({
      reportId,
      deletionTokenHash: hashReportSecret(deletionToken),
      payloadHash: hashReportSecret(encodedPayload),
      payload,
      payloadBytes: Buffer.byteLength(encodedPayload, "utf8"),
      receivedAt,
      expiresAt: new Date(receivedAt.getTime() + userErrorReportLimits.retentionMilliseconds),
    });
  }

  async delete(value: unknown): Promise<void> {
    const body = object(value, ["reportId", "deletionToken"]);
    await this.repository.delete(uuid(body.reportId), hashReportSecret(uuid(body.deletionToken)), this.now());
  }
}

export function validateUserErrorReport(value: unknown): UserErrorReportSubmission {
  const body = object(value, ["schemaVersion", "reportId", "deletionToken", "consentVersion", "message", "includeDiagnostics", "diagnostics"]);
  if (body.schemaVersion !== 1 || body.consentVersion !== "2026-09-13" || typeof body.message !== "string" || typeof body.includeDiagnostics !== "boolean") invalid();
  const message = body.message.trim();
  // Reject unpaired UTF-16 surrogates; the limit counts Unicode scalar values like iOS.
  if (!message.isWellFormed() || [...message].length < 1 || [...message].length > userErrorReportLimits.maximumMessageCharacters || message.includes("\u0000")) invalid();
  let diagnostics: readonly AppDiagnosticEvent[] | undefined;
  if (body.includeDiagnostics) {
    if (!Array.isArray(body.diagnostics) || body.diagnostics.length < 1 || body.diagnostics.length > userErrorReportLimits.maximumDiagnostics) invalid();
    diagnostics = body.diagnostics.map(validateDiagnostic);
    if (new Set(diagnostics.map((event) => event.id)).size !== diagnostics.length) invalid();
  } else if ("diagnostics" in body) invalid();
  return {
    reportId: uuid(body.reportId), deletionToken: uuid(body.deletionToken),
    schemaVersion: 1, consentVersion: "2026-09-13", message,
    includeDiagnostics: body.includeDiagnostics,
    ...(diagnostics === undefined ? {} : { diagnostics }),
  };
}

function validateDiagnostic(value: unknown): AppDiagnosticEvent {
  const event = object(value, ["id", "timestamp", "operation", "outcome", "category", "durationMilliseconds", "attempt", "httpStatus", "errorDomain", "errorCode", "serverRequestID", "edgeRequestID"]);
  return {
    id: uuid(event.id), timestamp: timestamp(event.timestamp),
    operation: member(event.operation, ["candidateSearch", "route", "candidateDistance", "authentication", "placeLookup", "mapsLaunch"]),
    outcome: member(event.outcome, ["failure", "retryScheduled", "recovered"]),
    category: member(event.category, ["networkTimeout", "networkLost", "offline", "connection", "http", "invalidResponse", "authentication", "noRoute", "invalidRoute", "throttled", "unknown"]),
    durationMilliseconds: integer(event.durationMilliseconds, 0, 300_000),
    attempt: integer(event.attempt, 1, 3),
    ...("httpStatus" in event ? { httpStatus: integer(event.httpStatus, 100, 599) } : {}),
    ...("errorDomain" in event ? { errorDomain: member(event.errorDomain, ["url", "mapKit", "routePlanning", "unknown"]) } : {}),
    ...("errorCode" in event ? { errorCode: integer(event.errorCode, -10_000, 10_000) } : {}),
    ...("serverRequestID" in event ? { serverRequestID: uuid(event.serverRequestID) } : {}),
    ...("edgeRequestID" in event ? { edgeRequestID: uuid(event.edgeRequestID) } : {}),
  };
}

function object(value: unknown, keys: readonly string[]): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value) || Object.keys(value).some((key) => !keys.includes(key))) invalid();
  return value as Record<string, unknown>;
}
function uuid(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(value)) invalid();
  return value.toLowerCase();
}
function timestamp(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/u.test(value)) invalid();
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 4_102_444_800_000 || new Date(parsed).toISOString().slice(0, 19) !== value.slice(0, 19)) invalid();
  return new Date(parsed).toISOString();
}
function integer(value: unknown, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) invalid();
  return value;
}
function member<const T extends string>(value: unknown, values: readonly T[]): T {
  if (typeof value !== "string" || !values.includes(value as T)) invalid();
  return value as T;
}
function invalid(): never { throw new InvalidUserErrorReportError("Invalid user error report."); }
