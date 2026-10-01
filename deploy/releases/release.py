#!/usr/bin/env python3
"""Fail-closed release of prebuilt immutable images; never prints process secrets."""
from __future__ import annotations

import argparse
import fcntl
import json
import http.client
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

DOMAINS = {"staging": "api-staging.nextstop.tech", "production": "api.nextstop.tech"}
PORTS = {"blue": (3100, 3101), "green": (3200, 3201), "legacy": (3000, 3001)}
DIGEST = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9./:_-]*@sha256:[0-9a-f]{64}\Z")


class ReleaseError(Exception):
    pass


def load_env(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ReleaseError("Invalid host environment format.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".new")
    descriptor = os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, mode)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def render_nginx(template: str, domain: str, slot: str) -> str:
    api, auth = PORTS[slot]
    return template.replace("__NEXTSTOP_DOMAIN__", domain).replace(
        "__NEXTSTOP_API_PORT__", str(api)).replace("__NEXTSTOP_AUTH_PORT__", str(auth))


def run(command: list[str], environment: dict[str, str], timeout: int = 180) -> str:
    # stderr/stdout may contain DSNs or secret values from a failing tool. Retain
    # neither in release logs and report only a fixed operation class on failure.
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseError("Release subprocess unavailable or timed out.") from error
    if result.returncode != 0:
        raise ReleaseError("Release subprocess failed; serving slot retained or restored.")
    return result.stdout


class Release:
    def __init__(self, args, runner=run, sleeper=time.sleep):
        self.args = args
        self.runner, self.sleep = runner, sleeper
        self.root = Path(args.root)
        self.config = load_env(Path(args.host_config))
        self.secrets = load_env(Path(args.secrets))
        if self.config.get("NEXTSTOP_ENVIRONMENT") != args.environment:
            raise ReleaseError("Requested environment does not match this host.")
        self.domain = self.config.get("DOMAIN", DOMAINS[args.environment])
        if self.domain != DOMAINS[args.environment]:
            raise ReleaseError("Environment/domain mismatch.")
        if self.config.get("DATABASE_MODE", "local") != "local":
            raise ReleaseError("This release supports one VM with a local database per environment.")
        self.environment = {**os.environ, **self.secrets, **self.config}
        self.environment["BACKEND_IMAGE"] = args.image or ""
        self.environment["RELEASE_IMAGE_DIGEST"] = (args.image or "").partition("@")[2]
        host = self.config.get("DATABASE_HOST", "database")
        port = self.config.get("DATABASE_PORT", "5432")
        if host != "database" or port != "5432":
            raise ReleaseError("The private local database service must be database:5432.")
        self.environment.update(DATABASE_HOST=host, DATABASE_PORT=port)
        for key, role, password in [
            ("API_DATABASE_URL", "nextstop_api", "API_DATABASE_PASSWORD"),
            ("AUTH_DATABASE_URL", "nextstop_auth", "AUTH_DATABASE_PASSWORD"),
            ("SUPPORT_DATABASE_URL", "nextstop_support", "SUPPORT_DATABASE_PASSWORD"),
            ("WORKER_DATABASE_URL", "nextstop_worker", "WORKER_DATABASE_PASSWORD"),
            ("MIGRATOR_DATABASE_URL", self.config.get("DATABASE_OWNER", "nextstop_app"), "POSTGRES_PASSWORD"),
        ]:
            encoded = urllib.parse.quote(self.secrets.get(password, ""), safe="")
            self.environment[key] = f"postgresql://{role}:{encoded}@{host}:{port}/nextstop"
        self.compose_file = self.root / "deploy/gcp-vm/compose.release.yaml"
        self.project = self.config.get("COMPOSE_PROJECT_NAME", "gcp-vm")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", self.project):
            raise ReleaseError("Invalid Compose project.")
        self.state_dir = Path(args.state_directory)
        self.state_file = self.state_dir / "state.json"
        self.site = Path(args.nginx_site)
        self.enabled_site = Path(args.nginx_enabled_site)
        self.state = json.loads(self.state_file.read_text()) if self.state_file.exists() else {}

    def command(self, *arguments, timeout=180):
        return self.runner(list(arguments), self.environment, timeout)

    def compose(self, *arguments, image=None, timeout=180):
        environment = {**self.environment}
        if image:
            environment["BACKEND_IMAGE"] = image
            environment["RELEASE_IMAGE_DIGEST"] = image.partition("@")[2]
        return self.runner(["docker", "compose", "--project-name", self.project,
                            "--env-file", self.args.secrets, "-f", str(self.compose_file), *arguments],
                           environment, timeout)

    def save(self, state):
        atomic_write(self.state_file, json.dumps(state, sort_keys=True) + "\n")
        self.state = state

    def token(self):
        result = json.loads(self.compose("run", "--rm", "--no-deps", "-T", "simulator-token-mint"))
        token = result.get("accessToken")
        if not isinstance(token, str) or len(token) > 2048:
            raise ReleaseError("Release token mint failed.")
        return token

    def request(self, url, body=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            # Probe this node's Nginx with the real TLS hostname even before DNS
            # is moved. The reserved pseudo-origin never leaves the host.
            if url.startswith("https://local-proxy/"):
                headers["Host"] = self.domain
                connection = http.client.HTTPSConnection(self.domain, timeout=20)
                connection.sock = ssl.create_default_context().wrap_socket(
                    socket.create_connection(("127.0.0.1", 443), timeout=20), server_hostname=self.domain)
                try:
                    connection.request("GET" if body is None else "POST", urllib.parse.urlsplit(url).path,
                                       body=None if body is None else json.dumps(body), headers=headers)
                    response = connection.getresponse()
                    if response.status != 200:
                        raise ReleaseError("Local TLS proxy gate failed.")
                    return json.loads(response.read(512 * 1024))
                finally:
                    connection.close()
            with urllib.request.urlopen(request, timeout=20, context=ssl.create_default_context()) as response:
                return json.loads(response.read(512 * 1024))
        except (OSError, ValueError, urllib.error.HTTPError) as error:
            raise ReleaseError("Release HTTP gate failed.") from error

    def ready(self, base, path="/ready"):
        deadline = time.monotonic() + 120
        for attempt in range(30):
            if time.monotonic() >= deadline:
                break
            try:
                response = self.request(base + path)
                if response.get("status") == "ready" and response.get("release") == self.environment["RELEASE_IMAGE_DIGEST"]:
                    return
            except ReleaseError:
                pass
            if attempt < 29:
                self.sleep(2)
        raise ReleaseError("Candidate readiness did not pass.")

    def public_gate(self, token):
        self.ready(f"https://{self.domain}")
        self.ready(f"https://{self.domain}", "/ready/auth")
        self.search_gate(f"https://{self.domain}", token)

    def search_gate(self, base, token):
        # Public synthetic Frankfurt/Wertheim corridor; never a driver route.
        body = {"requestId": str(uuid.uuid4()), "route": {"type": "LineString", "coordinates":
                [[8.68, 50.11], [9.12, 49.9], [9.57, 49.77]]}, "criteria": {
                "distanceRangeMeters": {"minimum": 15000, "maximum": 50000},
                "minimumChargingPoints": 2, "minimumPowerKW": 11}}
        response = self.request(base + "/v1/charging-parks/search", body, token)
        if not isinstance(response.get("candidates"), list) or not response["candidates"] or not isinstance(response.get("snapshotToken"), str):
            raise ReleaseError("Synthetic search returned no valid candidates.")

    def pull(self, image):
        if not DIGEST.fullmatch(image or ""):
            raise ReleaseError("A registry image pinned by sha256 digest is required.")
        self.command("docker", "pull", image, timeout=600)

    def require_secrets(self, names):
        if any(len(self.secrets.get(name, "")) < 16 for name in names):
            raise ReleaseError("Required service credentials are missing or invalid.")

    def migrate(self):
        self.require_secrets(["POSTGRES_PASSWORD", "API_DATABASE_PASSWORD", "AUTH_DATABASE_PASSWORD",
                              "SUPPORT_DATABASE_PASSWORD", "WORKER_DATABASE_PASSWORD"])
        if self.args.environment == "production":
            if not self.args.backup_receipt:
                raise ReleaseError("Production migration requires a successful backup receipt.")
            receipt = json.loads(Path(self.args.backup_receipt).read_text())
            if (receipt.get("environment") != "production" or receipt.get("image") != self.args.image
                    or receipt.get("status") != "SUCCESSFUL"
                    or not isinstance(receipt.get("backupId"), str)
                    or not re.fullmatch(r"gs://[a-z0-9][a-z0-9._-]+/[^#\s]+#[0-9]+", receipt["backupId"])
                    or receipt.get("project") != self.config.get("PROJECT_ID")
                    or receipt.get("instance") != self.config.get("DATABASE_INSTANCE")
                    or not isinstance(receipt.get("completedAt"), (int, float))
                    or not 0 <= time.time() - receipt["completedAt"] <= 3600):
                raise ReleaseError("Backup receipt is invalid or older than one hour.")
        # Adopt the existing database container without applying Compose config
        # differences to it. Database restarts/upgrades are separate operations.
        self.compose("--profile", "local-db", "up", "-d", "--no-recreate", "--wait", "database")
        self.compose("run", "--rm", "--no-deps", "-T", "migrator")
        self.compose("run", "--rm", "--no-deps", "-T", "database-role-initializer")

    def snapshot(self, retain_previous=False):
        transient = {"pending", "pendingWorkerChanged", "pendingCandidateSlot"}
        if not retain_previous:
            transient.add("previous")
        return {key: value for key, value in self.state.items() if key not in transient}

    def render_site(self, slot):
        # Serving deployments require a valid certificate; ACME bootstrap is a
        # separate explicit command and cannot downgrade an existing HTTPS site.
        certificate = Path(self.args.certificate_root) / self.domain / "fullchain.pem"
        if not certificate.is_file():
            raise ReleaseError("TLS must be provisioned before serving release activation.")
        template = (self.root / "deploy/gcp-vm/nginx-https.conf").read_text()
        return render_nginx(template, self.domain, slot)

    def switch_site(self, text):
        atomic_write(self.site, text, 0o644)
        self.enabled_site.parent.mkdir(parents=True, exist_ok=True)
        if not self.enabled_site.is_symlink():
            if self.enabled_site.exists():
                raise ReleaseError("Nginx activation path must be a symlink.")
            self.enabled_site.symlink_to(self.site)
        elif self.enabled_site.resolve() != self.site.resolve():
            raise ReleaseError("Nginx activation symlink points to an unexpected site.")
        self.command("nginx", "-t")
        self.command("systemctl", "reload", "nginx")

    def restore(self, previous, restart_worker=True, journal_worker=False):
        # Old API/auth remain running throughout deploy and drain. Reload only
        # after writing the exact prior known-good config back into place.
        if previous.get("nginxConfig"):
            self.switch_site(previous["nginxConfig"])
        elif "nginxConfig" in previous:
            self.site.unlink(missing_ok=True)
            self.enabled_site.unlink(missing_ok=True)
            self.command("nginx", "-t")
            self.command("systemctl", "reload", "nginx")
        if restart_worker:
            if journal_worker:
                self.save({**self.state, "pendingWorkerChanged": True})
            self.compose("stop", "--timeout", "45", "worker")
            if previous.get("workerImage"):
                self.compose("up", "-d", "--no-deps", "worker", image=previous["workerImage"])

    def recover_pending(self):
        previous = self.state["pending"]
        self.restore(previous, restart_worker=self.state.get("pendingWorkerChanged", False))
        retained = previous.get("previous", {}).get("api")
        if retained and retained["slot"] == self.state.get("pendingCandidateSlot"):
            # The inactive slot may have held the earlier rollback release. Put
            # it back after current Nginx requests drain, including after SIGKILL.
            self.sleep(65)
            self.compose("up", "-d", "--no-deps", f"api-{retained['slot']}",
                         f"auth-{retained['slot']}", image=retained["image"])
            expected = self.environment["RELEASE_IMAGE_DIGEST"]
            try:
                self.environment["RELEASE_IMAGE_DIGEST"] = retained["image"].partition("@")[2]
                api, auth = PORTS[retained["slot"]]
                self.ready(f"http://127.0.0.1:{api}")
                self.ready(f"http://127.0.0.1:{auth}")
            finally:
                self.environment["RELEASE_IMAGE_DIGEST"] = expected
        # Only clear the journal once both serving and retained slots recover.
        self.save(previous)

    def adopt_legacy(self):
        if self.state or not self.site.exists():
            return
        text = self.site.read_text()
        if "127.0.0.1:3000" not in text or "127.0.0.1:3001" not in text:
            raise ReleaseError("Unknown existing Nginx config: explicit state adoption required.")
        # Do not recreate these containers. Their immutable local image IDs are
        # recorded only for rollback; new releases always require a registry digest.
        worker = self.compose("ps", "-q", "worker").strip()
        worker_image = self.command("docker", "inspect", "--format", "{{.Image}}", worker).strip() if worker else None
        self.save({"api": {"slot": "legacy", "image": None}, "nginxConfig": text,
                   "workerImage": worker_image, "environment": self.args.environment})

    def deploy(self):
        self.pull(self.args.image)
        self.adopt_legacy()
        if "pending" in self.state:
            self.recover_pending()
        if not self.args.skip_migrations:
            self.migrate()
        self.require_secrets(["SEARCH_ACCESS_TOKEN_SIGNING_KEY", "API_DATABASE_PASSWORD",
                              "AUTH_DATABASE_PASSWORD", "SUPPORT_DATABASE_PASSWORD",
                              "SNAPSHOT_SIGNING_KEY", "WORKER_DATABASE_PASSWORD"])
        for key in ("ALLOW_LEGACY_STAGING_BEARER", "APP_ATTEST_ALLOW_DEVELOPMENT"):
            if self.environment.get(key, "false") not in ("true", "false"):
                raise ReleaseError("Authentication compatibility flags must be explicit booleans.")
        if self.args.environment == "production" and self.environment.get("APP_ATTEST_ALLOW_DEVELOPMENT", "false") != "false":
            raise ReleaseError("Production cannot enable development App Attest.")
        # The existing production legacy bearer remains operator-managed under
        # ADR 0015. Environment separation must not revoke installed clients.
        old = self.snapshot(retain_previous=True)
        if "nginxConfig" not in old:
            old["nginxConfig"] = self.site.read_text() if self.site.exists() else None
        self.save({**self.state, "pending": old})
        try:
            token = self.token()
            updated = {**old, "environment": self.args.environment, "image": self.args.image}
            slot = "green" if old.get("api", {}).get("slot") == "blue" else "blue"
            self.save({**self.state, "pendingCandidateSlot": slot})
            self.compose("up", "-d", "--no-deps", f"api-{slot}", f"auth-{slot}")
            api, auth = PORTS[slot]
            self.ready(f"http://127.0.0.1:{api}")
            self.ready(f"http://127.0.0.1:{auth}")
            self.search_gate(f"http://127.0.0.1:{api}", token)
            configuration = self.render_site(slot)
            self.switch_site(configuration)
            self.ready("https://local-proxy")
            self.ready("https://local-proxy", "/ready/auth")
            self.search_gate("https://local-proxy", token)
            if not self.args.skip_public_probe:
                self.public_gate(token)
            # Nginx reload preserves in-flight requests in old workers. Keep
            # both old application containers for rollback even after drain.
            self.sleep(65)
            updated.update(api={"slot": slot, "image": self.args.image}, nginxConfig=configuration)
            self.compose("run", "--rm", "--no-deps", "-T", "cache-initializer")
            self.save({**self.state, "pendingWorkerChanged": True})
            # Compose stop waits for the prior container to exit before returning.
            self.compose("stop", "--timeout", "45", "worker")
            self.compose("up", "-d", "--no-deps", "worker")
            container = self.compose("ps", "-q", "worker").strip()
            self.sleep(3)
            running = self.command("docker", "inspect", "--format", "{{.State.Running}} {{.RestartCount}}", container).strip()
            if running != "true 0":
                raise ReleaseError("New worker did not remain running.")
            updated["workerImage"] = self.args.image
            self.save({**updated, "previous": {key: value for key, value in old.items() if key != "previous"}})
        except BaseException:
            # No worker restart before its own cutover, including API gate errors.
            self.recover_pending()
            raise

    def rollback(self):
        if "pending" in self.state:
            self.recover_pending()
        previous = self.state.get("previous")
        if not previous:
            raise ReleaseError("No retained release is available for rollback.")
        current = self.snapshot()
        self.save({**self.state, "pending": self.snapshot(retain_previous=True)})
        try:
            api = previous.get("api")
            if api:
                port, auth_port = PORTS[api["slot"]]
                if api["slot"] == "legacy":
                    self.request(f"http://127.0.0.1:{port}/health")
                    self.request(f"http://127.0.0.1:{auth_port}/health")
                else:
                    self.compose("up", "-d", "--no-deps", f"api-{api['slot']}", f"auth-{api['slot']}", image=api["image"])
                    self.environment["RELEASE_IMAGE_DIGEST"] = api["image"].partition("@")[2]
                    self.ready(f"http://127.0.0.1:{port}")
                    self.ready(f"http://127.0.0.1:{auth_port}")
                self.search_gate(f"http://127.0.0.1:{port}", self.token())
            self.restore(previous, journal_worker=True)
            self.save({**previous, "previous": current})
        except BaseException:
            self.recover_pending()
            raise


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("action", choices=["deploy", "migrate", "rollback", "mint-token", "verify-public"])
    result.add_argument("--environment", required=True, choices=DOMAINS)
    result.add_argument("--image")
    result.add_argument("--skip-migrations", action="store_true")
    result.add_argument("--backup-receipt")
    result.add_argument("--skip-public-probe", action="store_true", help="Initial DNS/bootstrap only; local TLS proxy gates remain mandatory.")
    result.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    result.add_argument("--host-config", default="/etc/nextstop/release.env")
    result.add_argument("--secrets", default="/etc/nextstop/backend.env")
    result.add_argument("--state-directory", default="/var/lib/nextstop/releases")
    result.add_argument("--nginx-site", default="/etc/nginx/sites-available/nextstop")
    result.add_argument("--nginx-enabled-site", default="/etc/nginx/sites-enabled/nextstop")
    result.add_argument("--certificate-root", default="/etc/letsencrypt/live")
    return result


def main():
    args = parser().parse_args()
    try:
        release = Release(args)
        release.state_dir.mkdir(parents=True, exist_ok=True)
        if not args.image:
            active_image = release.state.get("image") or release.state.get("workerImage") or ""
            release.environment["BACKEND_IMAGE"] = active_image
            release.environment["RELEASE_IMAGE_DIGEST"] = active_image.partition("@")[2]
        if args.action == "mint-token":
            image = release.state.get("image") or release.state.get("workerImage")
            if not image or not DIGEST.fullmatch(image):
                raise ReleaseError("No active immutable release is configured.")
            release.environment["BACKEND_IMAGE"] = image
            sys.stdout.write(release.compose("run", "--rm", "--no-deps", "-T", "simulator-token-mint"))
        else:
            with (release.state_dir / "release.lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if args.action == "migrate":
                    release.pull(args.image)
                    release.migrate()
                elif args.action == "verify-public":
                    release.pull(args.image)
                    token = release.token()
                    # Multiple requests catch misrouted or stale backends during
                    # promotion. Local per-node TLS gates are the primary proof.
                    for _ in range(4):
                        release.public_gate(token)
                        release.sleep(1)
                else:
                    def interrupted(_signal, _frame):
                        raise ReleaseError("Release interrupted.")
                    signal.signal(signal.SIGTERM, interrupted)
                    signal.signal(signal.SIGHUP, interrupted)
                    getattr(release, args.action)()
                    print(json.dumps({"event": "release-completed", "environment": args.environment, "action": args.action}))
    except (ReleaseError, OSError, ValueError) as error:
        # Values from subprocesses, JSON, URLs and exceptions are deliberately not
        # interpolated here: they may contain deployment credentials.
        print("Release failed safely; inspect host state and retry or rollback.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
