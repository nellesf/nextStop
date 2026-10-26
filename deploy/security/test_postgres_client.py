import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


ROOT = Path(__file__).parent
s = module('client_scan', ROOT / 'scan-image.py')
p = module('client_prepare', ROOT / 'postgres-client/prepare.py')
COMMIT = 'a' * 40
CONFIG = 'sha256:' + 'b' * 64
IMAGE = p.REGISTRY + '@sha256:' + 'c' * 64
MEDIA = 'application/vnd.docker.distribution.manifest.v2+json'
DATA = {'image': IMAGE, 'configDigest': CONFIG, 'sourceCommit': COMMIT,
        'version': '17.11', 'platform': 'linux/amd64'}


def configuration():
    return {'User': '65532:65532', 'Cmd': ['psql', '--version'], 'WorkingDir': '/tmp',
            'Labels': {'org.opencontainers.image.revision': COMMIT,
                       'org.opencontainers.image.version': '17.11',
                       'org.opencontainers.image.base.digest': s.POSTGRES_CLIENT_BASE,
                       'tech.nextstop.image-purpose': 'postgres-client'}}


def inspection():
    return [{'Id': CONFIG, 'Os': 'linux', 'Architecture': 'amd64',
             'RepoDigests': [IMAGE], 'Config': configuration()}]


def archive(path, config):
    payload = json.dumps({'architecture': 'amd64', 'os': 'linux', 'config': config}).encode()
    with tarfile.open(path, 'w') as out:
        for name, value in [('config.json', payload), ('manifest.json', b'[{"Config":"config.json"}]')]:
            item = tarfile.TarInfo(name)
            item.size = len(value)
            out.addfile(item, io.BytesIO(value))


