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


def archive_identity(archive: Path, commit: str):
    if not COMMIT.fullmatch(commit):
        raise GateError('commit_invalid')
    with tarfile.open(archive, mode='r:*') as bundle:
        def read(name):
            member = bundle.getmember(name)
            if not member.isfile() or member.size > 2 * 1024 * 1024:
                raise GateError('image_metadata_invalid')
            return bundle.extractfile(member).read()
        manifest = json.loads(read('manifest.json'))
        if not isinstance(manifest, list) or len(manifest) != 1:
            raise GateError('one_image_required')
        data = read(manifest[0]['Config'])
        config = json.loads(data)
    if (config.get('architecture') != 'amd64' or config.get('os') != 'linux'
            or config.get('config', {}).get('Labels', {}).get('org.opencontainers.image.revision') != commit):
        raise GateError('image_platform_or_revision_mismatch')
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def evaluate(report, image_id):
    if (report.get('SchemaVersion') != 2 or report.get('Trivy', {}).get('Version') != VERSION
            or report.get('Metadata', {}).get('ImageID') != image_id
            or report.get('Metadata', {}).get('OS', {}).get('EOSL') is True):
        raise GateError('scan_identity_version_or_supported_os_invalid')
    results = report.get('Results', [])
    if not any(r.get('Class') == 'os-pkgs' and r.get('Packages') for r in results):
        raise GateError('os_inventory_missing')
    if not any(r.get('Class') == 'lang-pkgs' and r.get('Type') in ('npm', 'node-pkg') and r.get('Packages') for r in results):
        raise GateError('npm_inventory_missing')
    counts = {s: 0 for s in ('UNKNOWN', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL')}
    blockers = []
    for result in results:
        if result.get('ExperimentalModifiedFindings'):
            raise GateError('unexpected_suppression')
        for finding in result.get('Vulnerabilities') or []:
            severity = finding.get('Severity')
            if severity not in counts:
                raise GateError('unknown_severity_format')
            counts[severity] += 1
            if severity in ('HIGH', 'CRITICAL'):
                blockers.append({k: finding.get(k) for k in
                                 ('VulnerabilityID', 'PkgName', 'InstalledVersion', 'FixedVersion', 'Severity', 'Status')})
    return counts, blockers


def scan(archive: Path, commit: str, output: Path):
    image_id = archive_identity(archive, commit)
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
        counts, blockers = evaluate(report, image_id)
        receipt = {'schemaVersion': 1, 'passed': not blockers, 'commit': commit, 'imageId': image_id,
                   'image': None, 'observedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   'scanner': 'trivy', 'scannerVersion': VERSION, 'scannerArchiveSHA256': ARCHIVE_SHA256,
                   'policy': {'blockSeverities': ['HIGH', 'CRITICAL'], 'includeUnfixed': True,
                              'scanners': ['os', 'library'], 'suppressions': []},
                   'counts': counts, 'blockingFindings': blockers,
                   'reportSHA256': hashlib.sha256(report_path.read_bytes()).hexdigest()}
        output.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, separators=(',', ':')))
        if blockers:
            raise GateError('high_or_critical_vulnerabilities')
        return receipt


def bind(output: Path, inspection, image: str):
    receipt = json.loads(output.read_text())
    if (not isinstance(inspection, list) or len(inspection) != 1 or '@' not in image
            or not DIGEST.fullmatch(image.rsplit('@', 1)[1])):
        raise GateError('immutable_image_required')
    actual = inspection[0]
    if (receipt.get('passed') is not True or actual.get('Id') != receipt.get('imageId')
            or image not in actual.get('RepoDigests', [])
            or actual.get('Config', {}).get('Labels', {}).get('org.opencontainers.image.revision') != receipt.get('commit')):
        raise GateError('scanned_image_digest_binding_mismatch')
    receipt['image'] = image
    output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, separators=(',', ':')))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--image')
    parser.add_argument('--commit')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bind-inspection', type=Path)
    args = parser.parse_args()
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if args.bind_inspection:
            bind(args.output, json.loads(args.bind_inspection.read_text()), args.image or '')
        elif args.archive and not args.image:
            scan(args.archive, args.commit or '', args.output)
        elif args.image and not args.archive:
            inspection = json.loads(command(['docker', 'image', 'inspect', args.image]))
            if len(inspection) != 1 or not DIGEST.fullmatch(inspection[0].get('Id', '')):
                raise GateError('docker_image_identity_invalid')
            with tempfile.TemporaryDirectory(prefix='nextstop-image-export-') as temporary:
                archive = Path(temporary) / 'image.tar'
                command(['docker', 'image', 'save', '--output', str(archive), inspection[0]['Id']])
                receipt = scan(archive, args.commit or '', args.output)
                if receipt['imageId'] != inspection[0]['Id']:
                    raise GateError('exported_image_mismatch')
                if '@' in args.image:
                    bind(args.output, inspection, args.image)
        else:
            raise GateError('exactly_one_image_input_required')
    except GateError as error:
        print(json.dumps({'securityGate': 'failed', 'kind': str(error)}), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, tarfile.TarError):
        print('{"securityGate":"failed","kind":"invalid_input_or_tool_response"}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
