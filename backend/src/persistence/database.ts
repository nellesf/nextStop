import { Pool, type PoolConfig } from "pg";

export function createDatabasePool(connectionString: string): Pool {
  const configuration: PoolConfig = {
    connectionString,
    max: 10,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    application_name: "nextstop-backend",
  };
  return new Pool(configuration);
}
