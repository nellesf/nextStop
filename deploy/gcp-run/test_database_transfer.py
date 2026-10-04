import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("database_transfer", HERE / "database-transfer.py")
transfer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transfer)


def listing(purpose="handoff", migrations=17):
    return "\n".join(f"{index}; 0 {index} TABLE DATA nextstop {name} nextstop_app"
                     for index, name in enumerate(sorted(transfer.expected_tables(purpose, migrations)), 1))


class TransferTests(unittest.TestCase):
    def test_only_authorized_staging_target_and_no_secret_in_commands(self):
        for target in ["nextstop-tech-staging:europe-west1:db", "nextstop-tech-testing:europe-west3:db", "https://private-password.example", "nextstop-tech-testing:europe-west1:../db"]:
            with self.assertRaises(ValueError):
                transfer.plan(target, Path("/private/tmp/proof"), "handoff", 17)
        value = transfer.plan("nextstop-tech-testing:europe-west1:stage-db", Path("/private/tmp/proof"), "handoff", 17)
        self.assertFalse(value["durableStorageAllowed"])
        self.assertIn("--single-transaction", value["restoreArgv"])
        self.assertIn("--no-owner", value["restoreArgv"])
        self.assertNotIn("--exclude-table=nextstop.user_error_reports", value["dumpArgv"])
        backup = transfer.plan("nextstop-tech-testing:europe-west1:stage-db", Path("/private/tmp/proof"), "backup", 17)
        self.assertIn("--exclude-table=nextstop.user_error_reports", backup["dumpArgv"])

    def test_inventory_is_exact_and_durable_backup_rejects_reports(self):
        for migrations in [17, 18]:
            transfer.validate_listing(listing(migrations=migrations), "handoff", migrations)
            transfer.validate_listing(listing("backup", migrations), "backup", migrations)
        for text, purpose in [(listing(), "backup"), (listing()+"\n99; 0 99 TABLE DATA nextstop future_private_table nextstop_app", "handoff"),
                              (listing()+"\n99; 0 99 TABLE DATA public.private_data postgres", "handoff"),
                              (listing()+"\n99; 0 99 TABLE DATA nextstop app_attest_keys nextstop_app", "handoff"),
                              (listing("backup"), "handoff")]:
            with self.assertRaises(ValueError):
                transfer.validate_listing(text, purpose, 17)
        filtered = transfer.validate_listing("1; 0 0 EXTENSION - postgis postgres\n2; 0 0 SCHEMA - nextstop nextstop_app\n" + listing(), "handoff", 17)
        self.assertIn("; 1; 0 0 EXTENSION", filtered)
        self.assertIn("; 2; 0 0 SCHEMA", filtered)

    def test_prepare_reads_only_local_toc_and_creates_private_review_artifacts(self):
        with tempfile.TemporaryDirectory() as value:
            directory = Path(value)
            archive = directory / "handoff.dump"
            archive.write_bytes(b"synthetic archive only")
            archive.chmod(0o600)
            with patch.object(transfer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, listing(), "")) as run:
                receipt = transfer.prepare(archive, directory, "handoff", 17)
            self.assertEqual(run.call_args.args[0], ["pg_restore", "--list", str(archive)])
            self.assertFalse(receipt["durableStorageAllowed"])
            self.assertEqual((directory / "restore.list").stat().st_mode & 0o777, 0o600)
            self.assertEqual((directory / "archive-receipt.json").stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                transfer.write_private(directory / "archive-receipt.json", "overwrite")

    def test_backup_requires_private_schema_supplement_bound_into_receipt(self):
        with tempfile.TemporaryDirectory() as value:
            directory = Path(value)
            archive = directory / "backup.dump"
            archive.write_bytes(b"synthetic archive only")
            archive.chmod(0o600)
            with patch.object(transfer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, listing("backup"), "")):
                with self.assertRaises(ValueError):
                    transfer.prepare(archive, directory, "backup", 17)
                supplement = directory / "report-schema.sql"
                supplement.write_text("-- synthetic catalog DDL only")
                supplement.chmod(0o644)
                with self.assertRaises(ValueError):
                    transfer.prepare(archive, directory, "backup", 17)
                supplement.chmod(0o600)
                receipt = transfer.prepare(archive, directory, "backup", 17)
                self.assertEqual(receipt["reportSchema"]["sha256"], transfer.hashlib.sha256(supplement.read_bytes()).hexdigest())
                self.assertEqual(receipt["excludedTables"], ["nextstop.user_error_reports"])

    def test_owner_dump_with_embedded_report_schema_does_not_restore_duplicate_supplement(self):
        with tempfile.TemporaryDirectory() as value:
            directory = Path(value)
            archive = directory / "backup.dump"
            archive.write_bytes(b"synthetic initial owner archive")
            archive.chmod(0o600)
            toc = "90; 1259 90 TABLE nextstop user_error_reports nextstop_app\n" + listing("backup")
            with patch.object(transfer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, toc, "")):
                receipt = transfer.prepare(archive, directory, "backup", 17)
            self.assertFalse(receipt["restoreSupplementRequired"])
            self.assertNotIn("reportSchema", receipt)
            self.assertEqual(receipt["excludedTableData"], ["nextstop.user_error_reports"])

    def test_private_permissions_and_transfer_expiry_fail_closed(self):
        with tempfile.TemporaryDirectory() as value:
            directory = Path(value)
            archive = directory / "handoff.dump"
            archive.write_bytes(b"synthetic")
            archive.chmod(0o644)
            with self.assertRaises(ValueError):
                transfer.prepare(archive, directory, "handoff", 17)
            archive.chmod(0o600)
            os.utime(archive, (1, 1))
            with self.assertRaises(ValueError):
                transfer.prepare(archive, directory, "handoff", 17)
            link = directory / "link.dump"
            link.symlink_to(archive)
            with self.assertRaises(ValueError):
                transfer.prepare(link, directory, "handoff", 17)


if __name__ == "__main__":
    unittest.main()
