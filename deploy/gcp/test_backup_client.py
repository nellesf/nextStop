"""Exercise the isolated backup tools without Docker, credentials or live data."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("backup_client", Path(__file__).with_name("backup.py"))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
CLIENT = {"image": "europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/postgres-client@sha256:" + "1" * 64,
          "configDigest": "sha256:" + "2" * 64, "sourceCommit": "3" * 40,
          "version": "17.11", "platform": "linux/amd64"}


def remote_scope():
    scope = {}
    exec(compile(backup.REMOTE_DUMP, "<backup-tools>", "exec"), scope)
    return scope


def image_metadata():
    return {"Id": CLIENT["configDigest"], "RepoDigests": [CLIENT["image"]], "Os": "linux", "Architecture": "amd64",
            "Config": {"User": "65532:65532", "Cmd": ["psql", "--version"], "WorkingDir": "/tmp",
                       "Labels": {"org.opencontainers.image.revision": CLIENT["sourceCommit"],
                                  "org.opencontainers.image.version": "17.11", "tech.nextstop.image-purpose": "postgres-client",
                                  "org.opencontainers.image.base.digest": "sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4"}}}


class BackupClientTests(unittest.TestCase):
    def test_metadata_is_required_and_cannot_select_mutable_or_unreviewed_tools(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "image.json"
            with patch.object(backup, "CLIENT_METADATA", path):
                with self.assertRaises(FileNotFoundError):
                    backup.client_configuration()
                path.write_text(json.dumps(CLIENT))
                self.assertEqual(backup.client_configuration(), CLIENT)
                for change in ({"image": CLIENT["image"].split("@")[0] + ":latest"},
                               {"image": CLIENT["image"].replace("/postgres-client@", "/backend@")},
                               {"sourceCommit": "main"}, {"configDigest": "sha256:wrong"},
                               {"version": "17.5"}, {"platform": "linux/arm64"}):
                    path.write_text(json.dumps({**CLIENT, **change}))
                    with self.subTest(change=change), self.assertRaises(ValueError):
                        backup.client_configuration()

    def test_client_identity_accepts_only_the_reviewed_single_platform_tool_image(self):
        scope = remote_scope()
        manifest = CLIENT["image"].rsplit("@", 1)[1]
        for form in ("classic", "docker-manifest", "oci-manifest"):
            value = image_metadata()
            if form != "classic":
                value["Id"] = manifest
                value["Descriptor"] = {"digest": manifest, "mediaType": (
                    "application/vnd.oci.image.manifest.v1+json" if form == "oci-manifest"
                    else "application/vnd.docker.distribution.manifest.v2+json")}
            scope["execute"] = lambda args, **kwargs: json.dumps([value]).encode()
            scope["verify_client"](CLIENT)
            mutations = [{"Id": "sha256:" + "9" * 64}, {"RepoDigests": []}, {"Os": "windows"},
                         {"Architecture": "arm64"}, {"Descriptor": {"digest": manifest, "mediaType": "application/vnd.oci.image.index.v1+json"}},
                         {"Descriptor": {"digest": "sha256:" + "0" * 64, "mediaType": "application/vnd.oci.image.manifest.v1+json"}}]
            for change in mutations:
                invalid = {**copy.deepcopy(value), **change}
                scope["execute"] = lambda args, **kwargs: json.dumps([invalid]).encode()
                with self.subTest(form=form, change=change), self.assertRaises(RuntimeError):
                    scope["verify_client"](CLIENT)
        for change in ({"User": "root"}, {"Volumes": {"/var/lib/postgresql/data": {}}},
                       {"Entrypoint": ["docker-entrypoint.sh"]}, {"Cmd": ["postgres"]},
                       {"ExposedPorts": {"5432/tcp": {}}}, {"WorkingDir": "/"},
                       {"Labels": {}}):
            invalid = image_metadata()
            invalid["Config"].update(change)
            scope["execute"] = lambda args, **kwargs: json.dumps([invalid]).encode()
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                scope["verify_client"](CLIENT)

    def test_pgpass_escaping_and_invalid_host_credentials(self):
        scope = remote_scope()
        def source(value, *, mode=0o600, owner=0):
            return SimpleNamespace(stat=lambda: SimpleNamespace(st_uid=owner, st_mode=mode),
                                   read_bytes=lambda: value.encode())
        credential = scope["password_line"](source("# fixture\nOTHER=value\nPOSTGRES_PASSWORD='a:b\\c$`'\n"))
        self.assertEqual(credential, b"127.0.0.1:5432:nextstop:nextstop_app:a\\:b\\\\c$`\n")
        invalid = ["", "POSTGRES_PASSWORD=\n", "POSTGRES_PASSWORD=one\nPOSTGRES_PASSWORD=two\n",
                   "POSTGRES_PASSWORD=a\rb\n", "POSTGRES_PASSWORD=a\x00b\n", "POSTGRES_PASSWORD='a\nb'\n",
                   "POSTGRES_PASSWORD='unclosed\n", "POSTGRES_PASSWORD=" + "x" * 1025]
        for value in invalid:
            with self.subTest(value=value[:40]), self.assertRaises(RuntimeError):
                scope["password_line"](source(value))
        for kwargs in ({"mode": 0o644}, {"owner": 501}):
            with self.subTest(kwargs=kwargs), self.assertRaises(RuntimeError):
                scope["password_line"](source("POSTGRES_PASSWORD=value\n", **kwargs))

    def exercise_dump(self, root, *, failure=None, cleanup_state=None):
        scope = remote_scope()
        records, cleanups, handlers, identity_reads = [], [], {}, []
        identity = {"id": "a" * 64, "image": "sha256:" + "b" * 64, "name": "/gcp-vm-database-1",
                    "started": "2026-10-26T09:25:00Z", "running": True, "health": "healthy",
                    "project": "gcp-vm", "service": "database"}
        if failure == "identity":
            identity["service"] = "other"
        credentials = b"127.0.0.1:5432:nextstop:nextstop_app:SYNTHETIC-PRIVATE\n"
        active_connected = False
        archive_path = Path(root) / "archive.dump"
        class Archive:
            parent = SimpleNamespace(name=".release-backup-" + "c" * 32)
            def __str__(self): return "/srv/nextstop/" + self.parent.name + "/archive.dump"
            def __fspath__(self): return str(archive_path)
            def open(self, mode): return archive_path.open(mode)
        def execute(args, **kwargs):
            nonlocal active_connected
            if args[:3] == ["docker", "image", "inspect"]:
                return json.dumps([image_metadata()]).encode()
            if args[:2] == ["docker", "inspect"]:
                identity_reads.append(dict(identity))
                return json.dumps(identity).encode()
            if args[:2] == ["docker", "ps"]:
                self.assertEqual(args, ["docker", "ps", "-a", "-q", "--filter", "name=^/nextstop-backup-client-" + "c" * 32 + "$"])
                if active_connected and cleanup_state == "unavailable":
                    raise RuntimeError("Synthetic daemon error with PRIVATE output")
                return b"remaining-client" if active_connected and cleanup_state == "present" else b""
            self.assertEqual(args[:2], ["docker", "run"])
            records.append((args, kwargs))
            active_connected = "--network=container:" + "a" * 64 in args
            entrypoint = next(item.split("=", 1)[1] for item in args if item.startswith("--entrypoint="))
            tool = args[args.index("--") + 1].rsplit("/", 1)[1] if entrypoint == "/bin/sh" else entrypoint.rsplit("/", 1)[1]
            if "--version" in args:
                return (tool + " (PostgreSQL) " + ("17.5" if failure == "version" else "17.11") + "\n").encode()
            if tool == "psql":
                return json.dumps({"database": "wrong" if failure == "database" else "nextstop",
                                   "version": 160000 if failure == "major" else 170005, "bytes": 100}).encode()
            if tool == "pg_dump":
                if failure in ("restart", "dump-restart"):
                    identity["started"] = "2026-10-26T10:00:00Z"
                if failure in ("dump", "dump-restart"):
                    raise RuntimeError("Synthetic dump failure")
                if failure == "timeout":
                    raise subprocess.TimeoutExpired(args, 1500)
                if failure == "hangup":
                    handlers[signal.SIGHUP](signal.SIGHUP, None)
                kwargs["stdout"].write(b"PGDMP synthetic archive")
                return None
            self.assertEqual(tool, "pg_restore")
            self.assertEqual(kwargs["stdin"].read(), b"PGDMP synthetic archive")
            if failure == "list":
                raise RuntimeError("Synthetic list failure")
            return None
        def cleanup(args, **kwargs):
            cleanups.append(args)
            return SimpleNamespace(returncode=1 if cleanup_state else 0)
        scope.update(execute=execute, password_line=lambda path: credentials,
                     signal=SimpleNamespace(SIGTERM=signal.SIGTERM, SIGHUP=signal.SIGHUP, SIG_IGN=signal.SIG_IGN,
                                            signal=lambda signum, handler: handlers.update({signum: handler})),
                     subprocess=SimpleNamespace(PIPE=subprocess.PIPE, DEVNULL=subprocess.DEVNULL, run=cleanup,
                                                TimeoutExpired=subprocess.TimeoutExpired),
                     shutil=SimpleNamespace(disk_usage=lambda path: SimpleNamespace(free=0 if failure == "space" else 20 * 1024**3)),
                     os=SimpleNamespace(O_CREAT=os.O_CREAT, O_EXCL=os.O_EXCL, O_WRONLY=os.O_WRONLY,
                                        O_NOFOLLOW=os.O_NOFOLLOW, open=os.open, fdopen=os.fdopen, chown=lambda *args: None))
        if failure or cleanup_state in ("present", "unavailable"):
            with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)) as error:
                scope["main"](CLIENT, Archive(), 501, 20)
            if cleanup_state in ("present", "unavailable"):
                self.assertEqual(str(error.exception), "The private backup client could not be confirmed removed.")
        else:
            scope["main"](CLIENT, Archive(), 501, 20)
        if failure == 'hangup':
            self.assertEqual(handlers[signal.SIGHUP], signal.SIG_IGN)
            self.assertEqual(handlers[signal.SIGTERM], signal.SIG_IGN)
        return records, cleanups, identity_reads, archive_path

    def test_dump_uses_only_isolated_clients_and_stdin_secret_with_offline_catalogue_check(self):
        with tempfile.TemporaryDirectory() as root:
            records, cleanups, reads, archive = self.exercise_dump(root)
            self.assertEqual(archive.read_bytes(), b"PGDMP synthetic archive")
            self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(records), 6)
        self.assertEqual(len(cleanups), len(records))
        self.assertEqual(len(reads), 6)
        connected = []
        for args, kwargs in records:
            for flag in ("--pull=never", "--user=65532:65532", "--read-only", "--cap-drop=ALL",
                         "--security-opt=no-new-privileges", "--memory=512m", "--memory-swap=512m",
                         "--cpus=1", "--pids-limit=64", "--log-driver=none"):
                self.assertIn(flag, args)
            self.assertIn(CLIENT["image"], args)
            self.assertFalse(any(item in ("-v", "--volume", "--mount", "-e", "--env", "--env-file") or item.startswith(("--volume=", "--mount=", "--env=")) for item in args))
            self.assertNotIn("SYNTHETIC-PRIVATE", " ".join(args))
            if "--network=container:" + "a" * 64 in args:
                connected.append(args)
                self.assertIn("SYNTHETIC-PRIVATE", kwargs["input"].decode())
                self.assertIn("--host=127.0.0.1", args)
                self.assertIn("--port=5432", args)
                self.assertIn("--no-password", args)
                self.assertTrue(any(item.startswith("--tmpfs=/run/secrets:") for item in args))
            else:
                self.assertIn("--network=none", args)
                self.assertIsNone(kwargs["input"])
        self.assertEqual(len(connected), 2)
        self.assertIn("--exclude-table-data=nextstop.user_error_reports", connected[1])
        self.assertEqual(records[-1][0][-1], "--list")
        self.assertTrue(all(args == ["docker", "rm", "--force", "nextstop-backup-client-" + "c" * 32] for args in cleanups))

    def test_drift_errors_timeouts_and_disconnects_fail_closed_and_remove_own_client(self):
        for failure in ("identity", "version", "database", "major", "space", "restart", "dump", "dump-restart", "timeout", "hangup", "list"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as root:
                records, cleanups, reads, _ = self.exercise_dump(root, failure=failure)
                self.assertEqual(len(cleanups), len(records))
                if failure in ("restart", "dump-restart", "dump", "timeout", "hangup"):
                    self.assertGreaterEqual(len(reads), 5)
                if failure in ("identity", "version", "database", "major", "space"):
                    self.assertFalse(any("-Fc" in args for args, _ in records))

    def test_subprocess_never_returns_database_errors_or_private_stderr(self):
        scope = remote_scope()
        with patch.object(scope["subprocess"], "run", return_value=SimpleNamespace(returncode=1, stdout=b"PRIVATE", stderr=b"PRIVATE")) as run:
            with self.assertRaises(RuntimeError) as error:
                scope["execute"](["docker", "run"], input=b"PRIVATE")
            self.assertNotIn("PRIVATE", str(error.exception))
            self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_cleanup_requires_confirmed_absence_and_always_rechecks_database(self):
        for state in ("present", "unavailable", "absent"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as root:
                records, cleanups, reads, _ = self.exercise_dump(root, cleanup_state=state)
                self.assertEqual(len(records), len(cleanups))
                self.assertEqual(len(reads), 6 if state == "absent" else 3)


if __name__ == "__main__":
    unittest.main()
