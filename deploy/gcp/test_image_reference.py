"""Exercise canonical release selection against hashed registry metadata."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock

from common import ROOT, configuration, verified_platform_image

spec = importlib.util.spec_from_file_location("release_registry", ROOT / "deploy/gcp-run/registry.py")
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)
CONFIG = configuration("staging")
COMMIT = "b" * 40


class ImageReferenceTests(unittest.TestCase):
    def metadata(self, *, indexed=True, revision=COMMIT, architecture="amd64", matches=1, corrupt=None):
        documents = {}

        def add(resource, value):
            raw = json.dumps(value).encode()
            digest = "sha256:" + hashlib.sha256(raw).hexdigest()
            documents[(resource, digest)] = raw
            return digest, len(raw)

        config_digest, config_size = add("blobs", {
            "os": "linux", "architecture": architecture,
            "config": {"Labels": {"org.opencontainers.image.revision": revision}},
        })
        platform_digest, platform_size = add("manifests", {
            "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                       "digest": config_digest, "size": config_size},
        })
        tagged_digest = platform_digest
        if indexed:
            platform = {"mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "digest": platform_digest, "size": platform_size,
                        "platform": {"os": "linux", "architecture": "amd64"}}
            # BuildKit also emits unknown-platform attestations; they must not
            # become the canonical runnable image or cause a false ambiguity.
            attestation = {**platform, "platform": {"os": "unknown", "architecture": "unknown"}}
            tagged_digest, _ = add("manifests", {
                "schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
                "manifests": [attestation] + [platform] * matches,
            })
        if corrupt:
            target = {"index": ("manifests", tagged_digest), "manifest": ("manifests", platform_digest),
                      "config": ("blobs", config_digest)}[corrupt]
            # Same byte length: require hash validation, not only the size check.
            raw = documents[target]
            documents[target] = (b"[" if raw[:1] == b"{" else b"{") + raw[1:]
        reader = registry.RegistryReader("synthetic-test-only")

        class Response:
            status = 200
            def __init__(self, request):
                self.url = request.full_url
                resource, digest = self.url.rsplit("/", 2)[-2:]
                self.raw = documents[(resource, digest)]
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def geturl(self): return self.url
            def read(self, _): return self.raw

        reader.opener = Mock()
        reader.opener.open.side_effect = lambda request, **_: Response(request)

        def run(arguments):
            self.assertEqual(Path(arguments[1]), ROOT / "deploy/gcp-run/registry.py")
            self.assertEqual(arguments[-4:], ["--commit", COMMIT, "--digest", tagged_digest])
            return registry.verify(reader, tagged_digest, COMMIT)

        return CONFIG["registry"] + "@" + tagged_digest, CONFIG["registry"] + "@" + platform_digest, run

    def test_index_uses_verified_child_and_direct_manifest_is_preserved(self):
        for indexed in (False, True):
            with self.subTest(indexed=indexed):
                tagged, canonical, run = self.metadata(indexed=indexed)
                self.assertEqual(verified_platform_image(COMMIT, tagged, CONFIG, run=run), canonical)
                self.assertEqual(tagged == canonical, not indexed)

    def test_wrong_commit_architecture_or_ambiguous_platform_fails_closed(self):
        for changes in ({"revision": "c" * 40}, {"architecture": "arm64"}, {"matches": 0}, {"matches": 2}):
            with self.subTest(changes=changes):
                tagged, _, run = self.metadata(**changes)
                with self.assertRaises(registry.VerificationError):
                    verified_platform_image(COMMIT, tagged, CONFIG, run=run)

    def test_modified_index_manifest_and_config_bytes_fail_hash_verification(self):
        for corrupt in ("index", "manifest", "config"):
            with self.subTest(corrupt=corrupt):
                tagged, _, run = self.metadata(corrupt=corrupt)
                with self.assertRaisesRegex(registry.VerificationError, "digest verification"):
                    verified_platform_image(COMMIT, tagged, CONFIG, run=run)

    def test_incomplete_wrong_or_unbound_verifier_output_is_rejected(self):
        digest = "sha256:" + "a" * 64
        image = CONFIG["registry"] + "@" + digest
        proof = {"verified": True, "manifestAndConfigHashesVerified": True, "commit": COMMIT,
                 "digest": digest, "platform": "linux/amd64", "platformDigest": digest}
        for changes in ({"verified": False}, {"manifestAndConfigHashesVerified": False},
                        {"commit": "c" * 40}, {"digest": "sha256:" + "d" * 64},
                        {"platform": "linux/arm64"}, {"platformDigest": None},
                        {"platformDigest": "latest"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                verified_platform_image(COMMIT, image, CONFIG, run=lambda _: {**proof, **changes})


if __name__ == "__main__":
    unittest.main()
