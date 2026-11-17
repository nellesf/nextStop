#!/usr/bin/env python3
"""Pinned Trivy OS/library gate; reports bind the scanned Docker config to its digest."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = '0.75.0'
ARCHIVE_SHA256 = 'c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f'
URL = f'https://github.com/aquasecurity/trivy/releases/download/v{VERSION}/trivy_{VERSION}_Linux-64bit.tar.gz'
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
PROFILES = ('backend', 'postgres-client', 'ci-postgis')
SEVERITIES = ('UNKNOWN', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
POSTGRES_CLIENT_BASE = 'sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4'
MANIFEST_TYPES = ('application/vnd.oci.image.manifest.v1+json',
                  'application/vnd.docker.distribution.manifest.v2+json')
INDEX_TYPES = ('application/vnd.oci.image.index.v1+json',
               'application/vnd.docker.distribution.manifest.list.v2+json')
CONFIG_TYPES = ('application/vnd.oci.image.config.v1+json',
                'application/vnd.docker.container.image.v1+json')
ATTESTATION_TYPE = 'application/vnd.docker.attestation.manifest.v1+json'
EMPTY_CONFIG_TYPE = 'application/vnd.oci.empty.v1+json'
REFERRER_SUBJECT = 'io.containerd.manifest.subject'
MAX_METADATA_BYTES = 2 * 1024 * 1024


class GateError(Exception):
    pass


def command(args, *, cwd=None, env=None, timeout=1200):
    try:
        value = subprocess.run(args, cwd=cwd, env=env, timeout=timeout,
                               text=True, capture_output=True, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError('security_tool_unavailable_or_timeout') from error
    if value.returncode:
        raise GateError('security_tool_failed_exit_' + str(value.returncode))
    return value.stdout


def install(directory: Path) -> Path:
    # A reviewed release archive checksum, never a mutable install script/action.
    with urllib.request.urlopen(URL, timeout=60) as response:
        archive = response.read(150 * 1024 * 1024 + 1)
    if hashlib.sha256(archive).hexdigest() != ARCHIVE_SHA256:
        raise GateError('scanner_download_checksum_mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as bundle:
        member = bundle.getmember('trivy')
        if not member.isfile() or member.size > 400 * 1024 * 1024:
            raise GateError('scanner_archive_invalid')
        executable = directory / 'trivy'
        executable.write_bytes(bundle.extractfile(member).read())
        executable.chmod(0o700)
    return executable


def client_configuration(config):
    labels = config.get('Labels') or {}
    if (config.get('User') != '65532:65532' or config.get('Entrypoint')
            or config.get('Cmd') != ['psql', '--version'] or config.get('Volumes')
            or config.get('ExposedPorts') or config.get('WorkingDir') != '/tmp'
            or labels.get('tech.nextstop.image-purpose') != 'postgres-client'
            or labels.get('org.opencontainers.image.base.digest') != POSTGRES_CLIENT_BASE
            or labels.get('org.opencontainers.image.version') != '17.11'):
        raise GateError('postgres_client_configuration_invalid')


def descriptor_identity(value, media_types):
    if (not isinstance(value, dict) or value.get('mediaType') not in media_types
            or not isinstance(value.get('digest'), str) or not DIGEST.fullmatch(value['digest'])
            or type(value.get('size')) is not int or not 0 <= value['size'] <= MAX_METADATA_BYTES):
        raise GateError('image_descriptor_invalid')
    return {key: value[key] for key in ('mediaType', 'digest', 'size')}


def archive_descriptors(read, config_data, docker_manifest):
    """Prove OCI manifest/index digests refer to the exact config Trivy scans."""
    if json.loads(read('oci-layout')).get('imageLayoutVersion') != '1.0.0':
        raise GateError('image_layout_invalid')
    config_id = 'sha256:' + hashlib.sha256(config_data).hexdigest()

    def payload(descriptor):
        data = read('blobs/sha256/' + descriptor['digest'].split(':')[1])
        if (len(data) != descriptor['size']
                or 'sha256:' + hashlib.sha256(data).hexdigest() != descriptor['digest']):
            raise GateError('image_descriptor_content_mismatch')
        return data

    def document(descriptor):
        value = json.loads(payload(descriptor))
        if (not isinstance(value, dict) or value.get('schemaVersion') != 2
                or value.get('mediaType') != descriptor['mediaType']):
            raise GateError('image_descriptor_media_type_mismatch')
        return value

    def verify_referrer(item, chosen):
        # Containerd exports an OCI attestation beside a directly pulled child
        # manifest. The index annotation alone must never hide another image.
        descriptor = descriptor_identity(item, (MANIFEST_TYPES[0],))
        subject = descriptor_identity(chosen, MANIFEST_TYPES)
        value = document(descriptor)
        if (item['annotations'][REFERRER_SUBJECT] != subject['digest']
                or item.get('platform') not in (None, {'os': 'unknown', 'architecture': 'unknown'})
                or value.get('artifactType') != ATTESTATION_TYPE
                or descriptor_identity(value.get('subject'), MANIFEST_TYPES) != subject):
            raise GateError('image_referrer_subject_invalid')
        empty_config = descriptor_identity(value.get('config'), (EMPTY_CONFIG_TYPE,))
        if payload(empty_config) != b'{}':
            raise GateError('image_referrer_config_invalid')
        layers = value.get('layers')
        if not isinstance(layers, list) or not 1 <= len(layers) <= 32:
            raise GateError('image_referrer_layers_invalid')
        for layer in layers:
            descriptor_identity(layer, ('application/vnd.in-toto+json',))

    def select(index):
        if (not isinstance(index, dict) or index.get('schemaVersion') != 2
                or index.get('mediaType') not in INDEX_TYPES
                or not isinstance(index.get('manifests'), list)
                or not 1 <= len(index['manifests']) <= 32):
            raise GateError('image_index_invalid')
        # BuildKit provenance is metadata, not another runnable image. It must
        # explicitly identify itself and refer to the selected image manifest.
        images, attestations, referrers = [], [], []
        for item in index['manifests']:
            descriptor_identity(item, MANIFEST_TYPES + INDEX_TYPES)
            annotations = item.get('annotations', {})
            if not isinstance(annotations, dict):
                raise GateError('image_descriptor_annotations_invalid')
            if REFERRER_SUBJECT in annotations:
                referrers.append(item)
            elif annotations.get('vnd.docker.reference.type') == 'attestation-manifest':
                if item.get('platform') != {'architecture': 'unknown', 'os': 'unknown'}:
                    raise GateError('image_attestation_invalid')
                attestations.append(item)
            else:
                images.append(item)
        # Only one runnable image is supported, as in Docker's manifest.json.
        if len(images) != 1:
            raise GateError('one_image_required')
        chosen = images[0]
        for item in attestations:
            if item['annotations'].get('vnd.docker.reference.digest') != chosen['digest']:
                raise GateError('image_attestation_invalid')
        for item in referrers:
            verify_referrer(item, chosen)
        return chosen

    def visit(value, depth=0):
        if depth > 4:
            raise GateError('image_index_depth_exceeded')
        descriptor = descriptor_identity(value, MANIFEST_TYPES + INDEX_TYPES)
        platform = value.get('platform')
        if platform is not None and (platform.get('os') != 'linux' or platform.get('architecture') != 'amd64'
                                     or platform.get('variant') not in (None, '', 'v1')):
            raise GateError('image_platform_or_revision_mismatch')
        manifest = document(descriptor)
        if descriptor['mediaType'] in INDEX_TYPES:
            return [descriptor] + visit(select(manifest), depth + 1)
        config_descriptor = descriptor_identity(manifest.get('config'), CONFIG_TYPES)
        if config_descriptor['digest'] != config_id or config_descriptor['size'] != len(config_data):
            raise GateError('image_manifest_config_mismatch')
        # Docker/Trivy read manifest.json. Bind its ordered layer paths to the
        # hashed OCI manifest too, not merely its config field.
        layers = manifest.get('layers')
        if not isinstance(layers, list):
            raise GateError('image_manifest_layers_invalid')
        paths = []
        for layer in layers:
            digest = layer.get('digest', '')
            if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
                raise GateError('image_manifest_layers_invalid')
            paths.append('blobs/sha256/' + digest.split(':')[1])
        if docker_manifest.get('Layers') != paths:
            raise GateError('image_manifest_layers_mismatch')
        return [descriptor]

    return visit(select(json.loads(read('index.json'))))


def archive_identities(archive: Path, commit: str, profile='backend'):
    if not COMMIT.fullmatch(commit):
        raise GateError('commit_invalid')
    if profile not in PROFILES:
        raise GateError('inventory_profile_invalid')
    with tarfile.open(archive, mode='r:*') as bundle:
        members = {}
        for member in bundle.getmembers():
            if member.name in members:
                raise GateError('duplicate_image_archive_entry')
            members[member.name] = member

        def read(name):
            member = members[name]
            if not member.isfile() or not 0 <= member.size <= MAX_METADATA_BYTES:
                raise GateError('image_metadata_invalid')
            return bundle.extractfile(member).read()
        manifest = json.loads(read('manifest.json'))
        if not isinstance(manifest, list) or len(manifest) != 1:
            raise GateError('one_image_required')
        data = read(manifest[0]['Config'])
        config = json.loads(data)
        descriptors = archive_descriptors(read, data, manifest[0]) if 'index.json' in members else []
    if (config.get('architecture') != 'amd64' or config.get('os') != 'linux'
            or config.get('config', {}).get('Labels', {}).get('org.opencontainers.image.revision') != commit):
        raise GateError('image_platform_or_revision_mismatch')
    if profile == 'postgres-client':
        client_configuration(config.get('config', {}))
    if profile == 'ci-postgis':
        settings = config['config']
        if settings.get('User') != 'postgres' or (settings.get('Labels') or {}).get('tech.nextstop.image-purpose') != 'ci-postgis':
            raise GateError('ci_database_configuration_invalid')
    return 'sha256:' + hashlib.sha256(data).hexdigest(), descriptors


def archive_identity(archive: Path, commit: str, profile='backend'):
    return archive_identities(archive, commit, profile)[0]


def verify_inspection(inspection, image_id, descriptors, commit, profile='backend', image=None):
    if (not isinstance(image_id, str) or not DIGEST.fullmatch(image_id)
            or not isinstance(commit, str) or not COMMIT.fullmatch(commit)
            or not isinstance(descriptors, list)
            or not isinstance(inspection, list) or len(inspection) != 1
            or not isinstance(inspection[0], dict)):
        raise GateError('docker_image_identity_invalid')
    descriptors = [descriptor_identity(value, MANIFEST_TYPES + INDEX_TYPES) for value in descriptors]
    actual = inspection[0]
    docker_id = actual.get('Id')
    if not isinstance(docker_id, str) or not DIGEST.fullmatch(docker_id):
        raise GateError('docker_image_identity_invalid')
    descriptor = actual.get('Descriptor')
    if descriptor is not None:
        descriptor = descriptor_identity(descriptor, MANIFEST_TYPES + INDEX_TYPES)
        if descriptor not in descriptors:
            raise GateError('exported_image_mismatch')
    if docker_id != image_id and (descriptor is None or descriptor['digest'] != docker_id):
        raise GateError('exported_image_mismatch')
    if (actual.get('Os') != 'linux' or actual.get('Architecture') != 'amd64'
            or actual.get('Config', {}).get('Labels', {}).get('org.opencontainers.image.revision') != commit):
        raise GateError('image_platform_or_revision_mismatch')
    if profile not in PROFILES:
        raise GateError('inventory_profile_invalid')
    if profile == 'postgres-client':
        client_configuration(actual.get('Config', {}))
    if image is not None:
        if '@' not in image or not DIGEST.fullmatch(image.rsplit('@', 1)[1]):
            raise GateError('immutable_image_required')
        if not isinstance(actual.get('RepoDigests'), list) or image not in actual['RepoDigests']:
            raise GateError('scanned_image_digest_binding_mismatch')
        if descriptor is not None and image.rsplit('@', 1)[1] != descriptor['digest']:
            raise GateError('scanned_image_digest_binding_mismatch')
    return docker_id


def evaluate(report, image_id, profile='backend'):
    if profile not in PROFILES:
        raise GateError('inventory_profile_invalid')
    if (report.get('SchemaVersion') != 2 or report.get('Trivy', {}).get('Version') != VERSION
            or report.get('Metadata', {}).get('ImageID') != image_id
            or report.get('Metadata', {}).get('OS', {}).get('EOSL') is True):
        raise GateError('scan_identity_version_or_supported_os_invalid')
    results = report.get('Results', [])
    if not any(r.get('Class') == 'os-pkgs' and r.get('Packages') for r in results):
        raise GateError('os_inventory_missing')
    if profile == 'backend' and not any(r.get('Class') == 'lang-pkgs' and r.get('Type') in ('npm', 'node-pkg') and r.get('Packages') for r in results):
        raise GateError('npm_inventory_missing')
    if profile == 'postgres-client' and report.get('Metadata', {}).get('OS', {}).get('Family') != 'alpine':
        raise GateError('postgres_client_os_invalid')
    if profile == 'ci-postgis' and report.get('Metadata', {}).get('OS', {}).get('Family') != 'alpine':
        raise GateError('ci_database_os_invalid')
    counts = {s: 0 for s in SEVERITIES}
    blockers = []
    for result in results:
        if result.get('ExperimentalModifiedFindings'):
            raise GateError('unexpected_suppression')
        for finding in result.get('Vulnerabilities') or []:
            severity = finding.get('Severity')
            if severity not in counts:
                raise GateError('unknown_severity_format')
            counts[severity] += 1
            if profile == 'ci-postgis' or severity in ('HIGH', 'CRITICAL'):
                blockers.append({k: finding.get(k) for k in
                                 ('VulnerabilityID', 'PkgName', 'InstalledVersion', 'FixedVersion', 'Severity', 'Status')})
    return counts, blockers


def scan(archive: Path, commit: str, output: Path, profile='backend', *, inspection=None, image=None):
    if image is not None and inspection is None:
        raise GateError('docker_image_identity_required')
    image_id, descriptors = archive_identities(archive, commit, profile)
    # Check the export before scanning/publishing a passing receipt. Docker's
    # classic store identifies configs; containerd identifies manifests/indexes.
    docker_id = (verify_inspection(inspection, image_id, descriptors, commit, profile, image)
                 if inspection is not None else None)
    with tempfile.TemporaryDirectory(prefix='nextstop-image-security-') as temporary:
        work = Path(temporary)
        binary = install(work)
        # Fresh cache forces current advisory data. No inherited skip/ignore/server
        # flags, repository config, VEX or ignore files may weaken this gate.
        env = {k: v for k, v in os.environ.items() if not k.startswith('TRIVY_')}
        (work / 'empty.yaml').write_text('{}\n')
        (work / 'empty.ignore').write_text('')
        report_path = output.with_suffix('.trivy.json').resolve()
        command([str(binary), 'image', '--input', str(archive.resolve()),
                 '--config', str(work / 'empty.yaml'), '--ignorefile', str(work / 'empty.ignore'),
                 '--cache-dir', str(work / 'cache'), '--scanners', 'vuln', '--pkg-types', 'os,library',
                 '--list-all-pkgs', '--ignore-unfixed=false', '--format', 'json', '--output', str(report_path),
                 '--timeout', '15m', '--disable-telemetry', '--skip-version-check'], cwd=work, env=env)
        report = json.loads(report_path.read_text())
        counts, blockers = evaluate(report, image_id, profile)
        receipt = {'schemaVersion': 1, 'passed': not blockers, 'commit': commit, 'imageId': image_id,
                   'imageDescriptors': descriptors, 'dockerImageId': docker_id,
                   'inventoryProfile': profile,
                   'image': image, 'observedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   'scanner': 'trivy', 'scannerVersion': VERSION, 'scannerArchiveSHA256': ARCHIVE_SHA256,
                   'policy': {'blockSeverities': list(SEVERITIES) if profile == 'ci-postgis' else ['HIGH', 'CRITICAL'], 'includeUnfixed': True,
                              'scanners': ['os', 'library'], 'suppressions': []},
                   'counts': counts, 'blockingFindings': blockers,
                   'reportSHA256': hashlib.sha256(report_path.read_bytes()).hexdigest()}
        output.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, separators=(',', ':')))
        if blockers:
            raise GateError('ci_database_vulnerabilities' if profile == 'ci-postgis' else 'high_or_critical_vulnerabilities')
        return receipt


def bind(output: Path, inspection, image: str):
    receipt = json.loads(output.read_text())
    if receipt.get('passed') is not True:
        raise GateError('scanned_image_digest_binding_mismatch')
    receipt['dockerImageId'] = verify_inspection(
        inspection, receipt.get('imageId'), receipt.get('imageDescriptors', []),
        receipt.get('commit'), receipt.get('inventoryProfile', 'backend'), image)
    receipt['image'] = image
    output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, separators=(',', ':')))
    return receipt


def invalidate_receipt(output: Path, failure: str):
    # A failed identity/binding check must never leave an earlier passing receipt.
    try:
        receipt = json.loads(output.read_text()) if output.exists() else {}
        if not isinstance(receipt, dict):
            receipt = {}
    except (OSError, ValueError):
        receipt = {}
    receipt.update(schemaVersion=1, passed=False, image=None, failure=failure)
    try:
        output.write_text(json.dumps(receipt, indent=2) + '\n')
    except OSError:
        pass  # The process still fails; an unwritable output cannot be repaired.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--image')
    parser.add_argument('--commit')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bind-inspection', type=Path)
    parser.add_argument('--profile', choices=PROFILES, default='backend')
    args = parser.parse_args()
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if args.bind_inspection:
            bind(args.output, json.loads(args.bind_inspection.read_text()), args.image or '')
        elif args.archive and not args.image:
            scan(args.archive, args.commit or '', args.output, args.profile)
        elif args.image and not args.archive:
            inspection = json.loads(command(['docker', 'image', 'inspect', args.image]))
            if (not isinstance(inspection, list) or len(inspection) != 1
                    or not isinstance(inspection[0], dict)
                    or not DIGEST.fullmatch(inspection[0].get('Id', ''))):
                raise GateError('docker_image_identity_invalid')
            with tempfile.TemporaryDirectory(prefix='nextstop-image-export-') as temporary:
                archive = Path(temporary) / 'image.tar'
                command(['docker', 'image', 'save', '--output', str(archive), inspection[0]['Id']])
                scan(archive, args.commit or '', args.output, args.profile, inspection=inspection,
                     image=args.image if '@' in args.image else None)
        else:
            raise GateError('exactly_one_image_input_required')
    except GateError as error:
        invalidate_receipt(args.output, str(error))
        print(json.dumps({'securityGate': 'failed', 'kind': str(error)}), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, tarfile.TarError):
        invalidate_receipt(args.output, 'invalid_input_or_tool_response')
        print('{"securityGate":"failed","kind":"invalid_input_or_tool_response"}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
