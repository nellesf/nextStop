#!/usr/bin/env python3
"""Bounded synthetic staging candidate smokes; no deployment or provider refresh.

Tokens and HTTP payloads remain in memory. The output is a partial, release-bound
smoke report, never a complete promotion receipt. Distinct real client-IP
isolation, artifact/IAM/jobs/backup and live-task gates require independent evidence.
"""
import argparse
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

from render import PROJECT, ConfigurationError, origin, release_id, validate

MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
SMOKE_GATES = ("apiReady", "authReady", "syntheticSearchPassed", "xffPrefixResistancePassed")


class VerificationError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request_json(url, method, headers, payload=None, timeout=30):
    """No redirects, ambient proxy, cookies, retries, request logging or unbounded bodies."""
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    request = urllib.request.Request(url, method=method, headers=headers,
                                     data=None if payload is None else json.dumps(payload).encode())
    response = None
    try:
        try:
            response = client.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        status = response.status
        if response.headers.get("Content-Encoding", "identity").lower() != "identity":
            raise VerificationError("Unexpected encoded verification response.")
        value = response.read(MAXIMUM_RESPONSE_BYTES + 1)
        if len(value) > MAXIMUM_RESPONSE_BYTES:
            raise VerificationError("Verification response exceeds its bound.")
        body = json.loads(value)
        if not isinstance(body, dict):
            raise VerificationError("Verification response is not an object.")
        return status, body, {key.lower(): value for key, value in response.headers.items()}
    except (OSError, ValueError, TypeError, http.client.HTTPException, urllib.error.URLError):
        raise VerificationError("Candidate request failed or returned an invalid response.") from None
    finally:
        if response is not None:
            response.close()


def identity_provider(service_account=None):
    """Developer identity by default; CI may explicitly impersonate its authorized staging deploy identity."""
    if service_account is not None and not re.fullmatch(r"[a-z][a-z0-9-]{5,29}@" + re.escape(PROJECT) + r"\.iam\.gserviceaccount\.com", service_account):
        raise VerificationError("Identity account must belong to isolated staging.")
    cached = {}

    def token(audience):
        if audience not in cached:
            command = ["gcloud", "auth", "print-identity-token", "--quiet", "--verbosity=error"]
            if service_account is not None:
                command += ["--impersonate-service-account=" + service_account, "--audiences=" + audience]
            try:
                result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=30)
                value = result.stdout.strip()
                if result.returncode != 0 or not re.fullmatch(r"[A-Za-z0-9_.-]{32,8192}", value):
                    raise VerificationError("Verification identity unavailable.")
                cached[audience] = value
            except (OSError, subprocess.TimeoutExpired):
                raise VerificationError("Verification identity unavailable.") from None
        return cached[audience]
    return token


def verify(config, token_provider, request=request_json, monotonic=time.monotonic):
    """One synthetic search, two readiness checks and at most eight cheap schema failures, sequentially."""
    return _verify(config, token_provider, request, monotonic, public=False)


def verify_public(config, token_provider, request=request_json):
    """After promotion, check the fixed public staging origin without another limiter probe."""
    return _verify(config, token_provider, request, time.monotonic, public=True)


