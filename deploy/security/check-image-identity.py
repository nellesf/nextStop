#!/usr/bin/env python3
"""Exercise the image identity gate against disposable, real Docker exports.

This checks archive/daemon identity only. It does not produce a vulnerability
scan receipt or replace the backend and database security scans.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import uuid


spec = importlib.util.spec_from_file_location('image_security', Path(__file__).with_name('scan-image.py'))
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)


def check(commit: str, expected_store: str, output: Path):
    if not security.COMMIT.fullmatch(commit):
        raise security.GateError('commit_invalid')
    output.parent.mkdir(parents=True, exist_ok=True)
    observations = []
    variants = [('manifest', 'false'), ('default', None)] if expected_store == 'classic' else [
        ('manifest', 'false'), ('attested-index', 'mode=min')]
    try:
        for variant, provenance in variants:
            tag = 'nextstop-identity-regression:' + uuid.uuid4().hex
            container = None
            with tempfile.TemporaryDirectory(prefix='nextstop-identity-regression-') as temporary:
                work = Path(temporary)
                (work / 'Dockerfile').write_text('FROM scratch\nCOPY payload /payload\n')
                (work / 'payload').write_text('Identity regression fixture; never executed.\n')
                build = ['docker', 'build', '--platform', 'linux/amd64', '--label',
                         'org.opencontainers.image.revision=' + commit, '--tag', tag]
                if provenance is not None:
                    build.append('--provenance=' + provenance)
                try:
                    security.command([*build, str(work)])
                    inspection = json.loads(security.command(['docker', 'image', 'inspect', tag]))
                    archive = work / 'image.tar'
                    security.command(['docker', 'image', 'save', '--output', str(archive), inspection[0]['Id']])
                    config_id, descriptors = security.archive_identities(archive, commit)
                    docker_id = security.verify_inspection(inspection, config_id, descriptors, commit)
                    observation = {'variant': variant, 'configId': config_id, 'dockerImageId': docker_id,
                                   'descriptor': inspection[0].get('Descriptor')}
                    observations.append(observation)
                    if (docker_id == config_id) != (expected_store == 'classic'):
                        raise security.GateError('unexpected_docker_storage_identity')
                    if expected_store == 'containerd':
                        expected_types = (('application/vnd.oci.image.index.v1+json',
                                           'application/vnd.docker.distribution.manifest.list.v2+json')
                                          if variant == 'attested-index' else
                                          ('application/vnd.oci.image.manifest.v1+json',
                                           'application/vnd.docker.distribution.manifest.v2+json'))
                        if (inspection[0].get('Descriptor') or {}).get('mediaType') not in expected_types:
                            raise security.GateError('expected_docker_descriptor_not_exercised')

                    wrong = copy.deepcopy(inspection)
                    wrong[0]['Id'] = 'sha256:' + '0' * 64
                    try:
                        security.verify_inspection(wrong, config_id, descriptors, commit)
                    except security.GateError:
                        pass
                    else:
                        raise security.GateError('different_image_identity_was_accepted')

                    # A config digest is not a usable local image reference on
                    # every Docker store. Create, but never start, a container
                    # using the exact identity returned by the gate.
                    container = security.command(['docker', 'create', '--platform', 'linux/amd64',
                                                  docker_id, '/not-executed']).strip()
                    observation['verifiedReferenceCreatesContainer'] = True
                finally:
                    if container:
                        subprocess.run(['docker', 'container', 'rm', '--force', container],
                                       capture_output=True, check=False)
                    subprocess.run(['docker', 'image', 'rm', '--force', tag], capture_output=True, check=False)
    finally:
        output.write_text(json.dumps({'expectedStore': expected_store, 'observations': observations}, indent=2) + '\n')
    print(json.dumps({'identityRegression': 'passed', 'expectedStore': expected_store,
                      'variants': [item['variant'] for item in observations]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--expected-store', required=True, choices=('classic', 'containerd'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        check(args.commit, args.expected_store, args.output)
    except security.GateError as error:
        print(json.dumps({'identityRegression': 'failed', 'kind': str(error)}))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
