"""Exercise the production transfer engine against two disposable PG17 clusters."""
import contextlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


@unittest.skipUnless(os.environ.get("NEXTSTOP_TEST_PG_BIN") and os.environ.get("NEXTSTOP_TEST_NODE"),
                     "Set NEXTSTOP_TEST_PG_BIN and NEXTSTOP_TEST_NODE for the two-cluster transfer proof")
class ProductionPrivateHandoff(unittest.TestCase):
    def test_fenced_transfer_retry_and_purge(self):
        binary = Path(os.environ["NEXTSTOP_TEST_PG_BIN"])
        with contextlib.ExitStack() as cleanup:
            base = Path(cleanup.enter_context(tempfile.TemporaryDirectory(dir="/tmp", prefix="nsh-"))).resolve()
            for index, count in enumerate((15, 19)):
                endpoint = base / str(index)
                endpoint.mkdir(mode=0o700)
                env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
                env.update(PGHOST=str(endpoint), PGPORT="5432", PGDATABASE="nextstop", PGUSER="postgres")

                def run(name, *args, input=None, env=env):
                    result = subprocess.run([str(binary / name), *args], input=input, capture_output=True,
                                            text=True, env=env, timeout=90)
                    self.assertEqual(result.returncode, 0, result.stderr)

                run("initdb", "-D", str(endpoint / "data"), "-U", "postgres", "--auth-local=trust",
                    "--auth-host=reject", "--no-sync", "--encoding=UTF8", "--locale=C")
                run("pg_ctl", "-D", str(endpoint / "data"), "-l", str(endpoint / "log"),
                    "-o", f"-k {endpoint} -p 5432 -c listen_addresses='' -c log_error_verbosity=terse -c log_min_error_statement=panic -c log_parameter_max_length=0", "-w", "start")
                cleanup.callback(subprocess.run, [str(binary / "pg_ctl"), "-D", str(endpoint / "data"),
                                                  "-m", "immediate", "-w", "stop"], capture_output=True)
                run("psql", "-Xq", "-v", "ON_ERROR_STOP=1", "-d", "postgres", "-f", "-", input="""
                  CREATE ROLE nextstop_app LOGIN; CREATE ROLE nextstop_api LOGIN; CREATE ROLE nextstop_auth LOGIN;
                  CREATE ROLE nextstop_support LOGIN; CREATE ROLE nextstop_worker LOGIN; CREATE ROLE nextstop_backup LOGIN;
                  CREATE DATABASE nextstop OWNER nextstop_app; REVOKE ALL ON DATABASE nextstop FROM PUBLIC;""")
                run("psql", "-Xq", "-v", "ON_ERROR_STOP=1", "-c", "CREATE EXTENSION postgis; CREATE EXTENSION btree_gist")
                for migration in sorted((ROOT / "backend/migrations").glob("*.sql"))[:count]:
                    run("psql", "-Xq", "-v", "ON_ERROR_STOP=1", "-U", "nextstop_app", "-f", str(migration))
            result = subprocess.run([os.environ["NEXTSTOP_TEST_NODE"], str(HERE / "test-private-handoff.mjs"), str(base)],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
