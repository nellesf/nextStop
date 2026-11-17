"""Tag/index selection keeps the registry byte proof and scanned config binding."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import platform_image
from test_image_identity import COMMIT, Export, blob_path, s

spec = importlib.util.spec_from_file_location(
    "platform_registry", Path(__file__).resolve().parents[1] / "gcp-run/registry.py")
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)


class PlatformImageTests(unittest.TestCase):
    def resolve(self, export, commit=COMMIT):
        reader = registry.RegistryReader("synthetic-test-token")

        class Response:
            status = 200

            def __init__(self, url, raw):
                self.url, self.raw = url, raw

            def __enter__(self): return self
            def __exit__(self, *_): pass
            def geturl(self): return self.url
            def read(self, _): return self.raw

        def request(request, **_):
            digest = request.full_url.rsplit("/", 1)[1]
            return Response(request.full_url, export.files[blob_path(digest)])

        def run(arguments):
            if arguments[0] == "gcloud":
                self.assertIn(platform_image.REGISTRY + ":" + commit, arguments)
                return {"image_summary": {"digest": export.top["digest"]}}
            self.assertEqual(Path(arguments[1]).name, "registry.py")
            self.assertEqual(arguments[2:], ["--commit", commit, "--digest", export.top["digest"]])
            return registry.verify(reader, export.top["digest"], commit)

        with patch.object(reader.opener, "open", side_effect=request):
            return platform_image.select_image(commit, run=run)

    def test_index_and_direct_manifest_resolve_to_the_same_proven_child(self):
        for docker_media in (False, True):
            with self.subTest(docker_media=docker_media):
                indexed = Export("index", docker_media=docker_media)
                direct = Export("manifest", docker_media=docker_media)
                parent, child = self.resolve(indexed), self.resolve(direct)
                self.assertNotEqual(parent["tagImage"], parent["image"])
                self.assertEqual(parent["image"], child["image"])
                self.assertEqual(child["tagImage"], child["image"])
                self.assertTrue(parent["manifestAndConfigHashesVerified"])

    def test_corrupted_child_or_config_bytes_never_produce_a_release_reference(self):
        for corrupt in ("manifest", "config"):
            export = Export("index")
            digest = export.runtime_descriptor["digest"] if corrupt == "manifest" else export.config_id
            export.files[blob_path(digest)] += b" "
            with self.subTest(corrupt=corrupt), self.assertRaises(registry.VerificationError):
                self.resolve(export)

    def test_wrong_revision_architecture_and_ambiguous_index_are_rejected(self):
        cases = [Export("index", commit="e" * 40), Export("index", architecture="arm64")]
        ambiguous = Export("index")
        document = copy.deepcopy(ambiguous.image_index)
        document["manifests"].append(copy.deepcopy(document["manifests"][0]))
        ambiguous.replace_index(document)
        cases.append(ambiguous)
        for export in cases:
            with self.subTest(kind=export.config_id), self.assertRaises(registry.VerificationError):
                self.resolve(export)

    def test_child_inspection_binds_original_index_scan_but_parent_inspection_cannot(self):
        export = Export("index")
        proof = self.resolve(export)
        with tempfile.TemporaryDirectory() as temporary:
            archive, output = Path(temporary) / "image.tar", Path(temporary) / "receipt.json"
            export.write(archive)
            image_id, descriptors = s.archive_identities(archive, COMMIT)
            output.write_text(json.dumps({"passed": True, "commit": COMMIT,
                "imageId": image_id, "imageDescriptors": descriptors, "image": None}))
            inspection = export.inspection()
            inspection[0]["RepoDigests"] = [proof["tagImage"], proof["image"]]
            with self.assertRaises(s.GateError):
                s.bind(output, inspection, proof["image"])
            inspection[0].update(Id=export.runtime_descriptor["digest"],
                                 Descriptor=copy.deepcopy(export.runtime_descriptor))
            with patch("sys.stdout", new=io.StringIO()):
                receipt = s.bind(output, inspection, proof["image"])
            self.assertEqual(receipt["image"], proof["image"])
            self.assertEqual(receipt["imageId"], export.config_id)

    def test_failed_cli_removes_stale_ref_and_never_prints_private_command_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            reference, proof = Path(temporary) / "image.ref", Path(temporary) / "registry.json"
            reference.write_text("old-release\n")
            proof.write_text("{}")
            arguments = ["platform_image.py", "--commit", COMMIT, "--registry", platform_image.REGISTRY,
                         "--output-ref", str(reference), "--output-proof", str(proof)]
            with patch("sys.argv", arguments), patch("sys.stderr", new=io.StringIO()) as errors, \
                    patch.object(platform_image, "select_image", side_effect=RuntimeError("private-token")):
                self.assertEqual(platform_image.main(), 1)
            self.assertNotIn("private-token", errors.getvalue())
            self.assertFalse(reference.exists())
            self.assertFalse(proof.exists())


if __name__ == "__main__":
    unittest.main()
