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
import tarfile
import tempfile
import time
import urllib.request
import uuid


spec = importlib.util.spec_from_file_location('image_security', Path(__file__).with_name('scan-image.py'))
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)


def cleanup(*arguments):
    try:
        subprocess.run(['docker', *arguments], capture_output=True, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass  # Keep the original failure and still attempt other cleanup.


def check(commit: str, expected_store: str, output: Path):
    if not security.COMMIT.fullmatch(commit):
        raise security.GateError('commit_invalid')
    output.parent.mkdir(parents=True, exist_ok=True)
    observations = []
    registry = 'nextstop-identity-registry-' + uuid.uuid4().hex
    variants = [('manifest', 'false'), ('default', None)] if expected_store == 'classic' else [
        ('manifest', 'false'), ('attested-index', 'mode=min')]
    try:
        security.command(['docker', 'run', '--detach', '--rm', '--name', registry,
                          '--publish', '127.0.0.1::5000', 'registry:3'], timeout=180)
        address = security.command(['docker', 'port', registry, '5000/tcp'], timeout=30).strip()
        host, separator, port = address.partition(':')
        if host != '127.0.0.1' or separator != ':' or not port.isdecimal() or not 0 < int(port) <= 65535:
            raise security.GateError('local_registry_address_invalid')
        for attempt in range(30):
            try:
                with urllib.request.urlopen('http://' + address + '/v2/', timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            time.sleep(0.2)
        else:
            raise security.GateError('local_registry_not_ready')
        for variant, provenance in variants:
            tag = 'nextstop-identity-regression:' + uuid.uuid4().hex
            repository = address + '/nextstop-identity-' + uuid.uuid4().hex
            registry_tag = repository + ':regression'
            immutable = None
            canonical = None
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
                    security.command(['docker', 'tag', tag, registry_tag], timeout=30)
                    security.command(['docker', 'push', registry_tag], timeout=180)
                    pushed = json.loads(security.command(['docker', 'image', 'inspect', registry_tag], timeout=30))
                    references = [ref for ref in pushed[0].get('RepoDigests', [])
                                  if ref.startswith(repository + '@sha256:')]
                    if len(references) != 1:
                        raise security.GateError('local_registry_immutable_reference_missing')
                    immutable = references[0]
                    security.verify_inspection(pushed, config_id, descriptors, commit, image=immutable)
                    security.command(['docker', 'pull', immutable], timeout=180)
                    pulled = json.loads(security.command(['docker', 'image', 'inspect', immutable], timeout=30))
                    security.verify_inspection(pulled, config_id, descriptors, commit, image=immutable)
                    observation['verifiedImmutableRegistryReference'] = immutable

                    # The export has already proved the descriptor chain down
                    # to this config. Exercise the exact runnable manifest that
                    # Cloud Run retains, including an attested index's child.
                    canonical = immutable
                    if expected_store == 'containerd':
                        manifests = [item for item in descriptors if item['mediaType'] in security.MANIFEST_TYPES]
                        if len(manifests) != 1:
                            raise security.GateError('canonical_manifest_not_unique')
                        canonical = repository + '@' + manifests[0]['digest']
                    # A classic store's save metadata can use another manifest
                    # representation from its registry push. Its proven config
                    # identity and direct registry digest remain unchanged.
                    if (canonical != immutable) != (variant == 'attested-index'):
                        raise security.GateError('expected_canonical_reference_not_exercised')
                    if canonical != immutable:
                        security.command(['docker', 'pull', canonical], timeout=180)
                        pulled = json.loads(security.command(['docker', 'image', 'inspect', canonical], timeout=30))
                        # Selecting the child must not weaken the distinction
                        # between its descriptor and the parent index digest.
                        try:
                            security.verify_inspection(pulled, config_id, descriptors, commit, image=immutable)
                        except security.GateError:
                            pass
                        else:
                            raise security.GateError('parent_index_bound_to_child_inspection')
                    canonical_id = security.verify_inspection(pulled, config_id, descriptors, commit, image=canonical)
                    if expected_store == 'containerd' and canonical_id != canonical.rsplit('@', 1)[1]:
                        raise security.GateError('canonical_manifest_identity_mismatch')
                    observation['verifiedCanonicalRegistryReference'] = canonical
                    observation['canonicalDockerImageId'] = canonical_id
                    canonical_archive = work / 'canonical-image.tar'
                    # Save exactly the identity just inspected, as with the
                    # original export, rather than resolving a repository alias.
                    security.command(['docker', 'image', 'save', '--output', str(canonical_archive), canonical_id])
                    try:
                        canonical_config, canonical_descriptors = security.archive_identities(canonical_archive, commit)
                    except (security.GateError, KeyError, ValueError):
                        # Only this disposable, synthetic fixture is exported.
                        # Retain its bounded manifest metadata for diagnosing
                        # daemon alias/layout differences without relaxing the gate.
                        with tarfile.open(canonical_archive, mode='r:*') as bundle:
                            metadata = {}
                            for name in ('manifest.json', 'index.json'):
                                try:
                                    member = bundle.getmember(name)
                                except KeyError:
                                    continue
                                if member.isfile() and member.size <= security.MAX_METADATA_BYTES:
                                    metadata[name] = json.loads(bundle.extractfile(member).read())
                            # Include manifest/config bytes represented as JSON,
                            # never layer contents, for any unrecognized referrer.
                            blobs = {}
                            for descriptor in metadata.get('index.json', {}).get('manifests', []):
                                digest = descriptor.get('digest', '')
                                if not isinstance(digest, str) or not security.DIGEST.fullmatch(digest):
                                    continue
                                name = 'blobs/sha256/' + digest.split(':')[1]
                                try:
                                    member = bundle.getmember(name)
                                    if not member.isfile() or member.size > security.MAX_METADATA_BYTES:
                                        continue
                                    value = json.loads(bundle.extractfile(member).read())
                                    blobs[digest] = value
                                    config_digest = value.get('config', {}).get('digest', '')
                                    if not isinstance(config_digest, str) or not security.DIGEST.fullmatch(config_digest):
                                        continue
                                    member = bundle.getmember('blobs/sha256/' + config_digest.split(':')[1])
                                    if member.isfile() and member.size <= security.MAX_METADATA_BYTES:
                                        blobs[config_digest] = json.loads(bundle.extractfile(member).read())
                                except (KeyError, ValueError):
                                    continue
                            metadata['manifestAndConfigBlobs'] = blobs
                            observation['failedCanonicalExportMetadata'] = metadata
                            observation['originalVerifiedDescriptors'] = descriptors
                        raise
                    if canonical_config != config_id:
                        raise security.GateError('canonical_manifest_config_mismatch')
                    security.verify_inspection(pulled, canonical_config, canonical_descriptors, commit, image=canonical)
                    observation['canonicalExportMatchesOriginalConfig'] = True
                finally:
                    if container:
                        cleanup('container', 'rm', '--force', container)
                    references = list(dict.fromkeys([tag, registry_tag]
                                                    + ([immutable] if immutable else [])
                                                    + ([canonical] if canonical else [])))
                    cleanup('image', 'rm', '--force', *references)
    finally:
        cleanup('container', 'rm', '--force', '--volumes', registry)
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
