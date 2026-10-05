import assert from "node:assert/strict";
import test from "node:test";
import { backupArguments, backupConfiguration } from "../../src/jobs/database-backup.js";

const environment = { NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging",
  DATABASE_TRANSPORT: "cloud-sql-socket", CLOUD_SQL_CONNECTION_NAME: "nextstop-tech-testing:europe-west1:nextstop-staging",
  BACKUP_DATABASE_URL: "postgresql://nextstop_backup:synthetic-backup-password@localhost/nextstop",
  BACKUP_BUCKET: "nextstop-tech-testing-database-backups" };

void test("backup uses the restricted socket identity and excludes the complete report table", () => {
  const config = backupConfiguration(environment);
  assert.equal(config.pg.PGUSER,"nextstop_backup"); assert.equal(config.pg.PGDATABASE,"nextstop");
  assert.equal(config.pg.PGHOST,"/cloudsql/nextstop-tech-testing:europe-west1:nextstop-staging");
  assert.match(config.pg.PGOPTIONS ?? "",/default_transaction_read_only=on/u);
  assert.ok(backupArguments.includes("--exclude-table=nextstop.user_error_reports"));
  assert.doesNotMatch(backupArguments.join(" "),/synthetic-backup-password|postgresql:\/\//u);
  assert.equal(config.pg.SEARCH_ACCESS_TOKEN_SIGNING_KEY,undefined);
});

void test("backup cannot run on production, use an owner credential or send an archive outside staging", () => {
  for (const changed of [{NEXTSTOP_ENVIRONMENT:"production"},{NEXTSTOP_RUNTIME:"vm"},
    {BACKUP_BUCKET:"nextstop-production-backups"},{BACKUP_DATABASE_URL:environment.BACKUP_DATABASE_URL.replace("nextstop_backup","nextstop_app")},
    {BACKUP_DATABASE_URL:environment.BACKUP_DATABASE_URL.replace("localhost","remote.example")}]) {
    assert.throws(()=>backupConfiguration({...environment,...changed}));
  }
});
