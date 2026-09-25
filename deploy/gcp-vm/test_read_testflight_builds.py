import base64
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
from http.client import IncompleteRead
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


SPEC = importlib.util.spec_from_file_location(
    "read_testflight_builds", Path(__file__).with_name("read-testflight-builds.py")
)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
CONFIG = {
    "appId": "6804153717", "keyId": "EXAMPLEKEY1",
    "issuerId": "11111111-2222-3333-4444-555555555555", "privateKeyPath": "/unused/key.p8",
}
APP = {"data": {"type": "apps", "id": CONFIG["appId"], "attributes": {"bundleId": "de.nextstop.app"}}}
EXPECTED_BUILD_QUERY = {
    "filter[app]": "6804153717", "filter[processingState]": "VALID", "filter[expired]": "false",
    "include": "buildBetaDetail,app", "fields[builds]": "version,expired,processingState,buildBetaDetail,app",
    "fields[buildBetaDetails]": "internalBuildState", "fields[apps]": "bundleId", "limit": "200",
}


def build_page(versions=("10",), state="IN_BETA_TESTING"):
    return {
        "data": [{
            "type": "builds", "id": f"build-{index}",
            "attributes": {"version": version, "expired": False, "processingState": "VALID"},
            "relationships": {
                "app": {"data": {"type": "apps", "id": CONFIG["appId"]}},
                "buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": f"detail-{index}"}},
            },
        } for index, version in enumerate(versions)],
        "included": [{"type": "buildBetaDetails", "id": f"detail-{index}",
                      "attributes": {"internalBuildState": state}}
                     for index in range(len(versions))] + [deepcopy(APP["data"])],
        "links": {"next": None},
    }


def page_url(cursor="next"):
    return helper.API + "/v1/builds?" + urlencode({**helper.build_query(CONFIG["appId"]), "cursor": cursor})


