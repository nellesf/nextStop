import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "pg";
import { databasePoolConfiguration } from "../../src/persistence/database.js";

const environment = { NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging",
  DATABASE_TRANSPORT: "cloud-sql-socket", CLOUD_SQL_CONNECTION_NAME: "nextstop-tech-testing:europe-west1:nextstop-staging" };
const url = "postgresql://nextstop_api:synthetic%3Apass%40word@localhost/nextstop";

void test("Cloud SQL socket explicitly fixes driver host and retains a dedicated PostgreSQL session", () => {
  const config = databasePoolConfiguration(url, { maxConnections: 1, statementTimeoutMilliseconds: 1_000 }, environment);
  assert.equal(config.connectionString, undefined);
  assert.equal(config.host, "/cloudsql/nextstop-tech-testing:europe-west1:nextstop-staging");
  assert.equal(config.ssl, false);
  assert.equal(config.user, "nextstop_api");
  assert.equal(config.password, "synthetic:pass@word");
  assert.equal(config.database, "nextstop");
  assert.equal(config.port, 5432);
  assert.equal(config.max, 1);
  assert.equal(config.statement_timeout, 1_000);
  // Exercise pg's actual config resolution without opening any socket.
  const client = new Client(config);
  assert.equal(client.host, config.host);
  assert.equal(client.ssl, false);
  assert.equal(client.database, "nextstop");
});

void test("socket transport cannot redirect its mounted path or disable TLS for an arbitrary network host", () => {
  for (const value of [url.replace("localhost", "remote.example"), `${url}?host=/private/socket`,
    `${url}?sslmode=disable`, `${url}#private`, url.replace("localhost", "localhost:5432"),
    url.replace("/nextstop", "/other"), url.replace("nextstop_api", "postgres")]) {
    assert.throws(() => databasePoolConfiguration(value, {}, environment), (error: unknown) =>
      error instanceof Error && !/synthetic|private|remote\.example/u.test(error.message));
  }
  for (const connection of ["", "../private", "nextstop-tech-testing:europe-west1:../private",
    "nextstop-tech-testing:europe-west1:instance/extra", "UPPER:europe-west1:instance",
    `${"a".repeat(63)}:europe-west1:${"b".repeat(60)}`]) {
    assert.throws(() => databasePoolConfiguration(url, {}, { ...environment, CLOUD_SQL_CONNECTION_NAME: connection }));
  }
  assert.throws(() => databasePoolConfiguration(url, {}, { ...environment, DATABASE_SSL_CA: "conflicting" }));
  assert.throws(() => databasePoolConfiguration(url, {}, { ...environment, NEXTSTOP_RUNTIME: "vm" }));
  assert.throws(() => databasePoolConfiguration(url, {}, { ...environment, NEXTSTOP_ENVIRONMENT: "production" }));
  assert.throws(() => databasePoolConfiguration(url, {}, { ...environment, DATABASE_TRANSPORT: "direct-tls" }));
});
