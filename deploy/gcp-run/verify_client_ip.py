#!/usr/bin/env python3
"""Prove candidate IP-bucket separation from this computer and the existing staging VM.

Only invalid App Attest schemas are sent. No challenges, rows, search requests or
provider jobs are created. IAM credentials travel to the VM through encrypted SSH
stdin, never command arguments, environment variables, files or printed output.
"""
import argparse
from contextlib import suppress
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import subprocess
import sys
import time

from render import PROJECT, ConfigurationError, origin, release_id, validate
from verify import VerificationError, identity_provider, request_json, write_report

PREFIX = b"NEXTSTOP_IP_PROBE:"
PUBLIC_ORIGIN = "https://api-staging.nextstop.tech"
REMOTE_SCRIPT = r'''
import json, re, signal, ssl, sys, time, urllib.error, urllib.request
signal.alarm(90)
def emit(value):
    print("NEXTSTOP_IP_PROBE:"+json.dumps(value,separators=(",",":")),flush=True)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None
try:
    emit({"kind":"ready"})
    configuration=json.loads(sys.stdin.readline(9001))
    if set(configuration)!={"release","identityToken","public"}: raise ValueError()
    release=configuration["release"]; token=configuration["identityToken"]; public=configuration["public"]
    if not isinstance(release,str) or not re.fullmatch(r"[0-9a-f]{12}",release): raise ValueError()
    if type(public) is not bool: raise ValueError()
    if public:
        if token is not None: raise ValueError()
    elif not isinstance(token,str) or not re.fullmatch(r"[A-Za-z0-9_.-]{32,8192}",token): raise ValueError()
    base="https://api-staging.nextstop.tech" if public else "https://r-"+release+"---nextstop-gateway-353471052580.europe-west1.run.app"
    url=base+"/v1/auth/app-attest/challenge"
    client=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    emit({"kind":"configured"})
    probes=0
    while True:
        line=sys.stdin.readline(1001)
        if not line: break
        command=json.loads(line)
        if command=={"operation":"stop"}: break
        if set(command)!={"operation","sequence"} or command["operation"]!="probe" or type(command["sequence"]) is not int or not 1<=command["sequence"]<=254 or probes>=2: raise ValueError()
        probes+=1; n=command["sequence"]
        headers={"Content-Type":"application/json","X-Forwarded-For":"192.0.2."+str(n)+", 198.51.100."+str(n)}
        if not public: headers["X-Serverless-Authorization"]="Bearer "+token
        request=urllib.request.Request(url,method="POST",data=b'{"syntheticInvalidField":true}',headers=headers)
        response=None; start=time.monotonic()
        try:
            try: response=client.open(request,timeout=3)
            except urllib.error.HTTPError as error: response=error
            data=response.read(4097)
            if len(data)>4096 or response.headers.get("Content-Encoding","identity").lower()!="identity": raise ValueError()
            value=json.loads(data)
            status=response.status
            kind="unexpected"
            if status==400 and value.get("type")=="urn:nextstop:error:invalid-app-attest-request" and response.headers.get("X-Request-ID"):
                kind="schema_rejected"
            if status==429 and value.get("type")=="urn:nextstop:error:rate-limited" and response.headers.get("Retry-After")=="5" and not response.headers.get("X-Request-ID"):
                kind="gateway_rate_limited"
            emit({"kind":kind,"status":status,"latencyMs":round((time.monotonic()-start)*1000,1)})
        finally:
            if response is not None: response.close()
except Exception:
    emit({"kind":"failed"})
    sys.exit(1)
'''


def remote_command():
    return ["gcloud", "compute", "ssh", "nextstop-backend", "--project=" + PROJECT,
            "--zone=europe-west3-a", "--tunnel-through-iap", "--quiet", "--verbosity=error",
            "--ssh-flag=-T", "--ssh-flag=-oBatchMode=yes", "--ssh-flag=-oLogLevel=ERROR",
            "--command=python3 -u -c " + shlex.quote(REMOTE_SCRIPT)]


class VMProbe:
    def __init__(self, revision, token, public=False):
        gateway_origin(revision, public)
        self.process = subprocess.Popen(remote_command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        self.buffer = bytearray()
        try:
            if self.receive(45) != {"kind": "ready"}:
                raise VerificationError("Staging VM probe did not become ready.")
            self.send({"release": revision, "identityToken": token, "public": public})
            if self.receive(5) != {"kind": "configured"}:
                raise VerificationError("Staging VM probe configuration failed.")
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, timeout):
        deadline = time.monotonic() + timeout
        discarded = 0
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while True:
                while b"\n" in self.buffer:
                    line, _, remainder = self.buffer.partition(b"\n")
                    self.buffer = bytearray(remainder)
                    if line.startswith(PREFIX):
                        try:
                            result = json.loads(line[len(PREFIX):])
                        except (ValueError, TypeError):
                            raise VerificationError("Invalid staging VM probe response.") from None
                        if (not isinstance(result, dict) or set(result) - {"kind", "status", "latencyMs"}
                                or result.get("kind") not in {"ready", "configured", "failed", "schema_rejected", "gateway_rate_limited", "unexpected"}):
                            raise VerificationError("Invalid staging VM probe response.")
                        return result
                    # gcloud/SSH banners are never reflected to output.
                    discarded += len(line)
                    if discarded > 16384:
                        raise VerificationError("Staging VM probe transport failed.")
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise VerificationError("Staging VM probe timed out.")
                data = os.read(self.process.stdout.fileno(), 4096)
                if not data:
                    raise VerificationError("Staging VM probe stopped unexpectedly.")
                self.buffer.extend(data)
                if len(self.buffer) > 16384:
                    raise VerificationError("Staging VM probe response exceeds its bound.")

    def probe(self, sequence):
        self.send({"operation": "probe", "sequence": sequence})
        return self.receive(5)

    def close(self):
        try:
            if self.process.poll() is None:
                try:
                    self.send({"operation": "stop"})
                    self.process.stdin.close()
                    self.process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    with suppress(ProcessLookupError):
                        os.killpg(self.process.pid, signal.SIGTERM)
                    try:
                        self.process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        with suppress(ProcessLookupError):
                            os.killpg(self.process.pid, signal.SIGKILL)
                        self.process.wait(timeout=3)
        finally:
            if self.process.stdin is not None:
                with suppress(OSError, ValueError):
                    self.process.stdin.close()
            if self.process.stdout is not None:
                self.process.stdout.close()