class ReadBuildsTests(unittest.TestCase):
    def read(self, *pages, app=None):
        self.requester = Mock(side_effect=[deepcopy(APP) if app is None else app, *pages])
        self.signer = Mock(return_value="token-never-log")
        return helper.read_builds(CONFIG, requester=self.requester, signer=self.signer, now=lambda: 1000)

    def test_returns_unique_versions_and_filters_exact_app(self):
        self.assertEqual(self.read(build_page(("10", "2", "10"))), ["10", "2"])
        self.signer.assert_called_once_with(CONFIG, 1000)
        app_call, builds_call = self.requester.call_args_list
        self.assertEqual(urlsplit(app_call.args[0]).path, "/v1/apps/6804153717")
        self.assertEqual(parse_qs(urlsplit(app_call.args[0]).query), {"fields[apps]": ["bundleId"]})
        self.assertEqual(urlsplit(builds_call.args[0]).path, "/v1/builds")
        self.assertEqual(parse_qs(urlsplit(builds_call.args[0]).query), {
            key: [value] for key, value in EXPECTED_BUILD_QUERY.items()
        })

    def test_rejects_wrong_app_before_build_request(self):
        for field, value in (("bundleId", "other.app"), ("id", "123"), ("type", "builds")):
            app = deepcopy(APP)
            (app["data"]["attributes"] if field == "bundleId" else app["data"])[field] = value
            with self.subTest(field=field), self.assertRaises(helper.SyncError):
                self.read(build_page(), app=app)
            self.assertEqual(self.requester.call_count, 1)

    def test_skips_unavailable_or_unlinked_builds(self):
        pages = []
        for field, value in (("expired", True), ("expired", "false"), ("expired", 0),
                             ("processingState", "PROCESSING")):
            page = build_page()
            page["data"][0]["attributes"][field] = value
            pages.append(page)
        pages.extend(build_page(state=state) for state in ("READY_FOR_BETA_TESTING", "EXPIRED", None))
        page = build_page()
        page["data"][0]["relationships"]["buildBetaDetail"]["data"]["id"] = "missing"
        pages.append(page)
        page = build_page()
        page["included"] = []
        pages.append(page)
        for page in pages:
            with self.subTest(page=page):
                self.assertEqual(self.read(page), [])

    def test_rejects_malformed_or_foreign_metadata(self):
        pages = [{"data": None}, {"data": [None]}, build_page(("bad,version",)), build_page((3,))]
        page = build_page()
        page["data"][0]["relationships"]["app"]["data"]["id"] = "123"
        pages.append(page)
        page = build_page()
        page["data"][0]["relationships"]["app"] = {"links": {"related": "unused"}}
        pages.append(page)
        page = build_page()
        page["included"].append(deepcopy(page["included"][0]))
        pages.append(page)
        for page in pages:
            with self.subTest(page=page), self.assertRaises(helper.SyncError):
                self.read(page)

    def test_follows_safe_pagination_and_combines_results(self):
        page = build_page(("10",))
        page["links"]["next"] = page_url()
        self.assertEqual(self.read(page, build_page(("11", "10"))), ["10", "11"])
        self.assertEqual(self.requester.call_args.args[0], page_url())

    def test_rejects_unsafe_pagination_without_sending_token(self):
        urls = [
            page_url().replace("api.appstoreconnect.apple.com", "attacker.example"),
            page_url().replace("https:", "http:"), page_url().replace("/v1/builds?", "/v1/users?"),
            page_url().replace("6804153717", "123"), page_url() + "&cursor=duplicate",
            page_url() + "#fragment", page_url() + "&unexpected=true", 42,
        ]
        for url in urls:
            page = build_page()
            page["links"]["next"] = url
            with self.subTest(url=url), self.assertRaises(helper.SyncError):
                self.read(page)
            self.assertEqual(self.requester.call_count, 2)

    def test_caps_pages_and_detects_repeated_cursor(self):
        pages = []
        for index in range(5):
            page = build_page()
            page["links"]["next"] = page_url(str(index))
            pages.append(page)
        with self.assertRaisesRegex(helper.SyncError, "five-page"):
            self.read(*pages)
        self.assertEqual(self.requester.call_count, 6)
        with self.assertRaisesRegex(helper.SyncError, "repeated"):
            self.read(pages[0], pages[0])

    def test_rejects_over_32_versions_without_truncation(self):
        with self.assertRaisesRegex(helper.SyncError, "32"):
            self.read(build_page(tuple(str(index) for index in range(33))))

    def test_validates_config_before_signing_or_network(self):
        for field, value in (("appId", "1/../../users"), ("keyId", "bad\nkey"),
                             ("issuerId", "invalid"), ("privateKeyPath", "relative.p8")):
            signer, requester = Mock(), Mock()
            with self.subTest(field=field), self.assertRaises(helper.SyncError):
                helper.read_builds({**CONFIG, field: value}, requester=requester, signer=signer)
            signer.assert_not_called()
            requester.assert_not_called()


class TransportTests(unittest.TestCase):
    def test_bounds_response_and_uses_timeout(self):
        response = Mock(status=200)
        response.read.return_value = b'{"data": []}'
        opener = Mock()
        opener.open.return_value.__enter__ = Mock(return_value=response)
        opener.open.return_value.__exit__ = Mock(return_value=False)
        self.assertEqual(helper.fetch_json(page_url(), "secret-token", opener), {"data": []})
        response.read.assert_called_once_with(1024 * 1024 + 1)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(opener.open.call_args.kwargs, {"timeout": 15})
        for raw in (b"x" * (1024 * 1024 + 1), b"invalid-secret-response", b"[]"):
            response.read.return_value = raw
            with self.assertRaises(helper.SyncError) as error:
                helper.fetch_json(page_url(), "secret-token", opener)
            self.assertNotIn("secret", str(error.exception))

    def test_sanitizes_http_network_and_partial_body_errors(self):
        for failure in (HTTPError(page_url(), 403, "secret", {}, io.BytesIO(b"secret")),
                        URLError("secret"), IncompleteRead(b"secret")):
            opener = Mock()
            opener.open.side_effect = failure
            with self.subTest(failure=type(failure)), self.assertRaises(helper.SyncError) as error:
                helper.fetch_json(page_url(), "secret-token", opener)
            self.assertNotIn("secret", str(error.exception))

    def test_redirect_handler_refuses_redirects(self):
        with self.assertRaises(helper.SyncError):
            helper.NoRedirects().redirect_request(None, None, 302, "secret", {}, "https://attacker.example")

    def test_cli_errors_never_print_raw_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text('{"secret": "invalid"}')
            config.chmod(0o600)
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(helper.main(["--config", str(config)]), 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertNotIn("secret", stderr.getvalue())

    def test_cli_emits_only_json_versions_including_empty_results(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps(CONFIG))
            config.chmod(0o600)
            for versions in (["10"], []):
                stdout, stderr = io.StringIO(), io.StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr), patch.object(helper, "read_builds", return_value=versions):
                    self.assertEqual(helper.main(["--config", str(config)]), 0)
                self.assertEqual(json.loads(stdout.getvalue()), versions)
                self.assertEqual(stderr.getvalue(), "")

    def test_credentials_reject_world_readable_symlink_and_oversized_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key.p8"
            path.write_bytes(b"secret")
            path.chmod(0o644)
            with self.assertRaises(helper.SyncError):
                helper.private_file_bytes(path)
            path.chmod(0o600)
            self.assertEqual(helper.private_file_bytes(path), b"secret")
            link = path.with_name("link.p8")
            link.symlink_to(path)
            with self.assertRaises(OSError):
                helper.private_file_bytes(link)
            path.write_bytes(b"x" * 16385)
            with self.assertRaises(helper.SyncError):
                helper.private_file_bytes(path)


