"""Real PG17 proof in a private temporary cluster; never connects to an existing DB.

Set NEXTSTOP_TEST_PG_BIN to an existing PostgreSQL 17 bin directory with PostGIS.
Cloud SQL's extension-install permission remains a separate managed-service gate.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


@unittest.skipUnless(os.environ.get("NEXTSTOP_TEST_PG_BIN"), "Set NEXTSTOP_TEST_PG_BIN for isolated PG17 role proof")
class RestrictedBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ["NEXTSTOP_TEST_PG_BIN"])
        cls.directory = tempfile.TemporaryDirectory(prefix="nextstop-cloudsql-roles-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.base = Path(cls.directory.name)
        os.chmod(cls.base, 0o700)
        cls.environment = os.environ.copy()
        for key in ("OWNER", "API", "AUTH", "SUPPORT", "WORKER", "BACKUP"):
            cls.environment[key + "_DATABASE_PASSWORD"] = "synthetic-test-only-" + key.lower() + "-password-at-least-32"
        cls.environment.update({"PGHOST": str(cls.base), "PGPORT": "55439", "PGDATABASE": "nextstop"})
        version = cls.command("postgres", "--version").stdout
        if " 17." not in version:
            raise RuntimeError("Role proof requires PostgreSQL 17")
        cls.command("initdb", "-D", str(cls.base / "data"), "-U", "test_super", "--auth-local=trust", "--auth-host=reject", "--no-sync", "--encoding=UTF8", "--locale=C")
        cls.command("pg_ctl", "-D", str(cls.base / "data"), "-l", str(cls.base / "server.log"),
                    "-o", "-k " + str(cls.base) + " -p 55439 -c listen_addresses=''", "-w", "start")
        cls.addClassCleanup(lambda: cls.command("pg_ctl", "-D", str(cls.base / "data"), "-m", "fast", "-w", "stop", check=False))
        cls.sql("test_super", "CREATE ROLE cloudsqlsuperuser NOLOGIN; CREATE ROLE stage_bootstrap LOGIN NOINHERIT CREATEROLE CREATEDB; GRANT cloudsqlsuperuser TO stage_bootstrap", database="postgres")
        cls.sql("test_super", "CREATE DATABASE nextstop OWNER stage_bootstrap", database="postgres")
        # Managed Cloud SQL permits cloudsqlsuperuser extension creation; vanilla
        # PG does not. Install supported extensions before the non-superuser proof.
        cls.sql("test_super", "CREATE EXTENSION postgis; CREATE EXTENSION btree_gist")
        cls.script("stage_bootstrap", "database-bootstrap.sql")
        for migration in sorted((ROOT / "backend/migrations").glob("*.sql")):
            cls.command("psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", "nextstop_app", "-f", str(migration))
        cls.script("nextstop_app", "database-roles.sql")

    @classmethod
    def command(cls, binary, *args, check=True):
        result = subprocess.run([str(cls.binary / binary), *args], env=cls.environment,
                                capture_output=True, text=True, timeout=90)
        if check and result.returncode:
            # Test data only; redact even the synthetic passwords to preserve the
            # same operator convention as the actual bootstrap.
            error = result.stderr
            for key, value in cls.environment.items():
                if key.endswith("_DATABASE_PASSWORD"):
                    error = error.replace(value, "[redacted]")
            raise AssertionError(binary + " failed: " + error)
        return result

    @classmethod
    def sql(cls, role, sql, check=True, database="nextstop"):
        return cls.command("psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", role, "-d", database, "-c", sql, check=check)

    @classmethod
    def script(cls, role, filename, check=True):
        return cls.command("psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", role, "-f", str(HERE / filename), check=check)

    def test_owner_and_bootstrap_are_not_superusers_and_bootstrap_is_repeatable(self):
        self.assertEqual(self.sql("stage_bootstrap", "SELECT rolsuper FROM pg_roles WHERE rolname=current_user").stdout.strip(), "f")
        self.script("stage_bootstrap", "database-bootstrap.sql")
        self.script("nextstop_app", "database-roles.sql")
        self.assertEqual(self.sql("nextstop_app", "SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls FROM pg_roles WHERE rolname=current_user").stdout.strip(), "f")

    def test_all_runtime_isolation_and_worker_session_features(self):
        self.script("nextstop_app", "database-verify.sql")
        for role, allowed, denied in [
            ("nextstop_api", "projection_versions", "provider_records"),
            ("nextstop_auth", "app_attest_keys", "user_error_reports"),
            ("nextstop_support", "user_error_reports", "app_attest_keys"),
            ("nextstop_worker", "provider_records", "user_error_reports"),
            ("nextstop_backup", "app_attest_keys", "user_error_reports"),
        ]:
            self.sql(role, "SELECT count(*) FROM nextstop." + allowed)
            self.assertNotEqual(self.sql(role, "SELECT count(*) FROM nextstop." + denied, check=False).returncode, 0)
            self.assertNotEqual(self.sql(role, "CREATE TABLE nextstop.denied(id int)", check=False).returncode, 0)
        self.sql("nextstop_worker", "BEGIN; CREATE TEMP TABLE proof(id int) ON COMMIT DROP; SELECT pg_try_advisory_lock(991337); SELECT pg_advisory_unlock(991337); SELECT nextstop.rebuild_charging_park_power_projection('00000000-0000-0000-0000-000000000001'); SELECT nextstop.rebuild_charging_campus_power_projection('00000000-0000-0000-0000-000000000001'); SELECT nextstop.refresh_charging_projection_statistics(); ROLLBACK")
        self.assertNotEqual(self.sql("nextstop_api", "SELECT nextstop.refresh_charging_projection_statistics()", check=False).returncode, 0)
        self.sql("nextstop_worker", "SELECT nextstop.refresh_food_projection_statistics()")
        self.assertEqual(self.sql("nextstop_worker", "SELECT has_table_privilege(current_user,'nextstop.food_poi_projection','MAINTAIN') OR has_table_privilege(current_user,'nextstop.charging_park_food_poi_matches','MAINTAIN')").stdout.strip(), "f")
        for role in ("nextstop_api", "nextstop_auth", "nextstop_support", "nextstop_backup"):
            self.assertNotEqual(self.sql(role, "SELECT nextstop.refresh_food_projection_statistics()", check=False).returncode, 0)
        self.assertNotEqual(self.sql("nextstop_worker", "SELECT * FROM nextstop.schema_migrations", check=False).returncode, 0)
        self.assertEqual(self.sql("nextstop_api", "SELECT nextstop.required_migrations_applied(ARRAY['0017_monthly_ingestion_schedule.sql'])").stdout.strip(), "t")

    def test_backup_dump_excludes_report_object_without_reading_its_rows(self):
        self.sql("nextstop_app", "INSERT INTO nextstop.app_attest_challenges VALUES ('11111111-1111-1111-1111-111111111111', decode(repeat('11',32),'hex'),'attestation',decode(repeat('22',32),'hex'),now(),now()+interval '1 minute'); INSERT INTO nextstop.user_error_reports VALUES ('22222222-2222-2222-2222-222222222222',decode(repeat('33',32),'hex'),decode(repeat('44',32),'hex'),'{\"synthetic\":true}',1,now(),now()+interval '1 day')")
        archive = self.base / "backup.dump"
        archive.touch(mode=0o600)
        result = self.command("pg_dump", "-U", "nextstop_backup", "--dbname=nextstop", "--format=custom",
                             "--schema=nextstop", "--no-owner", "--no-privileges",
                             "--exclude-table-data=nextstop.user_error_reports", "--file=" + str(archive), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("permission denied for table user_error_reports", result.stderr)
        # A data-less table still requires a dump lock. Omitting its object avoids
        # any report access; its schema must be supplied from reviewed metadata.
        self.command("pg_dump", "-U", "nextstop_backup", "--dbname=nextstop", "--format=custom",
                     "--schema=nextstop", "--no-owner", "--no-privileges",
                     "--exclude-table=nextstop.user_error_reports", "--file=" + str(archive))
        listing = self.command("pg_restore", "--list", str(archive)).stdout
        self.assertNotIn("user_error_reports", listing)
        self.assertIn("TABLE DATA nextstop app_attest_keys", listing)
        supplement = self.command("psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", "nextstop_backup",
                                  "-f", str(ROOT / "backend/operations/export-report-schema.sql")).stdout
        self.assertNotIn("synthetic", supplement)
        self.assertIn("CREATE TABLE nextstop.user_error_reports", supplement)
        self.sql("test_super", "CREATE DATABASE restored OWNER nextstop_app", database="postgres")
        try:
            self.sql("test_super", "CREATE EXTENSION postgis; CREATE EXTENSION btree_gist", database="restored")
            self.sql("nextstop_app", "CREATE SCHEMA nextstop AUTHORIZATION nextstop_app", database="restored")
            self.command("pg_restore", "-U", "nextstop_app", "--dbname=restored", "--schema=nextstop", "--no-owner",
                         "--no-privileges", "--single-transaction", "--exit-on-error", str(archive))
            self.sql("nextstop_app", supplement, database="restored")
            self.assertEqual(self.sql("nextstop_app", "SELECT count(*) FROM nextstop.user_error_reports", database="restored").stdout.strip(), "0")
            self.assertEqual(self.sql("nextstop_app", "SELECT count(*) FROM nextstop.app_attest_challenges", database="restored").stdout.strip(), "1")
            for query in [
                "SELECT attname,format_type(atttypid,atttypmod),attnotnull FROM pg_attribute WHERE attrelid='nextstop.user_error_reports'::regclass AND attnum>0 ORDER BY attnum",
                "SELECT conname,pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='nextstop.user_error_reports'::regclass ORDER BY conname",
                "SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='nextstop' AND tablename='user_error_reports' ORDER BY indexname",
            ]:
                self.assertEqual(self.sql("nextstop_app", query).stdout, self.sql("nextstop_app", query, database="restored").stdout)
        finally:
            self.sql("test_super", "DROP DATABASE restored", database="postgres")
            self.sql("nextstop_app", "DELETE FROM nextstop.app_attest_challenges; DELETE FROM nextstop.user_error_reports")

    def test_report_schema_export_rejects_unreviewed_features(self):
        self.sql("nextstop_app", "ALTER TABLE nextstop.user_error_reports ADD COLUMN future_unreviewed text DEFAULT 'synthetic'")
        try:
            result = self.command("psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", "nextstop_backup",
                                  "-f", str(ROOT / "backend/operations/export-report-schema.sql"), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("CREATE TABLE", result.stdout)
        finally:
            self.sql("nextstop_app", "ALTER TABLE nextstop.user_error_reports DROP COLUMN future_unreviewed")

    def test_unsafe_existing_membership_fails_closed(self):
        self.sql("test_super", "GRANT pg_read_all_data TO nextstop_api")
        try:
            self.assertNotEqual(self.script("stage_bootstrap", "database-bootstrap.sql", check=False).returncode, 0)
            self.assertNotEqual(self.script("nextstop_app", "database-verify.sql", check=False).returncode, 0)
        finally:
            self.sql("test_super", "REVOKE pg_read_all_data FROM nextstop_api")

    @unittest.skipUnless(os.environ.get("NEXTSTOP_TEST_NODE"), "Set NEXTSTOP_TEST_NODE for the actual TypeScript concurrency proof")
    def test_monthly_budget_is_atomic_across_concurrent_worker_sessions(self):
        environment = {**self.environment, "PGUSER": "nextstop_worker"}
        script = """
