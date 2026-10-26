#!/usr/bin/env python3
"""Pull only the reviewed backup-client digest using the protected production identity."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shlex
import subprocess

PROJECT = 'nextstop-tech-staging'
INSTANCE = 'nextstop-backend'
ZONE = 'europe-west3-a'
ACCOUNT = f'nextstop-production-deploy@{PROJECT}.iam.gserviceaccount.com'
REGISTRY = f'europe-west3-docker.pkg.dev/{PROJECT}/nextstop/postgres-client'
BASE = 'sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4'
METADATA = Path(__file__).with_name('image.json')


class PrepareError(Exception):
    pass


def metadata(path=METADATA):
    value = json.loads(Path(path).read_text())
    if (not isinstance(value, dict) or value.get('version') != '17.11'
            or value.get('platform') != 'linux/amd64'
            or not isinstance(value.get('image'), str)
            or not re.fullmatch(re.escape(REGISTRY) + r'@sha256:[0-9a-f]{64}', value['image'])
            or not isinstance(value.get('configDigest'), str)
            or not re.fullmatch(r'sha256:[0-9a-f]{64}', value['configDigest'])
            or not isinstance(value.get('sourceCommit'), str)
            or not re.fullmatch(r'[0-9a-f]{40}', value['sourceCommit'])):
        raise PrepareError('invalid_client_metadata')
    return {key: value[key] for key in ('image', 'configDigest', 'sourceCommit', 'version', 'platform')}


def command(args, *, input_text=None, timeout=120):
    try:
        result = subprocess.run(args, input=input_text, capture_output=True, text=True,
                                check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise PrepareError('operation_unavailable_or_timeout') from None
    if result.returncode:
        raise PrepareError('operation_failed_private_output_suppressed')
    return result.stdout


# No credentials appear in this code or its SSH command line. The short-lived
# access token is read from SSH stdin and supplied to docker login via stdin.
# The remote process owns cleanup, including when the caller disconnects.
REMOTE = r'''
import datetime, json, os, pathlib, signal, subprocess, sys, tempfile

class GateError(Exception): pass

MEDIA_TYPES = ('application/vnd.docker.distribution.manifest.v2+json',
               'application/vnd.oci.image.manifest.v1+json')

def execute(args, env, token=None, timeout=90):
    try:
        result = subprocess.run(args, input=token, env=env, capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise GateError() from None
    if result.returncode: raise GateError()
    return result.stdout

def verify_manifest(value, data):
    if (not isinstance(value, dict) or value.get('schemaVersion') != 2
            or value.get('mediaType') not in MEDIA_TYPES
            or value.get('config', {}).get('digest') != data['configDigest']):
        raise GateError()
    return value['mediaType']

def verify_image(value, data, media_type):
    if not isinstance(value, list) or len(value) != 1: raise GateError()
    image = value[0]
    digest = data['image'].rsplit('@', 1)[1]
    descriptor = image.get('Descriptor')
    descriptor_ok = (isinstance(descriptor, dict) and descriptor.get('digest') == digest
                     and descriptor.get('mediaType') == media_type)
    identity_ok = ((image.get('Id') == data['configDigest'] and (descriptor is None or descriptor_ok))
                   or (image.get('Id') == digest and descriptor_ok))
    config = image.get('Config') or {}
    labels = config.get('Labels') or {}
    if (not identity_ok or data['image'] not in (image.get('RepoDigests') or [])
            or image.get('Os') != 'linux' or image.get('Architecture') != 'amd64'
            or labels.get('org.opencontainers.image.revision') != data['sourceCommit']
            or labels.get('org.opencontainers.image.base.digest') != data['baseDigest']
            or labels.get('org.opencontainers.image.version') != '17.11'
            or labels.get('tech.nextstop.image-purpose') != 'postgres-client'
            or config.get('User') != '65532:65532' or config.get('WorkingDir') != '/tmp'
            or config.get('Entrypoint') or config.get('Cmd') != ['psql', '--version']
            or config.get('Volumes') or config.get('ExposedPorts')):
        raise GateError()

def interrupted(_signum, _frame): raise GateError()

def main(data):
    phase = 'host-preflight'
    try:
        if os.geteuid() != 0: raise GateError()
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(signum, interrupted)
        values = {}
        for line in pathlib.Path('/etc/nextstop/release.env').read_text().splitlines():
            key, separator, value = line.strip().partition('=')
            if separator and key in ('NEXTSTOP_ENVIRONMENT', 'PROJECT_ID', 'DOMAIN'):
                values[key] = value.strip('"\'')
        if values != {'NEXTSTOP_ENVIRONMENT':'production', 'PROJECT_ID':data['project'],
                      'DOMAIN':'api.nextstop.tech'}: raise GateError()
        token = sys.stdin.read(16386).strip()
        if not token or len(token) > 16384 or any(c.isspace() for c in token): raise GateError()
        with tempfile.TemporaryDirectory(prefix='nextstop-postgres-client-registry-', dir='/run') as directory:
            os.chmod(directory, 0o700)
            env = {'PATH':'/usr/sbin:/usr/bin:/sbin:/bin', 'LANG':'C.UTF-8', 'DOCKER_CONFIG':directory}
            phase = 'registry-login'
            execute(['docker','login','--username','oauth2accesstoken','--password-stdin',data['registryHost']],
                    env, token=token + '\n')
            del token
            phase = 'registry-manifest'
            manifest = json.loads(execute(['docker','manifest','inspect',data['image']], env))
            media_type = verify_manifest(manifest, data)
            phase = 'image-pull'
            execute(['docker','pull','--platform','linux/amd64',data['image']], env, timeout=600)
            phase = 'image-identity'
            verify_image(json.loads(execute(['docker','image','inspect',data['image']], env)), data, media_type)
            phase = 'credential-cleanup'
        print(json.dumps({'passed':True, 'mode':'postgres-client-prepared', 'image':data['image'],
                          'configDigest':data['configDigest'], 'sourceCommit':data['sourceCommit'],
                          'version':'17.11', 'platform':'linux/amd64',
                          'preparedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    except (GateError, OSError, ValueError, KeyError, TypeError, AttributeError):
        print(json.dumps({'passed':False, 'mode':'postgres-client-prepared', 'phase':phase}))
        raise SystemExit(1) from None
'''


def ssh(script):
    return ['gcloud', 'compute', 'ssh', INSTANCE, f'--project={PROJECT}', f'--zone={ZONE}',
            '--tunnel-through-iap', '--quiet', '--command=' + script]


def prepare(path=METADATA, *, run=command):
    data = metadata(path)
    if run(['gcloud', 'config', 'get-value', 'account']).strip() != ACCOUNT:
        raise PrepareError('protected_production_identity_required')
    run(['git', 'merge-base', '--is-ancestor', data['sourceCommit'], 'origin/main'])
    run(ssh('true'))  # Isolate any first-use SSH key banner from the JSON response.
    token = run(['gcloud', 'auth', 'print-access-token', '--account=' + ACCOUNT, '--quiet']).strip()
    if not token or len(token) > 16384 or any(c.isspace() for c in token):
        raise PrepareError('registry_credential_invalid')
    payload = {**data, 'project':PROJECT, 'baseDigest':BASE, 'registryHost':REGISTRY.split('/')[0]}
    program = REMOTE + '\nmain(json.loads(' + repr(json.dumps(payload)) + '))\n'
    try:
        raw = run(ssh(shlex.join(['sudo', '/usr/bin/python3', '-c', program])),
                  input_text=token + '\n', timeout=900)
    finally:
        del token
    result = json.loads(raw)
    if (not isinstance(result, dict) or result.get('passed') is not True
            or result.get('mode') != 'postgres-client-prepared'
            or any(result.get(key) != value for key, value in data.items())):
        raise PrepareError('prepared_image_receipt_invalid')
    return result


def main():
    try:
        print(json.dumps(prepare(), sort_keys=True))
    except (PrepareError, OSError, ValueError, KeyError, TypeError):
        print(json.dumps({'passed':False, 'mode':'postgres-client-prepared',
                          'error':'Client preparation failed; private output suppressed.'}))
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