class SigningTests(unittest.TestCase):
    def test_es256_signature_scope_and_short_lifetime(self):
        key = ec.generate_private_key(ec.SECP256R1())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key.p8"
            path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                              serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            path.chmod(0o600)
            token = helper.sign_jwt({**CONFIG, "privateKeyPath": str(path)}, 1000)
        header, payload, signature = token.split(".")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        self.assertEqual(json.loads(decode(header)), {"alg": "ES256", "kid": CONFIG["keyId"], "typ": "JWT"})
        claims = json.loads(decode(payload))
        self.assertEqual(claims, {
            "iss": CONFIG["issuerId"], "iat": 1000, "exp": 1300, "aud": "appstoreconnect-v1",
            "scope": [
                "GET /v1/apps/6804153717?fields%5Bapps%5D=bundleId",
                "GET /v1/builds?" + urlencode({
                    key: value for key, value in EXPECTED_BUILD_QUERY.items() if key != "limit"
                }),
            ],
        })
        raw_signature = decode(signature)
        self.assertEqual(len(raw_signature), 64)
        der_signature = utils.encode_dss_signature(int.from_bytes(raw_signature[:32], "big"),
                                                   int.from_bytes(raw_signature[32:], "big"))
        key.public_key().verify(der_signature, (header + "." + payload).encode(), ec.ECDSA(hashes.SHA256()))

        # Check the signed scope against every actual request, including a
        # subsequent page, so fields/include/filter changes cannot drift.
        first_page = build_page()
        first_page["links"]["next"] = page_url()
        requester = Mock(side_effect=[deepcopy(APP), first_page, build_page(("11",))])
        helper.read_builds(CONFIG, requester=requester, signer=lambda *_: token, now=lambda: 1000)
        scoped_requests = {}
        for scope in claims["scope"]:
            method, path = scope.split(" ", 1)
            self.assertEqual(method, "GET")
            parsed = urlsplit(path)
            scoped_requests[parsed.path] = parse_qs(parsed.query)
        for request in requester.call_args_list:
            parsed = urlsplit(request.args[0])
            parameters = parse_qs(parsed.query)
            for ignored in ("limit", "cursor", "sort"):
                parameters.pop(ignored, None)
            self.assertEqual(scoped_requests[parsed.path], parameters)
            self.assertEqual(request.args[1], token)

    def test_refuses_other_curve_or_invalid_private_key(self):
        key = ec.generate_private_key(ec.SECP384R1())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key.p8"
            for content in (b"secret-invalid-key", key.private_bytes(serialization.Encoding.PEM,
                           serialization.PrivateFormat.PKCS8, serialization.NoEncryption())):
                path.write_bytes(content)
                path.chmod(0o600)
                with self.assertRaises(helper.SyncError) as error:
                    helper.sign_jwt({**CONFIG, "privateKeyPath": str(path)}, 1000)
                self.assertNotIn("secret", str(error.exception))


if __name__ == "__main__":
    unittest.main()