class ClientSecurityTests(unittest.TestCase):
    def test_client_profile_checks_configuration_without_weakening_backend_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.tar'
            archive(path, configuration())
            image_id = s.archive_identity(path, COMMIT, 'postgres-client')
        report = {'SchemaVersion': 2, 'Trivy': {'Version': s.VERSION},
                  'Metadata': {'ImageID': image_id, 'OS': {'Family': 'alpine'}},
                  'Results': [{'Class': 'os-pkgs', 'Packages': [{'Name': 'musl'}]}]}
        self.assertEqual(s.evaluate(report, image_id, 'postgres-client')[1], [])
        with self.assertRaises(s.GateError):
            s.evaluate(report, image_id)
        for change in ({'Family': 'debian'}, {'Family': 'alpine', 'EOSL': True}):
            report['Metadata']['OS'] = change
            with self.assertRaises(s.GateError):
                s.evaluate(report, image_id, 'postgres-client')

    def test_server_metadata_root_user_wrong_base_or_source_cannot_pass_client_gate(self):
        changes = [('User', '0'), ('Entrypoint', ['docker-entrypoint.sh']),
                   ('Cmd', ['postgres']), ('Volumes', {'/var/lib/postgresql/data': {}}),
                   ('ExposedPorts', {'5432/tcp': {}}), ('WorkingDir', '/')]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.tar'
            for key, value in changes:
                config = configuration(); config[key] = value; archive(path, config)
                with self.subTest(key=key), self.assertRaises(s.GateError):
                    s.archive_identity(path, COMMIT, 'postgres-client')
            for key in configuration()['Labels']:
                config = configuration(); config['Labels'][key] = 'unreviewed'; archive(path, config)
                with self.subTest(label=key), self.assertRaises(s.GateError):
                    s.archive_identity(path, COMMIT, 'postgres-client')
            with self.assertRaises(s.GateError):
                s.archive_identity(path, COMMIT, 'arbitrary-bypass')

    def test_client_profile_retains_unfixed_and_suppression_gates(self):
        report = {'SchemaVersion': 2, 'Trivy': {'Version': s.VERSION},
                  'Metadata': {'ImageID': CONFIG, 'OS': {'Family': 'alpine'}},
                  'Results': [{'Class': 'os-pkgs', 'Packages': [{'Name': 'musl'}],
                               'Vulnerabilities': [{'Severity': 'CRITICAL', 'Status': 'will_not_fix'}]}]}
        counts, blockers = s.evaluate(report, CONFIG, 'postgres-client')
        self.assertEqual(counts['CRITICAL'], 1)
        self.assertEqual(len(blockers), 1)
        report['Results'][0]['ExperimentalModifiedFindings'] = [{}]
        with self.assertRaises(s.GateError): s.evaluate(report, CONFIG, 'postgres-client')

    def test_bound_receipt_retains_client_profile_and_rejects_server_configuration(self):
        receipt = {'passed': True, 'imageId': CONFIG, 'commit': COMMIT, 'inventoryProfile': 'postgres-client'}
        with tempfile.TemporaryDirectory() as tmp, patch('builtins.print'):
            path = Path(tmp) / 'receipt.json'; path.write_text(json.dumps(receipt))
            self.assertEqual(s.bind(path, inspection(), IMAGE)['inventoryProfile'], 'postgres-client')
            changed = inspection(); changed[0]['Config']['User'] = 'root'
            path.write_text(json.dumps(receipt))
            with self.assertRaises(s.GateError): s.bind(path, changed, IMAGE)

    def test_prepare_rejects_unreviewed_metadata_before_cloud_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.json'
            changes = [('image', IMAGE.replace(p.REGISTRY, 'untrusted.invalid/tool')),
                       ('configDigest', 'latest'), ('sourceCommit', 'main'),
                       ('version', '17.5'), ('platform', 'linux/arm64')]
            for key, value in changes:
                path.write_text(json.dumps({**DATA, key: value}))
                with self.subTest(key=key), patch.object(p, 'command') as run, self.assertRaises(p.PrepareError):
                    p.prepare(path, run=run)
                run.assert_not_called()

    def test_prepare_requires_protected_account_and_token_only_uses_stdin(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.json'; path.write_text(json.dumps(DATA))
            with self.assertRaises(p.PrepareError):
                p.prepare(path, run=lambda *a, **kw: 'operator@example.invalid')
            calls = []
            def run(args, **kwargs):
                calls.append((args, kwargs))
                self.assertNotIn('synthetic-private-token', str(args))
                if args[:4] == ['gcloud', 'config', 'get-value', 'account']: return p.ACCOUNT
                if args[:3] == ['gcloud', 'auth', 'print-access-token']: return 'synthetic-private-token'
                if kwargs.get('input_text'):
                    self.assertEqual(kwargs['input_text'], 'synthetic-private-token\n')
                    return json.dumps({**DATA, 'passed': True, 'mode': 'postgres-client-prepared'})
                return ''
            self.assertTrue(p.prepare(path, run=run)['passed'])
            self.assertEqual(sum(bool(kw.get('input_text')) for _, kw in calls), 1)

    def remote(self):
        namespace = {}
        exec(p.REMOTE, namespace)
        return namespace

    def test_prepare_accepts_classic_or_exact_containerd_identity_and_rejects_mismatches(self):
        ns = self.remote(); data = {**DATA, 'baseDigest': p.BASE}
        self.assertEqual(ns['verify_manifest']({'schemaVersion': 2, 'mediaType': MEDIA,
                                              'config': {'digest': CONFIG}}, data), MEDIA)
        ns['verify_image'](inspection(), data, MEDIA)
        containerd = inspection(); containerd[0]['Id'] = IMAGE.rsplit('@', 1)[1]
        containerd[0]['Descriptor'] = {'digest': containerd[0]['Id'], 'mediaType': MEDIA}
        ns['verify_image'](containerd, data, MEDIA)
        for change in ('descriptor', 'revision', 'volume', 'platform', 'repodigest'):
            value = copy.deepcopy(containerd)
            if change == 'descriptor': value[0]['Descriptor']['digest'] = CONFIG
            if change == 'revision': value[0]['Config']['Labels']['org.opencontainers.image.revision'] = 'd' * 40
            if change == 'volume': value[0]['Config']['Volumes'] = {'/data': {}}
            if change == 'platform': value[0]['Architecture'] = 'arm64'
            if change == 'repodigest': value[0]['RepoDigests'] = []
            with self.subTest(change=change), self.assertRaises(ns['GateError']):
                ns['verify_image'](value, data, MEDIA)
        with self.assertRaises(ns['GateError']):
            ns['verify_manifest']({'schemaVersion': 2, 'mediaType': MEDIA,
                                   'config': {'digest': 'sha256:' + 'f' * 64}}, data)

    def test_remote_credentials_are_removed_on_login_or_pull_failure_without_secret_logs(self):
        original_temporary_directory = tempfile.TemporaryDirectory
        for failing in ('login', 'pull'):
            ns = self.remote(); paths = []
            def temporary_directory(**kwargs):
                self.assertEqual(kwargs['dir'], '/run')
                context = original_temporary_directory(prefix='nextstop-test-client-')
                paths.append(Path(context.name))
                return context
            def execute(args, env, token=None, timeout=90):
                self.assertEqual(Path(env['DOCKER_CONFIG']).stat().st_mode & 0o777, 0o700)
                self.assertNotIn('synthetic-private-token', str(args) + str(env))
                if args[1] == 'login':
                    self.assertEqual(token, 'synthetic-private-token\n')
                    (Path(env['DOCKER_CONFIG']) / 'config.json').write_text('synthetic-private-token')
                if args[1] == failing: raise ns['GateError']()
                return json.dumps({'schemaVersion': 2, 'mediaType': MEDIA, 'config': {'digest': CONFIG}})
            ns['execute'] = execute
            data = {**DATA, 'baseDigest': p.BASE, 'project': p.PROJECT, 'registryHost': p.REGISTRY.split('/')[0]}
            with patch.object(ns['os'], 'geteuid', return_value=0), \
                    patch.object(ns['signal'], 'signal'), \
                    patch.object(ns['pathlib'].Path, 'read_text', return_value=
                                 'NEXTSTOP_ENVIRONMENT=production\nPROJECT_ID=nextstop-tech-staging\nDOMAIN=api.nextstop.tech\n'), \
                    patch.object(ns['tempfile'], 'TemporaryDirectory', side_effect=temporary_directory), \
                    patch.object(ns['sys'], 'stdin', io.StringIO('synthetic-private-token\n')), \
                    patch.object(ns['sys'], 'stdout', io.StringIO()) as output, \
                    self.assertRaises(SystemExit):
                ns['main'](data)
            self.assertNotIn('synthetic-private-token', output.getvalue())
            self.assertTrue(paths)
            self.assertTrue(all(not path.exists() for path in paths))

    def test_prepare_command_does_not_include_private_subprocess_output(self):
        result = subprocess.CompletedProcess([], 1, 'synthetic-private-token', 'synthetic-private-token')
        with patch.object(p.subprocess, 'run', return_value=result), self.assertRaises(p.PrepareError) as error:
            p.command(['safe'], input_text='synthetic-private-token')
        self.assertNotIn('synthetic-private-token', str(error.exception))


if __name__ == '__main__': unittest.main()
