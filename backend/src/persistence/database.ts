import { Pool, type PoolConfig } from "pg";
import { deploymentRuntime, type RuntimeEnvironment } from "../runtime/deployment-runtime.js";

export interface DatabasePoolOptions {
  readonly applicationName?: string;
  readonly maxConnections?: number;
  readonly queryTimeoutMilliseconds?: number;
  readonly statementTimeoutMilliseconds?: number;
  readonly connectionTimeoutMilliseconds?: number;
}

export function createDatabasePool(
  connectionString: string,
  options: DatabasePoolOptions = {},
): Pool {
  return new Pool(databasePoolConfiguration(connectionString, options));
}

export function databasePoolConfiguration(
  connectionString: string,
  options: DatabasePoolOptions = {},
  environment: RuntimeEnvironment = process.env,
): PoolConfig {
  const cloud = deploymentRuntime(environment) === "cloud-run";
  const configuration: PoolConfig = {
    connectionString,
    max: cloud ? Math.min(options.maxConnections ?? 2, 4) : options.maxConnections ?? 10,
    // A suspended remote database may need to resume before accepting a socket.
    connectionTimeoutMillis: cloud ? Math.max(options.connectionTimeoutMilliseconds ?? 10_000, 10_000)
      : options.connectionTimeoutMilliseconds ?? 5_000,
    idleTimeoutMillis: cloud ? 1_000 : 30_000,
    application_name: options.applicationName ?? "nextstop-backend",
  };
  const transport = environment.DATABASE_TRANSPORT ?? "direct-tls";
  if (transport !== "direct-tls" && transport !== "cloud-sql-socket") {
    throw new Error("DATABASE_TRANSPORT is invalid.");
  }
  if (!cloud && transport === "cloud-sql-socket") {
    throw new Error("Cloud SQL sockets require the staging Cloud Run runtime.");
  }
  if (cloud && transport === "cloud-sql-socket") {
    configureCloudSQLSocket(configuration, connectionString, environment);
  } else if (cloud) {
    if (environment.CLOUD_SQL_CONNECTION_NAME !== undefined) {
      throw new Error("CLOUD_SQL_CONNECTION_NAME requires the cloud-sql-socket transport.");
    }
    const url = databaseURL(connectionString);
    // pg connection-string SSL options replace the explicit SSL object. Remove
    // accepted modes and fail closed on options that could bypass verification.
    const mode = url.searchParams.get("sslmode");
    if ((mode !== null && !["require", "verify-ca", "verify-full"].includes(mode)) ||
        ["ssl", "sslcert", "sslkey", "sslrootcert", "uselibpqcompat"].some((key) => url.searchParams.has(key))) {
      throw new Error("Cloud database connections require verified TLS; configure a CA through DATABASE_SSL_CA if needed.");
    }
    url.searchParams.delete("sslmode");
    configuration.connectionString = url.toString();
    configuration.ssl = { rejectUnauthorized: true,
      ...(environment.DATABASE_SSL_CA === undefined ? {} : { ca: environment.DATABASE_SSL_CA }) };
  }
  if (options.queryTimeoutMilliseconds !== undefined) {
    configuration.query_timeout = options.queryTimeoutMilliseconds;
  }
  if (options.statementTimeoutMilliseconds !== undefined) {
    configuration.statement_timeout = options.statementTimeoutMilliseconds;
  }
  return configuration;
}

function databaseURL(value: string): URL {
  try {
    const url = new URL(value);
    if (!["postgres:", "postgresql:"].includes(url.protocol) || url.hostname === "" ||
        url.searchParams.has("host")) throw new Error();
    return url;
  } catch { throw new Error("Cloud database connection URL is invalid."); }
}

/** Only Cloud Run's mounted, IAM-authorized Cloud SQL connector may bypass the local PG TLS layer. */
function configureCloudSQLSocket(configuration: PoolConfig, value: string, environment: RuntimeEnvironment): void {
  const connection = environment.CLOUD_SQL_CONNECTION_NAME ?? "";
  const socket = `/cloudsql/${connection}`;
  if (!/^[a-z][a-z0-9-]{4,61}[a-z0-9]:[a-z]+-[a-z]+[0-9]:[a-z][a-z0-9-]{0,96}[a-z0-9]$/u.test(connection) ||
      Buffer.byteLength(`${socket}/.s.PGSQL.5432`) > 107 || environment.DATABASE_SSL_CA !== undefined) {
    throw new Error("A valid Cloud SQL connection name is required for the mounted socket.");
  }
  const url = databaseURL(value);
  if (url.hostname !== "localhost" || url.port !== "" || url.pathname !== "/nextstop" ||
      url.search !== "" || url.hash !== "" || url.password === "" ||
      !/^nextstop_(?:app|api|auth|support|worker|backup)$/u.test(url.username)) {
    throw new Error("Cloud SQL role URLs must use localhost/nextstop without port, query or fragment.");
  }
  // Do not retain a connectionString: pg would parse it again and override host/ssl.
  delete configuration.connectionString;
  configuration.host = socket;
  configuration.port = 5432;
  configuration.database = "nextstop";
  configuration.user = url.username;
  configuration.password = decodeURIComponent(url.password);
  configuration.ssl = false;
}
