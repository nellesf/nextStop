#!/usr/bin/env python3
"""Read currently distributed internal TestFlight build versions; never mutate Apple."""

import argparse
import base64
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "de.nextstop.app"
CONFIG_PATH = Path("/etc/nextstop/testflight-sync.json")
VERSION_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,64}", re.ASCII)
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_PAGES = 5


class SyncError(Exception):
    """A deliberately sanitized operational failure."""


def private_file_bytes(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077):
            raise SyncError("Synchronization credentials must be private regular files owned by the service user.")
        content = stream.read(16385)
    if len(content) > 16384:
        raise SyncError("Synchronization credentials exceed the size limit.")
    return content


def validate_config(config):
    patterns = {
        "appId": r"[0-9]{1,20}", "keyId": r"[A-Za-z0-9]{1,64}",
        "issuerId": r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
    }
    if not isinstance(config, dict) or any(
        not isinstance(config.get(key), str) or re.fullmatch(pattern, config[key]) is None
        for key, pattern in patterns.items()
    ) or not isinstance(config.get("privateKeyPath"), str) or not Path(
        config["privateKeyPath"]
    ).is_absolute():
        raise SyncError("The TestFlight synchronization configuration is invalid.")
    return config


def sign_jwt(config, issued_at):
    # cryptography is provided by Ubuntu's python3-cryptography package.
    try:
        from cryptography.exceptions import UnsupportedAlgorithm
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        private_key = serialization.load_pem_private_key(private_file_bytes(config["privateKeyPath"]), password=None)
        if not isinstance(private_key, ec.EllipticCurvePrivateKey) or not isinstance(
            private_key.curve, ec.SECP256R1
        ):
            raise ValueError("Wrong key type")
        header = {"alg": "ES256", "kid": config["keyId"], "typ": "JWT"}
        # Apple ignores pagination/sort parameters when matching token scope;
        # all other query parameters must match the actual read requests.
        scoped_build_query = {
            key: value for key, value in build_query(config["appId"]).items()
            if key not in {"limit", "cursor", "sort"}
        }
        payload = {
            "iss": config["issuerId"], "iat": issued_at, "exp": issued_at + 300,
            "aud": "appstoreconnect-v1",
            "scope": [
                "GET " + app_request_path(config["appId"]),
                "GET " + build_request_path(scoped_build_query),
            ],
        }
        encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=")
        signing_input = b".".join(encode(json.dumps(value, separators=(",", ":")).encode())
                                  for value in (header, payload))
        signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = utils.decode_dss_signature(signature)
        return (signing_input + b"." + encode(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()
    except ImportError:
        raise SyncError("The Python cryptography package is unavailable.") from None
    except (OSError, ValueError, TypeError, UnsupportedAlgorithm):
        raise SyncError("Unable to sign the App Store Connect read token; check the P-256 key and cryptography package.") from None


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SyncError("App Store Connect returned an unexpected redirect.")


def fetch_json(url, token, opener=None):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com" or parsed.fragment:
        raise SyncError("Refusing an unexpected App Store Connect URL.")
    request = Request(url, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    try:
        with (opener or build_opener(NoRedirects())).open(request, timeout=15) as response:
            if response.status != 200:
                raise SyncError("App Store Connect returned an unexpected HTTP status.")
            raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise SyncError("App Store Connect returned an oversized response.")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("Expected object")
        return value
    except HTTPError as error:
        raise SyncError(f"App Store Connect request failed (HTTP {error.code}).") from None
    except (URLError, OSError, ValueError, HTTPException):
        raise SyncError("Unable to read a valid App Store Connect response.") from None


def app_request_path(app_id):
    return f"/v1/apps/{app_id}?" + urlencode({"fields[apps]": "bundleId"})


def build_query(app_id):
    return {
        "filter[app]": app_id, "filter[processingState]": "VALID", "filter[expired]": "false",
        "include": "buildBetaDetail,app", "fields[builds]": "version,expired,processingState,buildBetaDetail,app",
        "fields[buildBetaDetails]": "internalBuildState", "fields[apps]": "bundleId", "limit": "200",
    }


def build_request_path(query):
    return "/v1/builds?" + urlencode(query)


def next_page_url(value, query):
    if value is None:
        return None
    try:
        parsed = urlsplit(value)
        parameters = parse_qs(parsed.query, strict_parsing=True, keep_blank_values=True, max_num_fields=10)
        cursor = parameters.pop("cursor", [])
        if (parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com"
            or parsed.path != "/v1/builds" or parsed.fragment
            or parameters != {key: [item] for key, item in query.items()}
            or len(cursor) != 1 or not 1 <= len(cursor[0]) <= 1024):
            raise ValueError("Unexpected pagination")
        # Rebuild from fixed parameters, never forward a server-supplied URL verbatim.
        return API + build_request_path({**query, "cursor": cursor[0]})
    except (ValueError, TypeError, AttributeError):
        raise SyncError("App Store Connect returned unsafe pagination.") from None


def page_versions(page, app_id):
    try:
        builds, included = page["data"], page.get("included", [])
        if not isinstance(builds, list) or not isinstance(included, list):
            raise ValueError("Expected resource lists")
        details = {}
        for item in included:
            if item["type"] == "buildBetaDetails":
                if item["id"] in details:
                    raise ValueError("Duplicate detail")
                details[item["id"]] = item["attributes"]["internalBuildState"]
        versions = set()
        for build in builds:
            if build["type"] != "builds":
                raise ValueError("Unexpected resource")
            attributes, relationships = build["attributes"], build["relationships"]
            if relationships["app"]["data"] != {"type": "apps", "id": app_id}:
                raise ValueError("Wrong app relationship")
            detail = relationships.get("buildBetaDetail", {}).get("data")
            if (attributes.get("processingState") != "VALID" or attributes.get("expired") is not False
                or not isinstance(detail, dict) or detail.get("type") != "buildBetaDetails"
                or details.get(detail.get("id")) != "IN_BETA_TESTING"):
                continue
            version = attributes.get("version")
            if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
                raise ValueError("Invalid version")
            versions.add(version)
        return versions
    except (KeyError, TypeError, ValueError, AttributeError):
        raise SyncError("App Store Connect returned invalid build metadata.") from None


def read_builds(config, *, requester=fetch_json, now=time.time, signer=sign_jwt):
    config = validate_config(config)
    app_id = config["appId"]
    token = signer(config, int(now()))
    app_url = API + app_request_path(app_id)
    try:
        app = requester(app_url, token)["data"]
        if (app["type"] != "apps" or app["id"] != app_id
            or app["attributes"]["bundleId"] != BUNDLE_ID):
            raise ValueError("Wrong app")
    except (KeyError, TypeError, ValueError):
        raise SyncError("The configured App Store Connect app does not match nextStop.") from None
    query = build_query(app_id)
    url = API + build_request_path(query)
    seen, versions = set(), set()
    for _ in range(MAX_PAGES):
        if url in seen:
            raise SyncError("App Store Connect pagination repeated a page.")
        seen.add(url)
        page = requester(url, token)
        versions.update(page_versions(page, app_id))
        if len(versions) > 32:
            raise SyncError("More than 32 active build versions require an operator review.")
        links = page.get("links", {})
        if not isinstance(links, dict):
            raise SyncError("App Store Connect returned invalid pagination metadata.")
        url = next_page_url(links.get("next"), query)
        if url is None:
            return sorted(versions)
    raise SyncError("App Store Connect pagination exceeded the five-page safety limit.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    args = parser.parse_args(argv)
    try:
        config = json.loads(private_file_bytes(args.config))
        versions = read_builds(config)
    except (OSError, ValueError):
        print("Unable to read the TestFlight synchronization configuration.", file=sys.stderr)
        return 1
    except SyncError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(versions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
