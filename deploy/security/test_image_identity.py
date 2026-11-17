"""Regression coverage for classic Docker and containerd export identities."""
import copy
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('identity_security', Path(__file__).with_name('scan-image.py'))
s = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(s)
COMMIT = 'a' * 40
OTHER = 'sha256:' + 'f' * 64
PLATFORM = {'os': 'linux', 'architecture': 'amd64'}
MANIFEST = 'application/vnd.oci.image.manifest.v1+json'
INDEX = 'application/vnd.oci.image.index.v1+json'
CONFIG = 'application/vnd.oci.image.config.v1+json'


def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode()


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def blob_path(value):
    return 'blobs/sha256/' + value.split(':')[1]


class Export:
    """Small docker-save archive, with actual byte hashes at every OCI link."""

    def __init__(self, kind='index', *, architecture='amd64', commit=COMMIT, docker_media=False):
        self.kind = kind
        self.manifest_type = s.MANIFEST_TYPES[1] if docker_media else MANIFEST
        self.index_type = s.INDEX_TYPES[1] if docker_media else INDEX
        self.config_type = s.CONFIG_TYPES[1] if docker_media else CONFIG
        self.layer = io.BytesIO()
        with tarfile.open(fileobj=self.layer, mode='w') as bundle:
            info = tarfile.TarInfo('hello.txt')
            info.size = 5
            bundle.addfile(info, io.BytesIO(b'hello'))
        layer_bytes = self.layer.getvalue()
        self.layer = gzip.compress(layer_bytes, mtime=0)
        self.config = encoded({
            'architecture': architecture, 'os': 'linux',
            'config': {'Labels': {'org.opencontainers.image.revision': commit}, 'User': 'node'},
            'rootfs': {'type': 'layers', 'diff_ids': [digest(layer_bytes)]},
            'history': [{'created_by': 'COPY hello.txt /hello.txt'}],
        })
        self.config_id = digest(self.config)
        self.runtime = {
            'schemaVersion': 2, 'mediaType': self.manifest_type,
            'config': self.descriptor(self.config_type, self.config),
            'layers': [self.descriptor('application/vnd.oci.image.layer.v1.tar+gzip', self.layer)],
        }
        self.files = {}
        self.rebuild()

    @staticmethod
    def descriptor(media_type, payload):
        return {'mediaType': media_type, 'digest': digest(payload), 'size': len(payload)}

    def store(self, media_type, value):
        data = encoded(value)
        self.files[blob_path(digest(data))] = data
        return self.descriptor(media_type, data)

    def rebuild(self):
        if self.kind == 'classic':
            self.config_path = self.config_id.split(':')[1] + '.json'
            self.files = {self.config_path: self.config, 'layer/layer.tar': self.layer.getvalue()
                          if isinstance(self.layer, io.BytesIO) else gzip.decompress(self.layer)}
            self.docker_manifest = [{'Config': self.config_path, 'RepoTags': ['fixture:test'],
                                     'Layers': ['layer/layer.tar']}]
            self.files['manifest.json'] = encoded(self.docker_manifest)
            self.descriptors = []
            self.top = None
            return
        self.config_path = blob_path(self.config_id)
        self.files[self.config_path] = self.config
        self.files[blob_path(digest(self.layer))] = self.layer
        self.runtime_descriptor = self.store(self.manifest_type, self.runtime)
        self.top = self.runtime_descriptor
        self.descriptors = [self.runtime_descriptor]
        if self.kind == 'index':
            attestation_config = encoded({'architecture': 'unknown', 'os': 'unknown',
                                          'config': {}, 'rootfs': {'type': 'layers', 'diff_ids': []}})
            self.files[blob_path(digest(attestation_config))] = attestation_config
            attestation = self.store(MANIFEST, {
                'schemaVersion': 2, 'mediaType': MANIFEST,
                'config': self.descriptor(CONFIG, attestation_config), 'layers': [],
            })
            self.attestation_descriptor = {
                **attestation, 'platform': {'architecture': 'unknown', 'os': 'unknown'},
                'annotations': {'vnd.docker.reference.type': 'attestation-manifest',
                                'vnd.docker.reference.digest': self.runtime_descriptor['digest']},
            }
            self.image_index = {'schemaVersion': 2, 'mediaType': self.index_type,
                                'manifests': [{**self.runtime_descriptor, 'platform': PLATFORM},
                                              self.attestation_descriptor]}
            self.top = self.store(self.index_type, self.image_index)
            self.descriptors = [self.top, self.runtime_descriptor]
        self.wrapper = {'schemaVersion': 2, 'mediaType': INDEX,
                        'manifests': [{**self.top, 'annotations': {
                            'io.containerd.image.name': 'fixture:test',
                            'org.opencontainers.image.ref.name': 'test'}}]}
        self.files['index.json'] = encoded(self.wrapper)
        self.files['oci-layout'] = encoded({'imageLayoutVersion': '1.0.0'})
        self.docker_manifest = [{'Config': self.config_path, 'RepoTags': ['fixture:test'],
                                 'Layers': [blob_path(digest(self.layer))]}]
        self.files['manifest.json'] = encoded(self.docker_manifest)

    def replace_index(self, document):
        self.top = self.store(self.index_type, document)
        self.wrapper['manifests'] = [self.top]
        self.files['index.json'] = encoded(self.wrapper)

    def add_referrer(self, *, legacy=False):
        """Containerd's child export: one runtime manifest plus its OCI artifact."""
        empty = b'{}'
        self.files[blob_path(digest(empty))] = empty
        attestation = encoded({'_type': 'https://in-toto.io/Statement/v1', 'predicate': {},
                               'subject': [{'name': 'fixture', 'digest': {
                                   'sha256': self.runtime_descriptor['digest'].split(':')[1]}}]})
        self.files[blob_path(digest(attestation))] = attestation
        self.referrer = {
            'schemaVersion': 2, 'mediaType': MANIFEST, 'artifactType': s.ATTESTATION_TYPE,
            'config': self.descriptor(s.EMPTY_CONFIG_TYPE, empty),
            'subject': copy.deepcopy(self.runtime_descriptor),
            'layers': [self.descriptor('application/vnd.in-toto+json', attestation)],
        }
        if legacy:
            self.referrer.pop('artifactType')
            self.referrer.pop('subject')
            config = {'architecture': 'unknown', 'os': 'unknown', 'config': {},
                      'rootfs': {'type': 'layers', 'diff_ids': [digest(attestation)]}}
            self.referrer['config'] = self.store(CONFIG, config)
        self.rebuild_referrer()

    def rebuild_referrer(self):
        self.referrer_descriptor = self.store(MANIFEST, self.referrer)
        self.wrapper['manifests'] = [self.top, {**self.referrer_descriptor, 'annotations': {
            s.REFERRER_SUBJECT: self.runtime_descriptor['digest']}}]
        self.files['index.json'] = encoded(self.wrapper)

    def write(self, path, *, duplicate=None, symlink=None):
        with tarfile.open(path, mode='w') as bundle:
            entries = list(self.files.items())
            if duplicate is not None:
                entries.append((duplicate, self.files[duplicate]))
            for name, payload in entries:
                item = tarfile.TarInfo(name)
                if name == symlink:
                    item.type = tarfile.SYMTYPE
                    item.linkname = self.config_path
                    bundle.addfile(item)
                else:
                    item.size = len(payload)
                    bundle.addfile(item, io.BytesIO(payload))

    def inspection(self, *, classic=False):
        value = {'Id': self.config_id, 'Os': 'linux', 'Architecture': 'amd64',
                 'Config': json.loads(self.config)['config'], 'RepoDigests': [self.image()]}
        if self.top is not None and not classic:
            value.update(Id=self.top['digest'], Descriptor=copy.deepcopy(self.top))
        return [value]

    def image(self):
        return 'example.invalid/fixture@' + (self.top['digest'] if self.top else OTHER)