def gateway_origin(revision, public=False):
    if type(public) is not bool or not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{12}", revision):
        raise VerificationError("Only a reviewed revision and fixed staging ingress mode are accepted.")
    return PUBLIC_ORIGIN if public else origin("gateway", "r-" + revision)


def local_probe(revision, token, sequence, request=request_json, monotonic=time.monotonic, public=False):
    gateway = gateway_origin(revision, public)
    start = monotonic()
    request_headers = {"Content-Type": "application/json", "X-Forwarded-For": f"192.0.2.{sequence}, 198.51.100.{sequence}"}
    if not public:
        request_headers["X-Serverless-Authorization"] = "Bearer " + token
    status, body, headers = request(gateway + "/v1/auth/app-attest/challenge", "POST", request_headers,
                                   {"syntheticInvalidField": True}, timeout=3)
    kind = "unexpected"
    if status == 400 and body.get("type") == "urn:nextstop:error:invalid-app-attest-request" and headers.get("x-request-id"):
        kind = "schema_rejected"
    if status == 429 and body.get("type") == "urn:nextstop:error:rate-limited" and headers.get("retry-after") == "5" and not headers.get("x-request-id"):
        kind = "gateway_rate_limited"
    return {"kind": kind, "status": status, "latencyMs": round((monotonic() - start) * 1000, 1)}


def prove_isolation(first, second, monotonic=time.monotonic):
    """B is already connected/warm. A429 -> B400 -> A429 excludes simple refill/global-bucket explanations."""
    samples = []
    def call(source, function, sequence):
        value = function(sequence)
        if (not isinstance(value, dict) or set(value) != {"kind", "status", "latencyMs"}
                or value["kind"] not in {"schema_rejected", "gateway_rate_limited"}
                or value["status"] != (400 if value["kind"] == "schema_rejected" else 429)
                or type(value["latencyMs"]) not in {int, float} or not 0 <= value["latencyMs"] <= 5000):
            raise VerificationError("Synthetic source probe failed.")
        samples.append({"source": source, **value})
        return value["kind"]
    if call("staging-vm", second, 1) != "schema_rejected":
        raise VerificationError("Staging VM source is not independently ready; allow its bucket to refill.")
    if call("operator", first, 1) != "schema_rejected":
        raise VerificationError("Operator source is not independently ready; allow its bucket to refill.")
    start = monotonic()
    for sequence in range(2, 10):
        if monotonic() - start >= 10:
            raise VerificationError("Operator limiter exhaustion was inconclusive within its time budget.")
        kind = call("operator", first, sequence)
        if monotonic() - start >= 10:
            raise VerificationError("Operator limiter exhaustion was inconclusive within its time budget.")
        if kind == "gateway_rate_limited":
            break
    else:
        raise VerificationError("Changing spoofed prefixes did not exhaust one source bucket.")
    if call("staging-vm", second, 2) != "schema_rejected":
        raise VerificationError("A separate source was limited with the operator source.")
    if call("operator", first, 20) != "gateway_rate_limited":
        raise VerificationError("Operator bucket refilled or changed; isolation evidence is inconclusive.")
    return {"clientIPIsolationPassed": True, "xffPrefixResistancePassed": True, "samples": samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-release", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--impersonate-service-account")
    parser.add_argument("--public", action="store_true", help="After DNS cutover, test only https://api-staging.nextstop.tech.")
    args = parser.parse_args()
    remote = None
    try:
        config = validate(json.loads(args.config.read_text()))
        revision = release_id(config)
        if not re.fullmatch(r"[0-9a-f]{12}", args.expected_release) or revision != args.expected_release:
            raise VerificationError("Candidate release does not match the reviewed target.")
        token = None if args.public else identity_provider(args.impersonate_service_account)(origin("gateway"))
        if args.public:
            status, body, _ = request_json(PUBLIC_ORIGIN + "/ready", "GET", {})
            if status != 200 or body != {"status": "ready", "release": config["backendImage"].split("@", 1)[1]}:
                raise VerificationError("Public staging is not serving the reviewed release.")
        remote = VMProbe(revision, token, args.public)
        result = prove_isolation(lambda sequence: local_probe(revision, token, sequence, public=args.public), remote.probe)
        remote.close(); remote = None
        report = {"release": revision, "image": config["backendImage"], "commit": config["commit"],
                  "verifiedAt": datetime.now(timezone.utc).isoformat(), "ingress": "public-staging" if args.public else "candidate-run-app", **result}
        write_report(args.output, report)
        print(json.dumps({"status": "passed", "release": revision, "clientIPIsolationPassed": True,
                          "xffPrefixResistancePassed": True, "ingress": report["ingress"],
                          "requests": len(result["samples"]), "remoteStopped": True}))
    except (VerificationError, ConfigurationError, OSError, ValueError, TypeError, subprocess.SubprocessError):
        print('{"status":"failed","reason":"Two-source isolation was not demonstrated; no gate was written."}', file=sys.stderr)
        raise SystemExit(1) from None
    finally:
        if remote is not None:
            remote.close()


if __name__ == "__main__":
    main()
