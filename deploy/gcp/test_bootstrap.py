"""Execute the bootstrap against an isolated filesystem and package/service stubs.

The package stub starts Docker during installation, matching the startup ordering
that originally bypassed daemon.json. No real daemon, package manager or mounts run.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'deploy/gcp-vm/bootstrap-vm.sh'
STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
r = Path(os.environ['NEXTSTOP_BOOTSTRAP_TEST_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (r/'events').open('a') as f: f.write(json.dumps([name, args])+'\n')
def start():
    state = r/'running-root'
    if state.exists(): return
    dropin = r/'loaded-dropin'
    guarded = dropin.exists() and 'RequiresMountsFor=' in dropin.read_text() and 'ExecStartPre=/usr/bin/mountpoint -q ' in dropin.read_text()
    mounted = (r/'mounted').exists()
    if os.environ.get('NEXTSTOP_BOOTSTRAP_TEST_LOSE_MOUNT') == '1': mounted = False
    if guarded and not mounted: sys.exit(71)
    config = r/'etc/docker/daemon.json'
    root = json.loads(config.read_text())['data-root'] if config.exists() else str(r/'varlib/docker')
    state.write_text(root)
    (r/'first-start').write_text(json.dumps({'root': root, 'guarded': guarded}))
if name == 'blkid':
    if '-s' in args: print('fixture-disk-uuid')
elif name == 'mkfs.ext4':
    sys.exit(81)
elif name == 'mountpoint':
    sys.exit(0 if (r/'mounted').exists() else 1)
elif name == 'mount':
    if os.environ.get('NEXTSTOP_BOOTSTRAP_TEST_MOUNT_FAIL') == '1': sys.exit(72)
    (r/'mounted').touch()
elif name == 'find':
    entries = list(Path(args[0]).iterdir())
    if entries: print(entries[0])
elif name == 'systemctl':
    if args == ['daemon-reload']:
        (r/'loaded-dropin').write_text((r/'etc/systemd/system/docker.service.d/10-nextstop-data-root.conf').read_text())
    elif args == ['enable', '--now', 'docker', 'nginx']: start()
    else: sys.exit(82)
elif name == 'apt-get':
    if args[0] == 'install': start()
elif name == 'docker':
    if args != ['info', '--format', '{{.DockerRootDir}}']: sys.exit(83)
    print(str(r/'wrong-root') if os.environ.get('NEXTSTOP_BOOTSTRAP_TEST_WRONG_ROOT') == '1' else (r/'running-root').read_text())
else: sys.exit(84)
'''


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nextstop-bootstrap-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('bin', 'etc', 'data', 'varlib'):
            (self.root/name).mkdir()
        (self.root/'device').touch()
        (self.root/'mounted').touch()
        (self.root/'etc/fstab').write_text('')
        stub = self.root/'bin/stub'
        stub.write_text(STUB)
        stub.chmod(0o755)
        for name in ('blkid', 'mkfs.ext4', 'mountpoint', 'mount', 'find', 'systemctl', 'apt-get', 'docker'):
            (self.root/'bin'/name).symlink_to(stub)
        source = SOURCE.read_text()
        for original, relative in (
            ('/dev/disk/by-id/google-nextstop-data', 'device'),
            ('/srv/nextstop', 'data'),
            ('/etc/', 'etc/'),
            ('/var/lib/', 'varlib/'),
            ('/opt/nextstop/', 'opt/'),
            ('/var/www/', 'www/'),
        ):
            source = source.replace(original, str(self.root)+'/'+relative)
        self.script = self.root/'bootstrap.sh'
        self.script.write_text(source)

    @property
    def marker(self):
        return self.root/'varlib/nextstop-bootstrap-complete'

    def run_bootstrap(self, **variables):
        env = dict(os.environ, NEXTSTOP_BOOTSTRAP_TEST_ROOT=str(self.root), **variables)
        env['PATH'] = str(self.root/'bin')+os.pathsep+env['PATH']
        result = subprocess.run(['bash', str(self.script)], env=env, capture_output=True, text=True, timeout=10)
        self.events = [json.loads(line) for line in (self.root/'events').read_text().splitlines()]
        return result

    def test_package_first_start_uses_data_disk_and_loaded_mount_guard(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root/'first-start').read_text()), {'root': str(self.root/'data/docker'), 'guarded': True})
        self.assertTrue(self.marker.exists())
        installs = [event for event in self.events if event[0] == 'apt-get' and event[1][0] == 'install']
        self.assertEqual(len(installs), 1)
        self.assertLess(self.events.index(['systemctl', ['daemon-reload']]), self.events.index(installs[0]))

    def test_actual_wrong_root_cannot_mark_bootstrap_complete(self):
        result = self.run_bootstrap(NEXTSTOP_BOOTSTRAP_TEST_WRONG_ROOT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertIn('initial bootstrap remains incomplete', result.stderr)

    def test_lost_mount_prevents_package_daemon_start(self):
        result = self.run_bootstrap(NEXTSTOP_BOOTSTRAP_TEST_LOSE_MOUNT='1')
        self.assertEqual(result.returncode, 71)
        self.assertFalse((self.root/'running-root').exists())
        self.assertFalse(self.marker.exists())

    def test_failed_mount_never_installs_or_starts_services(self):
        (self.root/'mounted').unlink()
        result = self.run_bootstrap(NEXTSTOP_BOOTSTRAP_TEST_MOUNT_FAIL='1')
        self.assertEqual(result.returncode, 72)
        self.assertFalse(any(event[0] in ('apt-get', 'systemctl') for event in self.events))
        self.assertFalse(self.marker.exists())

    def test_existing_old_store_is_preserved_without_package_changes(self):
        store = self.root/'varlib/docker'
        store.mkdir()
        sentinel = store/'existing-volume'
        sentinel.write_text('preserve-user-data')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'preserve-user-data')
        self.assertFalse(any(event[0] in ('apt-get', 'systemctl') for event in self.events))
        self.assertFalse((self.root/'etc/docker/daemon.json').exists())

    def test_existing_different_config_is_not_overwritten(self):
        config = self.root/'etc/docker/daemon.json'
        config.parent.mkdir()
        config.write_text('{"data-root":"/operator-owned"}')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), '{"data-root":"/operator-owned"}')
        self.assertFalse(any(event[0] in ('apt-get', 'systemctl') for event in self.events))

    def test_completed_bootstrap_keeps_existing_service_path_unchanged(self):
        self.marker.write_text('existing-marker')
        (self.root/'running-root').write_text('/existing-production-root')
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text(), 'existing-marker')
        self.assertFalse(any(event[0] in ('apt-get', 'docker') for event in self.events))
        self.assertEqual([event for event in self.events if event[0] == 'systemctl'], [['systemctl', ['enable', '--now', 'docker', 'nginx']]])
        self.assertFalse((self.root/'etc/docker/daemon.json').exists())


if __name__ == '__main__':
    unittest.main()
