"""Filled synthetic fixtures for two fresh, isolated PostgreSQL databases."""
import re
import select
import subprocess


TABLES = ("app_attest_keys", "app_attest_challenges", "user_error_reports")
KEY = "decode(repeat('11',32),'hex')"
HASH = "decode(repeat('22',32),'hex')"
CHALLENGE = "00000000-0000-0000-0000-000000000001"
REPORT = "00000000-0000-0000-0000-000000000002"
EXPIRED_CHALLENGE = "00000000-0000-0000-0000-000000000003"


def rehearse(case, migrations, *, databases=("rehearsal_vm", "rehearsal_cloudsql"),
             owner="nextstop_app", admin="test_super", writers=("nextstop_auth", "nextstop_support"),
             role_environment=None):
    """Exercise both directions with disposable databases in a private fixture namespace."""
    if (len(set(databases)) != 2 or
            not all(re.fullmatch(r"rehearsal_[a-z0-9_]{2,48}", db) for db in databases) or
            not all(re.fullmatch(r"[a-z][a-z0-9_]{1,62}", role) for role in (owner, admin, *writers))):
        raise ValueError("Expected fresh rehearsal database names and SQL identifiers")
    old, new = databases
    auth, support = writers
    environment = role_environment or (lambda role: case.environment)

    def sql(db, query, role=owner):
        return case.sql(role, query, database=db).stdout.strip()

    def writer_access(db, enabled):
        action = "GRANT CONNECT ON DATABASE " + db + " TO " if enabled else "REVOKE CONNECT ON DATABASE " + db + " FROM "
        sql(db, action + ", ".join(writers))

    def frozen(db):
        roles = f"('{auth}'), ('{support}')"
        return sql(db, f"""
            SELECT NOT EXISTS (SELECT 1 FROM (VALUES {roles}) AS writers(role)
                         WHERE has_database_privilege(role, current_database(), 'CONNECT'))
               AND NOT EXISTS (SELECT 1 FROM pg_stat_activity
                         WHERE datname=current_database() AND pid <> pg_backend_pid())
        """) == "t"

    def state(db):
        # Fixtures only: compare every value including bytea, NULLs and exact timestamps.
        return tuple(sql(db, f"SELECT to_jsonb(t) FROM nextstop.{table} t ORDER BY 1") for table in TABLES)

    def transfer(source, destination, expected_destination, inject_failure=False):
        if not frozen(source) or not frozen(destination):
            raise ValueError("Both databases must be closed to writers and drained")
        if state(destination) != expected_destination:
            raise ValueError("Inactive destination diverged")
        before = state(source)
        # pg_dump provides a single consistent snapshot. An incomplete export must
        # never be piped into a transaction which could commit the initial deletes.
        dump = case.command("pg_dump", "-U", owner, "-d", source, "--data-only", "--no-owner",
                            "--no-privileges", *["--table=nextstop." + table for table in TABLES]).stdout
        delete = "".join(f"DELETE FROM nextstop.{table};\n" for table in TABLES)
        result = subprocess.run(
            [str(case.binary / "psql"), "-Xq", "-v", "ON_ERROR_STOP=1", "--single-transaction",
             "-U", owner, "-d", destination, "-f", "-"],
            input=delete + dump + ("\nSELECT 1/0;\n" if inject_failure else ""), text=True,
            capture_output=True, env=environment(owner), timeout=60)
        if inject_failure:
            case.assertNotEqual(result.returncode, 0)
            case.assertIn("division by zero", result.stderr)
            case.assertEqual(state(destination), expected_destination)
        else:
            case.assertEqual(result.returncode, 0, "Private table import failed")
            case.assertEqual(state(destination), before)
            case.assertTrue(frozen(source) and frozen(destination))
        return before

    for db, count in ((old, 15), (new, 19)):
        # Never clone the application database, even during a managed rehearsal.
        case.sql(admin, f"CREATE DATABASE {db} OWNER {owner} TEMPLATE template0", database="postgres")
        case.addCleanup(case.sql, admin, "DROP DATABASE " + db, database="postgres")
        sql(db, f"REVOKE ALL ON DATABASE {db} FROM PUBLIC")
        sql(db, "CREATE EXTENSION postgis; CREATE EXTENSION btree_gist", role=admin)
        for migration in sorted(migrations.glob("*.sql"))[:count]:
            case.command("psql", "-Xq", "-v", "ON_ERROR_STOP=1", "-U", owner,
                         "-d", db, "-f", str(migration))
        sql(db, f"""
            GRANT USAGE ON SCHEMA nextstop TO {auth}, {support};
            GRANT SELECT, INSERT, UPDATE, DELETE ON nextstop.app_attest_keys,
                nextstop.app_attest_challenges TO {auth};
            GRANT SELECT, INSERT, UPDATE, DELETE ON nextstop.user_error_reports TO {support};
        """)
        case.assertEqual(sql(db, "SELECT count(*) FROM nextstop.schema_migrations"), str(count))
    writer_access(old, True)
    sql(old, f"""
        INSERT INTO nextstop.app_attest_keys (key_id_hash, public_key_pem, receipt, environment, sign_count)
        VALUES ({KEY}, repeat('synthetic',12), {HASH}, 'production', 7);
        INSERT INTO nextstop.app_attest_challenges (challenge_id, key_id_hash, purpose, client_data, expires_at)
        VALUES ('{CHALLENGE}', {KEY}, 'assertion', {HASH}, now()+interval '3 minutes');
        INSERT INTO nextstop.app_attest_challenges
            (challenge_id, key_id_hash, purpose, client_data, created_at, expires_at)
        VALUES ('{EXPIRED_CHALLENGE}', {KEY}, 'assertion', {HASH}, now()-interval '5 minutes', now()-interval '3 minutes');
    """, role=auth)
    sql(old, f"""
        INSERT INTO nextstop.user_error_reports
            (report_id, deletion_token_hash, payload_hash, payload, payload_bytes, received_at, expires_at)
        VALUES ('{REPORT}', {KEY}, {HASH}, '{{"synthetic":true}}', 18, now(), now()+interval '5 days'),
               (gen_random_uuid(), {KEY}, NULL, NULL, 0, NULL, now()+interval '3 days'),
               (gen_random_uuid(), {KEY}, NULL, NULL, 0, NULL, now()-interval '1 hour');
    """, role=support)

    empty = ("", "", "")
    case.assertEqual(state(new), empty)
    # Hold a real pre-freeze writer with an uncommitted counter increment. New
    # connections must be refused while its existing transaction can commit.
    with subprocess.Popen([str(case.binary / "psql"), "-XqAt", "-v", "ON_ERROR_STOP=1",
                           "-U", auth, "-d", old], text=True, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment(auth)) as writer:
        try:
            writer.stdin.write("BEGIN; UPDATE nextstop.app_attest_keys SET sign_count=8; SELECT 'locked';\n")
            writer.stdin.flush()
            case.assertTrue(select.select([writer.stdout], [], [], 8)[0], "Timed out opening the writer")
            case.assertEqual(writer.stdout.readline().strip(), "locked")
            writer_access(old, False)
            for role in writers:
                case.assertNotEqual(case.sql(role, "SELECT 1", database=old, check=False).returncode, 0)
            with case.assertRaisesRegex(ValueError, "drained"):
                transfer(old, new, empty)
            writer.communicate("COMMIT;\n", timeout=10)
            case.assertEqual(writer.returncode, 0)
        finally:
            if writer.poll() is None:
                writer.kill()

    baseline = transfer(old, new, empty)
    writer_access(new, True)
    case.assertEqual(sql(new, "SELECT sign_count FROM nextstop.app_attest_keys", role=auth), "8")
    sql(new, f"""
        UPDATE nextstop.app_attest_keys SET sign_count=11, last_asserted_at=now(), revoked_at=now()
         WHERE key_id_hash={KEY} AND sign_count=8;
        DELETE FROM nextstop.app_attest_challenges WHERE challenge_id='{CHALLENGE}';
        INSERT INTO nextstop.app_attest_challenges (challenge_id, key_id_hash, purpose, client_data, expires_at)
        VALUES (gen_random_uuid(), {KEY}, 'attestation', {HASH}, now()+interval '1 minute');
    """, role=auth)
    sql(new, f"""
        UPDATE nextstop.user_error_reports SET payload=NULL, payload_bytes=0, received_at=NULL, payload_hash=NULL
         WHERE report_id='{REPORT}';
        INSERT INTO nextstop.user_error_reports
            (report_id, deletion_token_hash, payload_hash, payload, payload_bytes, received_at, expires_at)
        VALUES (gen_random_uuid(), {HASH}, {KEY}, '{{"after_cutover":true}}', 22, now(), now()+interval '1 day');
    """, role=support)
    writer_access(new, False)
    with case.assertRaisesRegex(ValueError, "diverged"):
        transfer(new, old, empty)
    transfer(new, old, baseline, inject_failure=True)
    transfer(new, old, baseline)
    writer_access(old, True)
    case.assertTrue(frozen(new))
    case.assertEqual(sql(old, "SELECT sign_count=11 AND revoked_at IS NOT NULL FROM nextstop.app_attest_keys",
                         role=auth), "t")
    case.assertEqual(sql(old, f"SELECT count(*) FROM nextstop.app_attest_challenges WHERE challenge_id='{CHALLENGE}'",
                         role=auth), "0")
    case.assertEqual(sql(old, f"SELECT payload IS NULL FROM nextstop.user_error_reports WHERE report_id='{REPORT}'",
                         role=support), "t")
    case.assertEqual(sql(old, "SELECT count(*) FROM nextstop.user_error_reports WHERE payload IS NOT NULL",
                         role=support), "1")
    # The old server's expiry, replay and retention checks must still distinguish
    # live state from expired rows after returning to its original schema.
    case.assertEqual(sql(old, f"""WITH consumed AS (
        DELETE FROM nextstop.app_attest_challenges WHERE challenge_id='{EXPIRED_CHALLENGE}'
        AND expires_at>now() RETURNING 1) SELECT count(*) FROM consumed""", role=auth), "0")
    case.assertEqual(sql(old, """WITH purged AS (
        DELETE FROM nextstop.user_error_reports WHERE expires_at<=now() RETURNING 1)
        SELECT count(*) FROM purged""", role=support), "1")
    case.assertEqual(sql(old, "SELECT count(*) FROM nextstop.user_error_reports WHERE payload IS NULL",
                         role=support), "2")
