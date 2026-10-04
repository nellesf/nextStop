#!/usr/bin/env python3
"""Verify one immutable nextStop backend image without Docker or registry writes."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


HOST = "europe-west3-docker.pkg.dev"
REPOSITORY = "nextstop-tech-staging/nextstop/backend"
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
MANIFEST_TYPES = {
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
}
INDEX_TYPES = {
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
}
CONFIG_TYPES = {
    "application/vnd.docker.container.image.v1+json",
    "application/vnd.oci.image.config.v1+json",
}
MAX_DOCUMENT_BYTES = 2 * 1024 * 1024


class VerificationError(Exception):
    pass


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise VerificationError("Registry redirect rejected")


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key rejected")
        result[key] = value
    return result


def descriptor_digest(descriptor, allowed_types):
    require(isinstance(descriptor, dict), "Invalid metadata descriptor")
    digest = descriptor.get("digest")
    require(isinstance(digest, str) and DIGEST.fullmatch(digest), "Invalid descriptor digest")
    require(descriptor.get("mediaType") in allowed_types, "Unsupported descriptor media type")
    size = descriptor.get("size")
    require(type(size) is int and 0 < size <= MAX_DOCUMENT_BYTES, "Invalid descriptor size")
    return digest, size


def get_token():
    try:
        result = subprocess.run(
            ["gcloud", "auth", "print-access-token", "--quiet"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise VerificationError("Could not obtain local operator credential") from None
    require(result.returncode == 0, "Could not obtain local operator credential")
    require(0 < len(result.stdout) <= 16384, "Invalid credential length")
    try:
        token = result.stdout.decode("ascii").strip()
    except UnicodeDecodeError:
        raise VerificationError("Invalid credential encoding") from None
    require(token and not any(character.isspace() for character in token), "Invalid credential format")
    return token


class RegistryReader:
    def __init__(self, token):
        self.token = token
        self.opener = build_opener(ProxyHandler({}), NoRedirects())

    def document(self, resource, digest, expected_size=None):
        require(resource in ("manifests", "blobs"), "Unsupported metadata resource")
        require(DIGEST.fullmatch(digest), "Invalid requested digest")
        url = f"https://{HOST}/v2/{REPOSITORY}/{resource}/{digest}"
        request = Request(url, method="GET", headers={
            "Authorization": "Bearer " + self.token,
            "Accept": ", ".join(sorted(MANIFEST_TYPES | INDEX_TYPES)) if resource == "manifests" else "application/octet-stream",
            "Accept-Encoding": "identity",
            "User-Agent": "nextstop-readonly-image-verifier/1",
        })
        try:
            with self.opener.open(request, timeout=20) as response:
                require(response.status == 200, "Unexpected registry status")
                require(response.geturl() == url, "Registry target changed")
                raw = response.read(MAX_DOCUMENT_BYTES + 1)
                require(len(raw) <= MAX_DOCUMENT_BYTES, "Registry metadata exceeded size limit")
        except HTTPError as error:
            raise VerificationError(f"Registry metadata request failed (HTTP {error.code})") from None
        except (URLError, TimeoutError, OSError):
            raise VerificationError("Registry metadata transport failed") from None
        require(expected_size is None or len(raw) == expected_size, "Metadata size does not match descriptor")
        require("sha256:" + hashlib.sha256(raw).hexdigest() == digest, "Metadata digest verification failed")
        try:
            parsed = json.loads(raw, object_pairs_hook=unique_object)
        except (ValueError, UnicodeDecodeError, RecursionError):
            raise VerificationError("Invalid registry metadata JSON") from None
        require(isinstance(parsed, dict), "Registry metadata must be an object")
        return parsed


def verify(reader, digest, commit):
    manifest = reader.document("manifests", digest)
    require(manifest.get("schemaVersion") == 2, "Unsupported manifest schema")
    media_type = manifest.get("mediaType")
    platform_digest = digest
    if media_type in INDEX_TYPES:
        entries = manifest.get("manifests")
        require(isinstance(entries, list) and 0 < len(entries) <= 128, "Invalid image index")
        matching = [entry for entry in entries if isinstance(entry, dict)
                    and isinstance(entry.get("platform"), dict)
                    and entry["platform"].get("os") == "linux"
                    and entry["platform"].get("architecture") == "amd64"
                    and entry["platform"].get("variant") in (None, "")]
        require(len(matching) == 1, "Expected exactly one linux/amd64 image")
        platform_digest, size = descriptor_digest(matching[0], MANIFEST_TYPES)
        manifest = reader.document("manifests", platform_digest, size)
        require(manifest.get("schemaVersion") == 2, "Unsupported platform manifest schema")
        media_type = manifest.get("mediaType")
    require(media_type in MANIFEST_TYPES, "Unsupported image manifest media type")
    config_digest, config_size = descriptor_digest(manifest.get("config"), CONFIG_TYPES)
    config = reader.document("blobs", config_digest, config_size)
    require(config.get("os") == "linux" and config.get("architecture") == "amd64", "Image is not linux/amd64")
    require(isinstance(config.get("config"), dict), "Missing image configuration")
    labels = config["config"].get("Labels")
    require(isinstance(labels, dict), "Missing image labels")
    require(labels.get("org.opencontainers.image.revision") == commit, "Image revision does not match expected commit")
    return {"verified": True, "commit": commit, "digest": digest,
            "platform": "linux/amd64", "platformDigest": platform_digest,
            "manifestAndConfigHashesVerified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--digest", required=True)
    args = parser.parse_args()
    if not COMMIT.fullmatch(args.commit) or not DIGEST.fullmatch(args.digest):
        parser.error("A complete lowercase Git commit and sha256 digest are required")
    try:
        result = verify(RegistryReader(get_token()), args.digest, args.commit)
    except VerificationError as error:
        print(json.dumps({"verified": False, "error": str(error)}), file=sys.stderr)
        return 1
    except Exception:
        print(json.dumps({"verified": False, "error": "Unexpected metadata verification failure"}), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
