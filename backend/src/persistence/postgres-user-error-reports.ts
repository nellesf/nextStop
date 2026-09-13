import { randomBytes, timingSafeEqual } from "node:crypto";
import type { Pool } from "pg";
import {
  UserErrorReportCapacityError,
  UserErrorReportConflictError,
  UserErrorReportWithdrawnError,
  userErrorReportLimits,
  type StoredUserErrorReport,
  type UserErrorReportReceipt,
  type UserErrorReportRepository,
} from "../application/user-error-reports.js";

export class PostgresUserErrorReportRepository implements UserErrorReportRepository {
  constructor(private readonly pool: Pool) {}

  async save(report: StoredUserErrorReport): Promise<{
    readonly created: boolean;
    readonly receipt: UserErrorReportReceipt;
  }> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      // Serialize the bounded quota check and insert, including simultaneous retries.
      await client.query("SELECT pg_advisory_xact_lock(74638912)");
      const existing = await client.query<{
        deletion_token_hash: Buffer;
        payload_hash: Buffer | null;
        received_at: Date | null;
        expires_at: Date;
      }> (
        `SELECT deletion_token_hash, payload_hash, received_at, expires_at
         FROM nextstop.user_error_reports WHERE report_id = $1`,
        [report.reportId],
      );
      const row = existing.rows[0];
      if (row !== undefined) {
        if (!timingSafeEqual(row.deletion_token_hash, report.deletionTokenHash)) {
          throw new UserErrorReportConflictError();
        }
        if (row.payload_hash === null || row.expires_at <= report.receivedAt) {
          throw new UserErrorReportWithdrawnError();
        }
        if (row.received_at === null || !timingSafeEqual(row.payload_hash, report.payloadHash)) {
          throw new UserErrorReportConflictError();
        }
        await client.query("COMMIT");
        return { created: false, receipt: receipt(report.reportId, row.received_at, row.expires_at) };
      }
      const totals = await client.query<{ count: string; bytes: string }>("SELECT count(*)::text AS count, COALESCE(sum(payload_bytes), 0)::text AS bytes FROM nextstop.user_error_reports");
      const total = totals.rows[0];
      if (
        total === undefined
        || Number(total.count) >= userErrorReportLimits.maximumReports
        || Number(total.bytes) + report.payloadBytes > userErrorReportLimits.maximumStoredBytes
      ) {
        throw new UserErrorReportCapacityError();
      }
      await client.query(
        `INSERT INTO nextstop.user_error_reports (report_id, deletion_token_hash, payload_hash, payload, payload_bytes, received_at, expires_at)
         VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7)`,
        [report.reportId, report.deletionTokenHash, report.payloadHash, JSON.stringify(report.payload), report.payloadBytes, report.receivedAt, report.expiresAt],
      );
      await client.query("COMMIT");
      return { created: true, receipt: receipt(report.reportId, report.receivedAt, report.expiresAt) };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async delete(reportId: string, deletionTokenHash: Buffer, now: Date): Promise<void> {
    await this.withdraw(reportId, deletionTokenHash, now);
  }

  async deleteAsAdministrator(reportId: string, now: Date): Promise<void> {
    await this.withdraw(reportId, undefined, now);
  }

  private async withdraw(
    reportId: string,
    deletionTokenHash: Buffer | undefined,
    now: Date,
  ): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SELECT pg_advisory_xact_lock(74638912)");
      const existing = await client.query("SELECT report_id FROM nextstop.user_error_reports WHERE report_id = $1", [reportId]);
      if (existing.rowCount === 0) {
        // Withdrawal may beat an in-flight POST. Remember it before acknowledging 204.
        const totals = await client.query<{ count: string }>("SELECT count(*)::text AS count FROM nextstop.user_error_reports");
        if (Number(totals.rows[0]?.count ?? userErrorReportLimits.maximumReports) >= userErrorReportLimits.maximumReports) {
          throw new UserErrorReportCapacityError();
        }
        await client.query(
          `INSERT INTO nextstop.user_error_reports (report_id, deletion_token_hash, payload_bytes, expires_at)
           VALUES ($1, $2, 0, $3)`,
          [reportId, deletionTokenHash ?? randomBytes(32), new Date(now.getTime() + userErrorReportLimits.retentionMilliseconds)],
        );
      } else {
        await client.query(
          `UPDATE nextstop.user_error_reports SET payload = NULL, payload_bytes = 0, payload_hash = NULL, received_at = NULL
           WHERE report_id = $1 AND ($2::bytea IS NULL OR deletion_token_hash = $2) AND payload IS NOT NULL`,
          [reportId, deletionTokenHash ?? null],
        );
      }
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async purge(now: Date): Promise<number> {
    const result = await this.pool.query("DELETE FROM nextstop.user_error_reports WHERE expires_at <= $1", [now]);
    return result.rowCount ?? 0;
  }
}

function receipt(reportId: string, receivedAt: Date, expiresAt: Date): UserErrorReportReceipt {
  return { reportId, receivedAt: receivedAt.toISOString(), expiresAt: expiresAt.toISOString() };
}
