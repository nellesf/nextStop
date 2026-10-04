import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('security', Path(__file__).with_name('scan-image.py'))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
COMMIT = 'a' * 40
IMAGE_ID = 'sha256:' + 'b' * 64
IMAGE = 'example.invalid/project/image@sha256:' + 'c' * 64


def report():
    return {'SchemaVersion': 2, 'Trivy': {'Version': s.VERSION},
            'Metadata': {'ImageID': IMAGE_ID, 'OS': {'Family': 'debian'}},
            'Results': [{'Class': 'os-pkgs', 'Packages': [{'Name': 'libc'}]},
                        {'Class': 'lang-pkgs', 'Type': 'node-pkg', 'Packages': [{'Name': 'fastify'}]}]}


class SecurityTests(unittest.TestCase):
    def test_real_image_node_package_inventory_and_npm_lockfile_types_are_supported(self):
        for kind in ('node-pkg', 'npm'):
            data = report(); data['Results'][1]['Type'] = kind
            self.assertEqual(s.evaluate(data, IMAGE_ID)[1], [])
        data = report(); data['Results'][1]['Type'] = 'pip'
        with self.assertRaises(s.GateError): s.evaluate(data, IMAGE_ID)

    def test_high_unfixed_blocks_medium_remains_reported(self):
        data = report()
        data['Results'][0]['Vulnerabilities'] = [
            {'VulnerabilityID': 'CVE-example', 'Severity': 'HIGH', 'Status': 'will_not_fix'},
            {'Severity': 'MEDIUM'}]
        counts, blockers = s.evaluate(data, IMAGE_ID)
        self.assertEqual(counts['HIGH'], 1)
        self.assertEqual(counts['MEDIUM'], 1)
        self.assertEqual(len(blockers), 1)
        self.assertEqual(blockers[0]['Status'], 'will_not_fix')

    def test_missing_inventory_wrong_identity_tool_version_eosl_or_suppression_fails(self):
        cases = []
        for key, value in [('SchemaVersion', 1), ('Trivy', {}), ('Metadata', {})]:
            data = report(); data[key] = value; cases.append(data)
        for index in (0, 1):
            data = report(); data['Results'].pop(index); cases.append(data)
        data = report(); data['Metadata']['OS']['EOSL'] = True; cases.append(data)
        data = report(); data['Results'][0]['ExperimentalModifiedFindings'] = [{}]; cases.append(data)
        for data in cases:
            with self.subTest(data=data), self.assertRaises(s.GateError):
                s.evaluate(data, IMAGE_ID)

    def archive(self, path, *, commit=COMMIT, architecture='amd64'):
        config = json.dumps({'architecture': architecture, 'os': 'linux',
                             'config': {'Labels': {'org.opencontainers.image.revision': commit}}}).encode()
        with tarfile.open(path, 'w') as archive:
            for name, payload in [('config.json', config), ('manifest.json', b'[{"Config":"config.json"}]')]:
                info = tarfile.TarInfo(name); info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
        return 'sha256:' + hashlib.sha256(config).hexdigest()

    def test_archive_checks_actual_config_bytes_platform_and_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.tar'
            expected = self.archive(path)
            self.assertEqual(s.archive_identity(path, COMMIT), expected)
            self.archive(path, architecture='arm64')
            with self.assertRaises(s.GateError): s.archive_identity(path, COMMIT)
            self.archive(path, commit='d' * 40)
            with self.assertRaises(s.GateError): s.archive_identity(path, COMMIT)

    def test_download_checksum_failure_never_extracts_or_executes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(s.urllib.request, 'urlopen') as download:
            download.return_value.__enter__.return_value.read.return_value = b'untrusted executable'
            with self.assertRaises(s.GateError): s.install(Path(tmp))
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_scan_uses_fresh_db_isolated_config_no_environment_bypass_and_bound_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.tar'; expected = self.archive(path)
            output = Path(tmp) / 'receipt.json'
            def fake_command(args, **kwargs):
                self.assertNotIn('TRIVY_IGNORE_UNFIXED', kwargs['env'])
                self.assertNotIn('TRIVY_SKIP_DB_UPDATE', kwargs['env'])
                self.assertIn('--ignore-unfixed=false', args)
                self.assertEqual(args[args.index('--pkg-types') + 1], 'os,library')
                self.assertFalse((Path(args[args.index('--cache-dir') + 1])).exists())
                self.assertEqual(Path(args[args.index('--ignorefile') + 1]).read_text(), '')
                data = report(); data['Metadata']['ImageID'] = expected
                Path(args[args.index('--output') + 1]).write_text(json.dumps(data))
            with patch.object(s, 'install', return_value=Path('/pinned/trivy')), \
                    patch.object(s, 'command', side_effect=fake_command), patch('builtins.print'), \
                    patch.dict(os.environ, {'TRIVY_IGNORE_UNFIXED': 'true', 'TRIVY_SKIP_DB_UPDATE': 'true'}):
                value = s.scan(path, COMMIT, output)
            self.assertTrue(value['passed'])
            self.assertEqual(value['imageId'], expected)
            self.assertIsNone(value['image'])
            self.assertEqual(value['reportSHA256'], hashlib.sha256(output.with_suffix('.trivy.json').read_bytes()).hexdigest())

    def test_digest_binding_rejects_different_config_unscanned_digest_or_revision(self):
        with tempfile.TemporaryDirectory() as tmp, patch('builtins.print'):
            output = Path(tmp) / 'receipt.json'
            receipt = {'passed': True, 'imageId': IMAGE_ID, 'commit': COMMIT}
            inspect = [{'Id': IMAGE_ID, 'RepoDigests': [IMAGE],
                        'Config': {'Labels': {'org.opencontainers.image.revision': COMMIT}}}]
            for field, value in [('Id', 'sha256:' + 'e' * 64), ('RepoDigests', []), ('Config', {})]:
                changed = copy.deepcopy(inspect); changed[0][field] = value
                output.write_text(json.dumps(receipt))
                with self.assertRaises(s.GateError): s.bind(output, changed, IMAGE)
            output.write_text(json.dumps(receipt))
            self.assertEqual(s.bind(output, inspect, IMAGE)['image'], IMAGE)
            output.write_text(json.dumps({**receipt, 'passed': False}))
            with self.assertRaises(s.GateError): s.bind(output, inspect, IMAGE)

    def test_tool_failure_timeout_and_secret_output_are_not_success_or_leaked(self):
        for outcome in [subprocess.CompletedProcess([], 2, 'secret-token', 'secret-token'),
                        subprocess.TimeoutExpired('secret-token', 1, 'secret-token')]:
            with self.subTest(outcome=outcome), patch.object(s.subprocess, 'run') as run:
                if isinstance(outcome, Exception): run.side_effect = outcome
                else: run.return_value = outcome
                with self.assertRaises(s.GateError) as error: s.command(['scanner'])
                self.assertNotIn('secret-token', str(error.exception))


if __name__ == '__main__': unittest.main()