import assert from 'node:assert/strict';
import { Pool } from 'pg';
import { PostgresMonthlyImportBudget } from './src/jobs/cloud-monthly-ingestion.ts';
const pool = new Pool({max: 20});
try {
  const budget = new PostgresMonthlyImportBudget(pool);
  const october = new Date('2026-10-31T23:59:59Z');
  assert.equal((await Promise.all(Array.from({length: 20}, () => budget.reserve(october)))).filter(Boolean).length, 3);
  assert.equal(await budget.reserve(new Date('2026-09-01T00:00:00Z')), false);
  assert.equal((await Promise.all(Array.from({length: 20}, () => budget.reserve(new Date('2026-11-01T00:00:00Z'))))).filter(Boolean).length, 3);
  assert.equal(await budget.reserve(october), false);
  assert.deepEqual((await pool.query('SELECT month_start::text,attempts FROM nextstop.monthly_import_budget')).rows, [{month_start:'2026-11-01',attempts:3}]);
  await budget.deferDueUntilNextMonth(new Date('2026-10-04T12:00:00Z'));
  assert.deepEqual((await pool.query('SELECT job,next_due_at FROM nextstop.monthly_ingestion_schedule ORDER BY job')).rows.map(row => [row.job,row.next_due_at.toISOString()]),
    [['charging-static','2026-11-01T02:00:00.000Z'],['food-pois','2026-12-01T02:00:00.000Z']]);
} finally { await pool.end(); }
"""
        self.sql("nextstop_app", "TRUNCATE nextstop.monthly_import_budget,nextstop.monthly_ingestion_schedule; INSERT INTO nextstop.monthly_ingestion_schedule(job,next_due_at) VALUES ('charging-static','2026-10-01T02:00:00Z'),('food-pois','2026-12-01T02:00:00Z')")
        try:
            result = subprocess.run([os.environ["NEXTSTOP_TEST_NODE"], "--import", "tsx", "--input-type=module", "-e", script],
                                    cwd=ROOT / "backend", env=environment, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, "Synthetic local budget concurrency proof failed: " + result.stderr)
        finally:
            self.sql("nextstop_app", "TRUNCATE nextstop.monthly_import_budget,nextstop.monthly_ingestion_schedule")

    def test_empty_password_rejected_without_mutation(self):
        previous = self.environment["API_DATABASE_PASSWORD"]
        self.environment["API_DATABASE_PASSWORD"] = ""
        try:
            self.assertNotEqual(self.script("stage_bootstrap", "database-bootstrap.sql", check=False).returncode, 0)
        finally:
            self.environment["API_DATABASE_PASSWORD"] = previous


if __name__ == "__main__":
    unittest.main()