def trivy_report(image_id):
    return {'SchemaVersion': 2, 'Trivy': {'Version': s.VERSION},
            'Metadata': {'ImageID': image_id, 'OS': {'Family': 'alpine'}},
            'Results': [{'Class': 'os-pkgs', 'Packages': [{'Name': 'musl'}]},
                        {'Class': 'lang-pkgs', 'Type': 'node-pkg', 'Packages': [{'Name': 'fastify'}]}]}


class ImageIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / 'image.tar'
        self.output = self.directory / 'receipt.json'

    def identities(self, export):
        export.write(self.archive)
        return s.archive_identities(self.archive, COMMIT)

    def scan(self, export, *, inspection=None, image=None):
        export.write(self.archive)

        def scanner(args, **_kwargs):
            self.assertIn('--input', args)
            data = trivy_report(export.config_id)
            Path(args[args.index('--output') + 1]).write_text(json.dumps(data))

        with patch.object(s, 'install', return_value=Path('/pinned/trivy')), \
                patch.object(s, 'command', side_effect=scanner), patch('builtins.print'):
            return s.scan(self.archive, COMMIT, self.output, inspection=inspection, image=image)

    def test_classic_manifest_and_attested_index_keep_config_and_daemon_ids_separate(self):
        for kind in ('classic', 'manifest', 'index'):
            for docker_media in (False, True):
                with self.subTest(kind=kind, docker_media=docker_media):
                    export = Export(kind, docker_media=docker_media)
                    config_id, descriptors = self.identities(export)
                    self.assertEqual(config_id, export.config_id)
                    self.assertEqual(descriptors, export.descriptors)
                    actual = export.inspection()
                    self.assertEqual(s.verify_inspection(actual, config_id, descriptors, COMMIT), actual[0]['Id'])
                    receipt = self.scan(export, inspection=actual)
                    self.assertTrue(receipt['passed'])
                    self.assertEqual(receipt['imageId'], config_id)
                    self.assertEqual(receipt['dockerImageId'], actual[0]['Id'])
                    self.assertEqual(receipt['imageDescriptors'], descriptors)

    def test_manifest_and_index_proof_supports_split_archive_scan_then_immutable_binding(self):
        for kind in ('classic', 'manifest', 'index'):
            with self.subTest(kind=kind):
                export = Export(kind)
                receipt = self.scan(export)
                self.assertIsNone(receipt['dockerImageId'])
                self.assertIsNone(receipt['image'])
                with patch('builtins.print'):
                    bound = s.bind(self.output, export.inspection(), export.image())
                self.assertEqual(bound['image'], export.image())
                self.assertEqual(bound['imageId'], export.config_id)
                self.assertEqual(bound['dockerImageId'], export.inspection()[0]['Id'])

    def test_immutable_scan_checks_binding_before_emitting_one_passed_receipt(self):
        export = Export()
        receipt = self.scan(export, inspection=export.inspection(), image=export.image())
        self.assertEqual(receipt['image'], export.image())
        self.assertTrue(receipt['passed'])

    def test_changed_manifest_or_index_bytes_and_descriptor_sizes_are_rejected(self):
        for kind in ('manifest', 'index'):
            for corruption in ('bytes', 'size', 'digest'):
                with self.subTest(kind=kind, corruption=corruption):
                    export = Export(kind)
                    if corruption == 'bytes':
                        export.files[blob_path(export.top['digest'])] += b' '
                    else:
                        descriptor = export.wrapper['manifests'][0]
                        descriptor[corruption] = descriptor['size'] + 1 if corruption == 'size' else OTHER
                        export.files['index.json'] = encoded(export.wrapper)
                    export.write(self.archive)
                    with self.assertRaises((s.GateError, KeyError)):
                        s.archive_identities(self.archive, COMMIT)

    def test_hashed_manifest_cannot_reference_another_config_or_docker_layer_list(self):
        for corruption in ('config-digest', 'config-size', 'layers'):
            with self.subTest(corruption=corruption):
                export = Export()
                if corruption == 'config-digest':
                    export.runtime['config']['digest'] = OTHER
                elif corruption == 'config-size':
                    export.runtime['config']['size'] += 1
                else:
                    export.runtime['layers'][0]['digest'] = OTHER
                export.rebuild()
                with self.assertRaises(s.GateError):
                    self.identities(export)

    def test_docker_config_and_platform_must_match_expected_source(self):
        for kind in ('classic', 'manifest', 'index'):
            for fields in ({'architecture': 'arm64'}, {'commit': 'b' * 40}):
                with self.subTest(kind=kind, fields=fields), self.assertRaises(s.GateError):
                    self.identities(Export(kind, **fields))
        export = Export()
        document = copy.deepcopy(export.image_index)
        document['manifests'][0]['platform'] = {'os': 'linux', 'architecture': 'arm64'}
        export.replace_index(document)
        with self.assertRaises(s.GateError):
            self.identities(export)

    def test_ambiguous_and_unrelated_top_level_images_are_rejected(self):
        export = Export()
        export.wrapper['manifests'].append(copy.deepcopy(export.wrapper['manifests'][0]))
        export.files['index.json'] = encoded(export.wrapper)
        with self.assertRaises(s.GateError):
            self.identities(export)
        export = Export()
        document = copy.deepcopy(export.image_index)
        document['manifests'].append(copy.deepcopy(document['manifests'][0]))
        export.replace_index(document)
        with self.assertRaises(s.GateError):
            self.identities(export)

    def test_attestations_never_count_as_runtime_images_and_must_reference_selected_manifest(self):
        for corruption in ('reference', 'platform', 'type'):
            with self.subTest(corruption=corruption):
                export = Export()
                document = copy.deepcopy(export.image_index)
                attestation = document['manifests'][1]
                if corruption == 'reference':
                    attestation['annotations']['vnd.docker.reference.digest'] = OTHER
                elif corruption == 'platform':
                    attestation['platform'] = PLATFORM
                else:
                    del attestation['annotations']['vnd.docker.reference.type']
                export.replace_index(document)
                with self.assertRaises(s.GateError):
                    self.identities(export)

    def test_canonical_manifest_with_verified_oci_referrer_keeps_one_scanned_runtime(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                export = Export('manifest')
                export.add_referrer(legacy=legacy)
                config_id, descriptors = self.identities(export)
                self.assertEqual(config_id, export.config_id)
                self.assertEqual(descriptors, [export.runtime_descriptor])
                receipt = self.scan(export, inspection=export.inspection(), image=export.image())
                self.assertTrue(receipt['passed'])
                self.assertEqual(receipt['imageDescriptors'], [export.runtime_descriptor])
                self.assertEqual(receipt['imageId'], export.config_id)
                wrong = export.inspection()
                wrong[0].update(Id=export.referrer_descriptor['digest'], Descriptor=export.referrer_descriptor)
                with self.assertRaises(s.GateError):
                    s.verify_inspection(wrong, config_id, descriptors, COMMIT)

    def test_legacy_referrer_requires_exact_nonruntime_config_and_hashed_statement_subject(self):
        cases = ('architecture', 'os', 'command', 'diff-id', 'config-bytes', 'layer-bytes',
                 'layer-size', 'layer-type', 'subject', 'missing-subject', 'statement-type',
                 'mixed-artifact', 'mixed-subject')
        for corruption in cases:
            with self.subTest(corruption=corruption):
                export = Export('manifest')
                export.add_referrer(legacy=True)
                config_descriptor = export.referrer['config']
                config = json.loads(export.files[blob_path(config_descriptor['digest'])])
                layer_descriptor = export.referrer['layers'][0]
                statement = json.loads(export.files[blob_path(layer_descriptor['digest'])])
                if corruption == 'architecture': config['architecture'] = 'amd64'
                if corruption == 'os': config['os'] = 'linux'
                if corruption == 'command': config['config'] = {'Cmd': ['/runnable']}
                if corruption == 'diff-id': config['rootfs']['diff_ids'] = [OTHER]
                if corruption == 'subject': statement['subject'][0]['digest']['sha256'] = OTHER.split(':')[1]
                if corruption == 'missing-subject': statement.pop('subject')
                if corruption == 'statement-type': statement['_type'] = 'not-in-toto'
                if corruption in ('subject', 'missing-subject', 'statement-type'):
                    layer_descriptor = export.store('application/vnd.in-toto+json', statement)
                    export.referrer['layers'] = [layer_descriptor]
                    config['rootfs']['diff_ids'] = [layer_descriptor['digest']]
                export.referrer['config'] = export.store(CONFIG, config)
                if corruption == 'layer-size': layer_descriptor['size'] += 1
                if corruption == 'layer-type': layer_descriptor['mediaType'] = 'application/vnd.oci.image.layer.v1.tar'
                if corruption == 'mixed-artifact': export.referrer['artifactType'] = s.ATTESTATION_TYPE
                if corruption == 'mixed-subject': export.referrer['subject'] = export.runtime_descriptor
                export.rebuild_referrer()
                if corruption == 'config-bytes': export.files[blob_path(export.referrer['config']['digest'])] += b' '
                if corruption == 'layer-bytes': export.files[blob_path(layer_descriptor['digest'])] += b' '
                with self.assertRaises(s.GateError):
                    self.identities(export)

    def test_referrer_annotation_cannot_hide_unrelated_runnable_or_modified_content(self):
        cases = ('annotation', 'missing-annotation', 'subject-digest', 'subject-size', 'subject-type',
                 'artifact-type', 'platform', 'manifest-bytes', 'manifest-size', 'config-bytes',
                 'config-size', 'config-type', 'runnable-config', 'runtime-layer', 'extra-runtime')
        for corruption in cases:
            with self.subTest(corruption=corruption):
                export = Export('manifest')
                export.add_referrer()
                if corruption == 'subject-digest': export.referrer['subject']['digest'] = OTHER
                if corruption == 'subject-size': export.referrer['subject']['size'] += 1
                if corruption == 'subject-type': export.referrer['subject']['mediaType'] = INDEX
                if corruption == 'artifact-type': export.referrer['artifactType'] = 'application/example'
                if corruption == 'config-size': export.referrer['config']['size'] += 1
                if corruption == 'config-type': export.referrer['config']['mediaType'] = CONFIG
                if corruption == 'runnable-config':
                    export.referrer['config'] = export.descriptor(s.EMPTY_CONFIG_TYPE, export.config)
                if corruption == 'runtime-layer': export.referrer['layers'][0]['mediaType'] = 'application/vnd.oci.image.layer.v1.tar'
                export.rebuild_referrer()
                descriptor = export.wrapper['manifests'][1]
                if corruption == 'annotation': descriptor['annotations'][s.REFERRER_SUBJECT] = OTHER
                if corruption == 'missing-annotation': descriptor.pop('annotations')
                if corruption == 'platform': descriptor['platform'] = PLATFORM
                if corruption == 'manifest-size': descriptor['size'] += 1
                if corruption == 'manifest-bytes':
                    export.files[blob_path(descriptor['digest'])] += b' '
                if corruption == 'config-bytes':
                    export.files[blob_path(export.referrer['config']['digest'])] = b'[]'
                if corruption == 'extra-runtime':
                    export.wrapper['manifests'].append(copy.deepcopy(export.runtime_descriptor))
                export.files['index.json'] = encoded(export.wrapper)
                with self.assertRaises(s.GateError):
                    self.identities(export)

    def test_runtime_manifest_with_forged_referrer_annotation_is_rejected(self):
        export = Export('manifest')
        export.wrapper['manifests'].append({**export.runtime_descriptor, 'annotations': {
            s.REFERRER_SUBJECT: export.runtime_descriptor['digest']}})
        export.files['index.json'] = encoded(export.wrapper)
        with self.assertRaises(s.GateError):
            self.identities(export)

    def test_duplicate_or_symlinked_metadata_is_rejected(self):
        for name in ('manifest.json', 'index.json'):
            for kind in ('duplicate', 'symlink'):
                with self.subTest(name=name, kind=kind):
                    export = Export()
                    export.write(self.archive, **{kind: name})
                    with self.assertRaises(s.GateError):
                        s.archive_identities(self.archive, COMMIT)

    def test_descriptor_media_type_shape_and_size_must_be_valid(self):
        for field, value in (('mediaType', 'application/json'), ('digest', 'sha512:abc'),
                             ('digest', None), ('size', -1), ('size', True),
                             ('size', s.MAX_METADATA_BYTES + 1)):
            with self.subTest(field=field, value=value):
                export = Export('manifest')
                export.wrapper['manifests'][0][field] = value
                export.files['index.json'] = encoded(export.wrapper)
                with self.assertRaises(s.GateError):
                    self.identities(export)

    def test_same_revision_does_not_admit_wrong_daemon_image_or_descriptor(self):
        export = Export()
        config_id, descriptors = self.identities(export)
        for corruption in ('id', 'no-descriptor', 'descriptor-digest', 'descriptor-size',
                           'descriptor-type', 'platform', 'revision', 'repo-list', 'repo-shape'):
            with self.subTest(corruption=corruption):
                actual = export.inspection()
                if corruption == 'id': actual[0]['Id'] = OTHER
                if corruption == 'no-descriptor': del actual[0]['Descriptor']
                if corruption == 'descriptor-digest': actual[0]['Descriptor']['digest'] = OTHER
                if corruption == 'descriptor-size': actual[0]['Descriptor']['size'] += 1
                if corruption == 'descriptor-type': actual[0]['Descriptor']['mediaType'] = MANIFEST
                if corruption == 'platform': actual[0]['Architecture'] = 'arm64'
                if corruption == 'revision': actual[0]['Config']['Labels']['org.opencontainers.image.revision'] = 'b' * 40
                if corruption == 'repo-list': actual[0]['RepoDigests'] = []
                if corruption == 'repo-shape': actual[0]['RepoDigests'] = export.image()
                with self.assertRaises(s.GateError):
                    s.verify_inspection(actual, config_id, descriptors, COMMIT, image=export.image())

    def test_unrelated_registry_digest_cannot_be_bound_even_when_listed_by_inspect(self):
        export = Export()
        config_id, descriptors = self.identities(export)
        image = 'example.invalid/fixture@' + OTHER
        actual = export.inspection()
        actual[0]['RepoDigests'].append(image)
        with self.assertRaises(s.GateError):
            s.verify_inspection(actual, config_id, descriptors, COMMIT, image=image)

    def test_wrong_export_is_rejected_before_downloading_or_executing_scanner(self):
        export = Export()
        export.write(self.archive)
        actual = export.inspection()
        actual[0]['Id'] = OTHER
        with patch.object(s, 'install') as install, patch.object(s, 'command') as command:
            with self.assertRaises(s.GateError):
                s.scan(self.archive, COMMIT, self.output, inspection=actual)
        install.assert_not_called()
        command.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_cli_export_mismatch_invalidates_previous_success_and_never_prints_success(self):
        export = Export()
        self.output.write_text(json.dumps({'passed': True, 'image': export.image()}))
        actual = export.inspection()
        actual[0]['Id'] = OTHER

        def docker(args, **_kwargs):
            if args[:3] == ['docker', 'image', 'inspect']:
                return json.dumps(actual)
            self.assertEqual(args[:3], ['docker', 'image', 'save'])
            export.write(Path(args[args.index('--output') + 1]))
            return ''

        with patch.object(s.sys, 'argv', ['scan-image.py', '--image', 'fixture:test', '--commit', COMMIT,
                                          '--output', str(self.output)]), \
                patch.object(s, 'command', side_effect=docker), patch.object(s, 'install') as install, \
                patch('builtins.print') as output:
            self.assertEqual(s.main(), 1)
        install.assert_not_called()
        self.assertFalse(json.loads(self.output.read_text())['passed'])
        self.assertIsNone(json.loads(self.output.read_text())['image'])
        self.assertNotIn('"passed":true', str(output.call_args_list))

    def test_cli_bind_failure_invalidates_existing_passing_receipt(self):
        export = Export()
        self.scan(export)
        actual = export.inspection()
        actual[0]['RepoDigests'] = []
        inspection_path = self.directory / 'inspection.json'
        inspection_path.write_text(json.dumps(actual))
        with patch.object(s.sys, 'argv', ['scan-image.py', '--bind-inspection', str(inspection_path),
                                          '--image', export.image(), '--output', str(self.output)]), \
                patch('builtins.print'):
            self.assertEqual(s.main(), 1)
        receipt = json.loads(self.output.read_text())
        self.assertFalse(receipt['passed'])
        self.assertIsNone(receipt['image'])

    def test_cli_malformed_metadata_fails_closed_with_an_explicit_failed_receipt(self):
        for name, malformed in (('manifest.json', b'{}'), ('index.json', b'null'),
                                ('oci-layout', b'[]'), ('manifest.json', b'not json')):
            with self.subTest(name=name, malformed=malformed):
                export = Export()
                export.files[name] = malformed
                export.write(self.archive)
                self.output.write_text(json.dumps({'passed': True}))
                with patch.object(s.sys, 'argv', ['scan-image.py', '--archive', str(self.archive),
                                                  '--commit', COMMIT, '--output', str(self.output)]), \
                        patch.object(s, 'install') as install, patch('builtins.print'):
                    self.assertEqual(s.main(), 1)
                install.assert_not_called()
                self.assertFalse(json.loads(self.output.read_text())['passed'])


if __name__ == '__main__':
    unittest.main()
