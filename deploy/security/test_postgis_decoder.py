"""Run the real ACL transaction on an isolated PG17/PostGIS database."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("restrict-postgis-flatbuffer-decoder.sql")
VERIFY = Path(__file__).with_name("verify-postgis-flatbuffer-decoder.sql")
FUNCTION = "public.st_fromflatgeobuf(anyelement,bytea)"


@unittest.skipUnless(os.environ.get("NEXTSTOP_TEST_PG_BIN"), "Set NEXTSTOP_TEST_PG_BIN to a PG17/PostGIS bin directory")
class PostgisDecoder(unittest.TestCase):
    def test_real_acl_and_transaction_rollback(self):
        bin_dir = Path(os.environ["NEXTSTOP_TEST_PG_BIN"])
        with tempfile.TemporaryDirectory(prefix="nfg-", dir="/tmp") as directory:
            base = Path(directory).resolve()
            data = base / "data"
            env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
            env.update(PGHOST=str(base), PGDATABASE="postgres", PGUSER="nextstop_app", PGPORT="5432")

            def run(name, *args, check=True):
                result = subprocess.run([str(bin_dir / name), *map(str, args)], env=env,
                                        capture_output=True, text=True, timeout=45)
                if check:
                    self.assertEqual(result.returncode, 0, result.stderr)
                return result

            run("initdb", "-D", data, "-U", "fixture_admin", "-A", "trust", "--no-sync", "--locale=C", "-E", "UTF8")
            run("pg_ctl", "-w", "-D", data, "-l", base / "server.log", "-o", f"-k {base} -c listen_addresses=''", "start")
            try:
                def sql(stmt, role="nextstop_app", db="nextstop", check=True):
                    return run("psql", "-XAtq", "-v", "ON_ERROR_STOP=1", "-U", role, "-d", db, "-c", stmt, check=check)

                def restrict(role="nextstop_app", check=True, db="nextstop"):
                    return run("psql", "-Xq", "-v", "ON_ERROR_STOP=1", "-U", role, "-d", db,
                               "-f", SCRIPT, check=check)

                def verify(db="nextstop", check=True):
                    return run("psql", "-Xq", "-v", "ON_ERROR_STOP=1", "-U", "nextstop_api", "-d", db,
                               "-f", VERIFY, check=check)

                sql("CREATE ROLE nextstop_app LOGIN SUPERUSER", role="fixture_admin", db="postgres")
                sql("CREATE DATABASE nextstop", db="postgres")
                roles = ["nextstop_api", "nextstop_auth", "nextstop_worker", "nextstop_support", "nextstop_backup"]
                for role in roles:
                    sql(f"CREATE ROLE {role} LOGIN")
                sql("CREATE EXTENSION postgis")
                self.assertNotEqual(verify(check=False).returncode, 0)
                sql("CREATE ROLE indirect; GRANT indirect TO nextstop_worker WITH INHERIT FALSE")
                sql(f"GRANT EXECUTE ON FUNCTION {FUNCTION} TO nextstop_support,indirect")
                self.assertNotEqual(restrict("nextstop_api", check=False).returncode, 0)
                self.assertNotEqual(restrict(check=False).returncode, 0)
                access = f"SELECT has_function_privilege(current_user,'{FUNCTION}','EXECUTE')"
                self.assertEqual(sql(access, "nextstop_api").stdout.strip(), "t")
                sql(f"REVOKE EXECUTE ON FUNCTION {FUNCTION} FROM indirect")
                restrict()
                restrict()
                verify()
                for role in roles:
                    self.assertEqual(sql(access, role).stdout.strip(), "f")
                header = "SELECT has_function_privilege(current_user,'public.st_fromflatgeobuftotable(text,text,bytea)','EXECUTE')"
                self.assertEqual(sql(header, "nextstop_worker").stdout.strip(), "f")
                self.assertEqual(sql(access).stdout.strip(), "t")
                geo = "SELECT ST_DWithin('POINT(0 0)'::geography,'POINT(0 0.001)'::geography,200)"
                self.assertEqual(sql(geo, "nextstop_api").stdout.strip(), "t")
                untouched = "SELECT has_function_privilege(current_user,'public.st_asflatgeobuf(anyelement)','EXECUTE')"
                self.assertEqual(sql(untouched, "nextstop_api").stdout.strip(), "t")

                # Model the managed catalog's versioned library and separate PostGIS owner.
                sql("CREATE ROLE postgres LOGIN SUPERUSER; CREATE ROLE cloudsqlsuperuser; GRANT cloudsqlsuperuser TO postgres")
                sql("CREATE DATABASE template_postgis TEMPLATE template0 OWNER postgres", role="postgres", db="postgres")
                sql("CREATE EXTENSION postgis", role="postgres", db="template_postgis")
                sql(f"""UPDATE pg_proc SET probin = '$libdir/postgis-' ||
                     (SELECT substring(extversion FROM '^[0-9]+[.][0-9]+') FROM pg_extension WHERE extname='postgis') ||
                     '/postgis-3' WHERE oid = '{FUNCTION}'::regprocedure""", role="postgres", db="template_postgis")
                sql("ALTER ROLE nextstop_app NOSUPERUSER", role="postgres", db="template_postgis")
                restrict("postgres", db="template_postgis")
                verify("template_postgis")
                self.assertEqual(sql(access, "nextstop_app", "template_postgis").stdout.strip(), "f")
            finally:
                run("pg_ctl", "-w", "-D", data, "-m", "immediate", "stop")
