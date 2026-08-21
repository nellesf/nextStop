import { Pool, type PoolConfig } from "pg";

export interface DatabasePoolOptions {
  readonly applicationName?: string;
  readonly maxConnections?: number;
  readonly queryTimeoutMilliseconds?: number;
  readonly statementTimeoutMilliseconds?: number;
}

export function createDatabasePool(
  connectionString: string,
  options: DatabasePoolOptions = {},
): Pool {
  const configuration: PoolConfig = {
    connectionString,
    max: options.maxConnections ?? 10,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    application_name: options.applicationName ?? "nextstop-backend",
  };
  if (options.queryTimeoutMilliseconds !== undefined) {
    configuration.query_timeout = options.queryTimeoutMilliseconds;
  }
  if (options.statementTimeoutMilliseconds !== undefined) {
    configuration.statement_timeout = options.statementTimeoutMilliseconds;
  }
  return new Pool(configuration);
}
