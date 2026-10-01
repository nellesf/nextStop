import importlib.util
from pathlib import Path
import shlex
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
        shell_script = shlex.split(script)[5]
        archive_check = shell_script.partition("<<'PY'\n")[2].rpartition('\nPY\n')[0]
        self.assertIn('validate_archive_inventory(listing,', archive_check)
        compile(archive_check, 'remote_archive_inventory', 'exec')

    def test_archive_added_private_table_fails_even_after_source_inventory_passed(self):
        listing = '\n'.join(f'{index}; 0 1 TABLE DATA nextstop {table} nextstop_app'
                            for index, table in enumerate(sorted(seed.PUBLIC_TABLES), 1))
        seed.validate_archive_inventory(listing, seed.PUBLIC_TABLES)
        for unexpected in ['private_events', 'app_attest_keys']:
            with self.assertRaises(RuntimeError):
                seed.validate_archive_inventory(listing + f'\n99; 0 1 TABLE DATA nextstop {unexpected} nextstop_app', seed.PUBLIC_TABLES)

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
        self.assertIn('--schema=nextstop', restored)
        self.assertIn('CREATE SCHEMA nextstop AUTHORIZATION nextstop_app', restored)
        self.assertIn('CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public', restored)
        self.assertIn('CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public', restored)
        self.assertIn('DROP SCHEMA nextstop"', restored)
        self.assertNotIn('DROP SCHEMA nextstop CASCADE', restored)
        self.assertIn('Private staging tables must be empty', restored)
        self.assertIn('ANALYZE', restored)

    def test_cleanup_is_privileged_but_only_for_exact_generated_files(self):
        directory = '/srv/nextstop/.public-seed-' + 'a' * 32
        for staging in [False, True]:
            command = seed.cleanup_script(directory, staging=staging)
            self.assertIn('sudo rm -f -- ' + directory + '/public.dump', command)
            self.assertIn('sudo rmdir -- ' + directory, command)
            self.assertNotIn('rm -rf', command)
            self.assertNotIn('*', command)
        self.assertIn('/tmp/nextstop-public-seed-' + 'a' * 32 + '.tar.gz', seed.cleanup_script(directory, staging=True))
        for unsafe in ['/srv/nextstop', directory + '/../database', '/tmp/public-seed', '/srv/nextstop/.public-seed-abc']:
            with self.assertRaises(RuntimeError):
                seed.cleanup_script(unsafe)


if __name__ == '__main__':
    unittest.main()
