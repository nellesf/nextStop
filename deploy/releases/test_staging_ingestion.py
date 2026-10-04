import importlib.util
from pathlib import Path
import tempfile
import unittest

from release import ReleaseError, load_env

spec = importlib.util.spec_from_file_location("staging_ingestion", Path(__file__).with_name("configure-staging-ingestion.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StagingIngestionTests(unittest.TestCase):
    def test_enable_is_idempotent_and_disable_preserves_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            host, private = Path(temporary) / "release.env", Path(temporary) / "backend.env"
            host.write_text("NEXTSTOP_ENVIRONMENT=staging\nDOMAIN=api-staging.nextstop.tech\nDATABASE_MODE=local\n")
            private.write_text("EXISTING_SECRET=synthetic-secret\n")
            module.configure(host, private, enabled=True)
            token = load_env(private)["LIVE_REFRESH_TOKEN"]
            self.assertEqual(len(token), 64)
            module.configure(host, private, enabled=True)
            self.assertEqual(load_env(private)["LIVE_REFRESH_TOKEN"], token)
            self.assertEqual(load_env(host)["INGESTION_SCHEDULE"], "monthly")
            self.assertEqual(load_env(host)["DEMAND_LIVE_AVAILABILITY_ENABLED"], "true")
            self.assertEqual(private.stat().st_mode & 0o777, 0o600)
            module.configure(host, private, enabled=False)
            self.assertEqual(load_env(host)["INGESTION_SCHEDULE"], "daily")
            self.assertEqual(load_env(host)["DEMAND_LIVE_AVAILABILITY_ENABLED"], "false")
            self.assertEqual(load_env(private)["LIVE_REFRESH_TOKEN"], token)
            self.assertEqual(load_env(private)["EXISTING_SECRET"], "synthetic-secret")

    def test_production_and_wrong_domains_fail_before_any_write(self):
        for environment, domain in [("production", "api.nextstop.tech"), ("staging", "api.nextstop.tech")]:
            with tempfile.TemporaryDirectory() as temporary:
                host, private = Path(temporary) / "release.env", Path(temporary) / "backend.env"
                original = f"NEXTSTOP_ENVIRONMENT={environment}\nDOMAIN={domain}\n"
                host.write_text(original)
                private.write_text("EXISTING_SECRET=synthetic-secret\n")
                with self.assertRaises(ReleaseError):
                    module.configure(host, private, enabled=True)
                self.assertEqual(host.read_text(), original)
                self.assertEqual(private.read_text(), "EXISTING_SECRET=synthetic-secret\n")

    def test_invalid_existing_refresh_secret_is_not_silently_rotated(self):
        with tempfile.TemporaryDirectory() as temporary:
            host, private = Path(temporary) / "release.env", Path(temporary) / "backend.env"
            host.write_text("NEXTSTOP_ENVIRONMENT=staging\nDOMAIN=api-staging.nextstop.tech\n")
            private.write_text("LIVE_REFRESH_TOKEN=short\n")
            with self.assertRaises(ReleaseError):
                module.configure(host, private, enabled=True)
            self.assertNotIn("INGESTION_SCHEDULE", load_env(host))


if __name__ == "__main__":
    unittest.main()
