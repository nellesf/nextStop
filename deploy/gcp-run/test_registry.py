import hashlib
import json
import unittest
from unittest.mock import patch

import registry


class RegistryTests(unittest.TestCase):
    def fixture(self, revision="b" * 40, architecture="amd64"):
        config = {"os": "linux", "architecture": architecture, "config": {"Labels": {"org.opencontainers.image.revision": revision}}}
        raw = json.dumps(config).encode()
        config_digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(raw)}}

        class Reader:
            def document(self, resource, digest, expected_size=None):
                return manifest if resource == "manifests" else config
        return Reader()

    def test_wrong_source_revision_or_platform_cannot_pass(self):
        for reader in (self.fixture(revision="c" * 40), self.fixture(architecture="arm64")):
            with self.assertRaises(registry.VerificationError):
                registry.verify(reader, "sha256:" + "a" * 64, "b" * 40)
        result = registry.verify(self.fixture(), "sha256:" + "a" * 64, "b" * 40)
        self.assertTrue(result["manifestAndConfigHashesVerified"])

    def test_metadata_byte_digest_is_checked_before_parsing(self):
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def geturl(self): return f"https://{registry.HOST}/v2/{registry.REPOSITORY}/manifests/sha256:" + "a" * 64
            def read(self, _): return b'{"schemaVersion":2}'
        reader = registry.RegistryReader("synthetic-only")
        with patch.object(reader.opener, "open", return_value=Response()), self.assertRaisesRegex(registry.VerificationError, "digest verification"):
            reader.document("manifests", "sha256:" + "a" * 64)

    def test_duplicate_keys_and_redirects_are_rejected(self):
        with self.assertRaises(registry.VerificationError):
            registry.unique_object([("a", 1), ("a", 2)])
        with self.assertRaises(registry.VerificationError):
            registry.NoRedirects().redirect_request(None, None, 302, "redirect", {}, "https://other.example")


if __name__ == "__main__":
    unittest.main()