def _verify(config, token_provider, request, monotonic, public):
    validate(config)
    tag = "r-" + release_id(config)
    gateway = "https://api-staging.nextstop.tech" if public else origin("gateway", tag)
    broker = origin("broker", tag)
    try:
        broker_identity = token_provider(origin("broker"))
        status, minted, _ = request(broker + "/token", "POST", {"Authorization": "Bearer " + broker_identity})
        app_token = minted.get("accessToken")
        if (status != 200 or set(minted) != {"accessToken", "expiresInSeconds", "tokenType"}
                or minted.get("tokenType") != "Bearer" or type(minted.get("expiresInSeconds")) is not int
                or not 60 <= minted["expiresInSeconds"] <= 900
                or not isinstance(app_token, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{32,4096}", app_token)):
            raise VerificationError("Candidate broker contract failed.")
        # Cloud Run consumes its own ID token; the public gateway keeps the app
        # token separate and generates fresh private-service IAM credentials.
        headers = {"Authorization": "Bearer " + app_token, "Content-Type": "application/json"}
        if not public:
            headers["X-Serverless-Authorization"] = "Bearer " + token_provider(origin("gateway"))
        expected = {"status": "ready", "release": config["backendImage"].split("@", 1)[1]}
        for path in ("/ready", "/ready/auth"):
            status, body, _ = request(gateway + path, "GET", headers)
            if status != 200 or body != expected:
                raise VerificationError("Candidate readiness or release identity failed.")
        # Public Frankfurt/Wertheim fixture; never accepts an owner's actual route.
        payload = {"requestId": str(uuid.uuid4()), "route": {"type": "LineString",
                   "coordinates": [[8.68, 50.11], [9.12, 49.9], [9.57, 49.77]]},
                   "criteria": {"distanceRangeMeters": {"minimum": 15000, "maximum": 50000},
                                "minimumChargingPoints": 2, "minimumPowerKW": 11}}
        status, body, _ = request(gateway + "/v1/charging-parks/search", "POST", headers, payload)
        candidates = body.get("candidates")
        if (status != 200 or not isinstance(candidates, list) or not 1 <= len(candidates) <= 100
                or any(not isinstance(candidate, dict) for candidate in candidates)
                or not isinstance(body.get("snapshotToken"), str) or not body["snapshotToken"]):
            raise VerificationError("Synthetic candidate search failed.")
        if not public:
            prove_prefix_resistance(gateway, headers, request, monotonic)
        return {gate: True for gate in SMOKE_GATES if not public or gate != "xffPrefixResistancePassed"}
    except VerificationError:
        raise
    except Exception:
        # Injected HTTP/identity implementations must not disclose subprocess
        # errors, auth payloads, result records or exact network addresses either.
        raise VerificationError("Candidate verification failed.") from None


def prove_prefix_resistance(gateway, headers, request, monotonic):
    start = monotonic()
    rejected = False
    for index in range(8):
        if monotonic() - start >= 10:
            raise VerificationError("Forwarded-prefix probe was inconclusive within its time budget.")
        spoof = f"192.0.2.{index + 1}, 198.51.100.{index + 1}"
        status, body, reply_headers = request(gateway + "/v1/auth/app-attest/challenge", "POST",
            {**headers, "X-Forwarded-For": spoof}, {"syntheticInvalidField": True}, timeout=3)
        if monotonic() - start >= 10:
            raise VerificationError("Forwarded-prefix probe was inconclusive within its time budget.")
        if status == 429:
            # Distinguish the gateway ingress budget from authentication-service
            # capacity limits. Never generate real challenges or mutate auth rows.
            if (body.get("type") != "urn:nextstop:error:rate-limited"
                    or reply_headers.get("retry-after") != "5"
                    or "x-request-id" in reply_headers):
                raise VerificationError("Unexpected limiter rejected the synthetic probe.")
            rejected = True
        elif status != 400:
            raise VerificationError("Synthetic header probe had an unexpected outcome.")
    if not rejected:
        raise VerificationError("Forwarded-prefix resistance was not demonstrated.")


def smoke_report(config, gates, now=None):
    if set(gates) != set(SMOKE_GATES) or any(value is not True for value in gates.values()):
        raise VerificationError("Incomplete candidate smoke evidence.")
    return {"release": release_id(config), "image": config["backendImage"], "commit": config["commit"],
            "verifiedAt": (now or datetime.now(timezone.utc)).isoformat(), **gates}


def write_report(path, report):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(report, stream, sort_keys=True, indent=2)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--impersonate-service-account")
    args = parser.parse_args()
    try:
        config = validate(json.loads(args.config.read_text()))
        gates = verify(config, identity_provider(args.impersonate_service_account))
        write_report(args.output, smoke_report(config, gates))
        print(json.dumps({"status": "passed", "release": release_id(config), "gates": list(SMOKE_GATES),
                          "clientIPIsolationStillRequiresIndependentEvidence": True}))
    except (VerificationError, ConfigurationError, OSError, ValueError, TypeError):
        print('{"status":"failed","reason":"Candidate verification did not pass; no promotion receipt was written."}', file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
