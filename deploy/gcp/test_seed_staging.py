import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('seed_staging', Path(__file__).with_name('seed-staging.py'))
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class PublicSeedTests(unittest.TestCase):
    def test_unknown_or_missing_table_fails_closed_before_public_dump(self):
        known = sorted(seed.PUBLIC_TABLES | set(seed.PRIVATE_TABLES))
        self.assertEqual(len(known), 23)
        seed.validate_source_inventory(known)
        for tables in [known + ['private_events'], known[:-1], None]:
            with self.assertRaises(RuntimeError):
                seed.validate_source_inventory(tables)

    def test_dump_scope_and_private_data_exclusions_are_explicit(self):
        script = seed.dump_script('/srv/nextstop/.public-seed-' + 'a' * 32)
        self.assertIn('--schema=nextstop', script)
        self.assertIn('--no-owner --no-privileges', script)
        self.assertIn('--lock-wait-timeout=500ms', script)
        for table in seed.PRIVATE_TABLES:
            self.assertIn('--exclude-table-data=nextstop.' + table, script)
        self.assertIn('TABLE DATA nextstop', script)

    def test_generated_remote_scripts_parse_and_destination_is_guarded(self):
        auth = {field: 'public-fixture' for field in seed.AUTH_FIELDS}
        prepared = seed.prepare_script(auth, '/opt/nextstop/test', '/tmp/test.tar.gz')
        restored = seed.restore_script('/srv/nextstop/test', {'size': 123, 'sha256': 'a' * 64})
        for name, source in [('metadata', seed.metadata_script()), ('prepare', prepared), ('restore', restored)]:
            compile(source, name, 'exec')
        for source in [prepared, restored]:
            self.assertIn('nextstop-tech-testing', source)
            self.assertIn("to_regnamespace('nextstop') IS NULL", source)
        self.assertIn('secrets.token_hex(32)', prepared)
        self.assertIn('--single-transaction', restored)
        self.assertIn('Private staging tables must be empty', restored)
        self.assertIn('ANALYZE', restored)


if __name__ == '__main__':
    unittest.main()
