from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "allow_testflight_build", Path(__file__).with_name("allow-testflight-build.py")
)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class FakeCompose:
    def __init__(self, environment_file, runtime="1", fail_updates=(), wrong_updates=()):
        self.environment_file = environment_file
        self.runtime = runtime
        self.fail_updates = fail_updates
        self.wrong_updates = wrong_updates
        self.commands = []
        self.updates = 0

    def __call__(self, command):
        self.commands.append(command)
        if "exec" in command:
            return subprocess.CompletedProcess(command, 0, json.dumps(self.runtime), "")
        self.updates += 1
        if self.updates in self.fail_updates:
            return subprocess.CompletedProcess(command, 1, "", "secret-from-compose")
        if self.updates not in self.wrong_updates:
            self.runtime = ",".join(helper.updated_environment(
                self.environment_file.read_bytes(), "1"
            )[1])
        return subprocess.CompletedProcess(command, 0, "", "")


class AllowBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.environment = Path(self.directory.name) / "backend.env"
        self.original = (
            b"SECRET=do-not-print\r\nAPP_ATTEST_SUPPORTED_BUNDLE_VERSIONS=1\r\n"
            b"OTHER_SECRET=unchanged"
        )
        self.environment.write_bytes(self.original)
        self.compose = Path(self.directory.name) / "compose.yaml"

    def apply(self, build="10", runner=None):
        return helper.apply_build_versions(
            [build], self.environment, self.compose,
            runner if runner is not None else FakeCompose(self.environment),
        )

    def test_adds_build_preserving_bytes_and_recreates_only_auth(self):
        runner = FakeCompose(self.environment)
        self.assertTrue(self.apply(runner=runner))
        self.assertEqual(
            self.environment.read_bytes(), self.original.replace(b"=1\r\n", b"=1,10\r\n")
        )
        self.assertEqual(stat.S_IMODE(self.environment.stat().st_mode), 0o600)
        self.assertEqual(runner.runtime, "1,10")
        update = next(command for command in runner.commands if "up" in command)
        self.assertEqual(update[-7:], [
            "up", "-d", "--wait", "--wait-timeout", "120", "--no-deps", "auth-backend"
        ])
        self.assertNotIn("secret", str(runner.commands))
        self.assertFalse(list(self.environment.parent.glob(".nextstop-env-*")))

    def test_existing_build_is_a_noop_when_runtime_matches(self):
        runner = FakeCompose(self.environment)
        original_inode = self.environment.stat().st_ino
        self.assertFalse(self.apply("1", runner))
        self.assertEqual(runner.updates, 0)
        self.assertEqual(self.environment.stat().st_ino, original_inode)

    def test_batches_builds_in_one_update_preserving_existing_versions(self):
        runner = FakeCompose(self.environment)
        self.assertTrue(helper.apply_build_versions(
            ["10", "11", "1"], self.environment, self.compose, runner
        ))
        self.assertEqual(runner.runtime, "1,10,11")
        self.assertEqual(runner.updates, 1)

    def test_concurrent_updates_wait_for_lock_and_preserve_both_builds(self):
        first_applying = threading.Event()
        second_started = threading.Event()
        release_first = threading.Event()
        first_runner = FakeCompose(self.environment)
        second_runner = FakeCompose(self.environment)

        def blocked_runner(command):
            if "up" in command:
                first_applying.set()
                if not release_first.wait(5):
                    raise AssertionError("Test did not release the first update.")
            return first_runner(command)

        def second_update():
            second_started.set()
            return self.apply("11", second_runner)

        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.apply, "10", blocked_runner)
            try:
                self.assertTrue(first_applying.wait(5))
                second = pool.submit(second_update)
                self.assertTrue(second_started.wait(5))
                self.assertEqual(second_runner.commands, [])
            finally:
                release_first.set()
            self.assertTrue(first.result(timeout=5))
            self.assertTrue(second.result(timeout=5))
        self.assertEqual(second_runner.runtime, "1,10,11")

    def test_rejects_invalid_batch_without_side_effects(self):
        for versions in ([], "10", ["1", "1"], ["1,10"], [1]):
            with self.subTest(versions=versions):
                runner = FakeCompose(self.environment)
                with self.assertRaises(helper.AllowlistError):
                    helper.apply_build_versions(
                        versions, self.environment, self.compose, runner
                    )
                self.assertEqual(runner.commands, [])
                self.assertEqual(self.environment.read_bytes(), self.original)

    def test_existing_build_reapplies_a_stale_or_missing_runtime(self):
        for runtime in ("0", None):
            with self.subTest(runtime=runtime):
                runner = FakeCompose(self.environment, runtime=runtime)
                self.assertTrue(self.apply("1", runner))
                self.assertEqual(runner.updates, 1)
                self.assertEqual(self.environment.read_bytes(), self.original)

    def test_update_failure_restores_file_and_runtime_without_exposing_output(self):
        runner = FakeCompose(self.environment, fail_updates=(1,))
        with self.assertRaisesRegex(helper.AllowlistError, "restored and reapplied") as result:
            self.apply(runner=runner)
        self.assertNotIn("secret", str(result.exception))
        self.assertEqual(self.environment.read_bytes(), self.original)
        self.assertEqual(runner.runtime, "1")
        self.assertEqual(runner.updates, 2)

    def test_runtime_verification_failure_also_rolls_back(self):
        runner = FakeCompose(self.environment, wrong_updates=(1,))
        with self.assertRaisesRegex(helper.AllowlistError, "restored and reapplied"):
            self.apply(runner=runner)
        self.assertEqual(self.environment.read_bytes(), self.original)
        self.assertEqual(runner.updates, 2)

    def test_failed_recovery_has_actionable_sanitized_error(self):
        runner = FakeCompose(self.environment, fail_updates=(1, 2))
        with self.assertRaisesRegex(helper.AllowlistError, "recovery could not be verified"):
            self.apply(runner=runner)
        self.assertEqual(self.environment.read_bytes(), self.original)

    def test_external_environment_change_is_not_overwritten_during_rollback(self):
        external = self.original + b"\nEXTERNAL_CHANGE=preserve\n"

        def concurrent_writer(command):
            self.environment.write_bytes(external)
            return subprocess.CompletedProcess(command, 1, "", "private output")

        with self.assertRaisesRegex(helper.AllowlistError, "changed externally"):
            self.apply(runner=concurrent_writer)
        self.assertEqual(self.environment.read_bytes(), external)

    def test_rejects_invalid_supplied_versions_before_commands_or_writes(self):
        for build in ("", "1,10", "x y", "x\ny", "a" * 65, "ä", "$(id)"):
            with self.subTest(build=build):
                runner = FakeCompose(self.environment)
                with self.assertRaises(helper.AllowlistError):
                    self.apply(build, runner)
                self.assertEqual(runner.commands, [])
                self.assertEqual(self.environment.read_bytes(), self.original)

    def test_rejects_missing_duplicate_or_malformed_settings(self):
        setting = helper.SETTING.encode("ascii")
        for content in (
            b"SECRET=hidden\n", setting + b"=1\n" + setting + b"=10\n",
            b"export " + setting + b"=1\n", b" " + setting + b"=1\n",
            setting + b" =1\n", setting + b'=\"1\"\n', setting + b"=1,1\n",
            setting + b"=1, 10\n", setting + b"=\n",
        ):
            with self.subTest(content=content):
                self.environment.write_bytes(content)
                runner = FakeCompose(self.environment)
                with self.assertRaises(helper.AllowlistError):
                    self.apply(runner=runner)
                self.assertEqual(self.environment.read_bytes(), content)
                self.assertEqual(runner.commands, [])

    def test_capacity_preserves_all_supported_builds(self):
        builds = ",".join(str(value) for value in range(1, 33))
        content = (helper.SETTING + "=" + builds + "\n").encode("ascii")
        self.environment.write_bytes(content)
        runner = FakeCompose(self.environment, runtime=builds)
        self.assertFalse(self.apply("10", runner))
        with self.assertRaises(helper.AllowlistError):
            self.apply("33", runner)
        self.assertEqual(self.environment.read_bytes(), content)
        self.assertEqual(runner.updates, 0)

    def test_rejects_symlink_environment(self):
        target = self.environment.with_name("real.env")
        self.environment.rename(target)
        self.environment.symlink_to(target)
        with self.assertRaisesRegex(helper.AllowlistError, "regular file"):
            self.apply()
        self.assertEqual(target.read_bytes(), self.original)

    def test_command_runner_removes_allowlist_override_and_captures_output(self):
        with patch.dict(helper.os.environ, {helper.SETTING: "999"}), \
                patch.object(helper.subprocess, "run") as run:
            helper.run_command(["docker", "compose", "version"])
        options = run.call_args.kwargs
        self.assertNotIn(helper.SETTING, options["env"])
        self.assertTrue(options["capture_output"])
        self.assertEqual(options["timeout"], 5)

    def test_cli_is_quiet_when_existing_builds_are_verified(self):
        output = io.StringIO()
        with patch.object(helper, "apply_build_versions", return_value=False) as apply, \
                redirect_stdout(output):
            self.assertEqual(helper.main(["10"]), 0)
        apply.assert_called_once_with(["10"])
        self.assertEqual(output.getvalue(), "")

    def test_compose_and_recovery_fit_within_orchestrator_deadline(self):
        # Lock + initial lookup + apply/verify + rollback/verify stays below
        # the orchestrator's 330-second updater deadline, including recovery.
        maximum = (
            helper.LOCK_TIMEOUT_SECONDS + 3 * helper.RUNTIME_TIMEOUT_SECONDS
            + 2 * helper.COMPOSE_TIMEOUT_SECONDS
        )
        self.assertLessEqual(maximum, 300)
        with patch.object(helper.subprocess, "run") as run:
            helper.run_command(["docker", "compose", "up", "--wait-timeout", "120"])
        self.assertEqual(run.call_args.kwargs["timeout"], 140)

    def test_busy_lock_fails_without_environment_or_runtime_changes(self):
        runner = FakeCompose(self.environment)
        with patch.object(helper.fcntl, "flock", side_effect=BlockingIOError), \
                patch.object(helper, "LOCK_TIMEOUT_SECONDS", 0):
            with self.assertRaisesRegex(helper.AllowlistError, "update is in progress"):
                self.apply(runner=runner)
        self.assertEqual(self.environment.read_bytes(), self.original)
        self.assertEqual(runner.commands, [])

    def test_timeout_or_invalid_compose_output_is_sanitized_and_rolled_back(self):
        for failure in (
            subprocess.TimeoutExpired(["private-command"], 140, output="private-output"),
            UnicodeDecodeError("utf-8", b"private-\xff", 8, 9, "private-reason"),
        ):
            with self.subTest(failure=type(failure).__name__):
                fallback = FakeCompose(self.environment)
                failed = False

                def runner(command):
                    nonlocal failed
                    if not failed:
                        failed = True
                        raise failure
                    return fallback(command)

                with self.assertRaisesRegex(helper.AllowlistError, "restored and reapplied") as result:
                    self.apply(runner=runner)
                self.assertNotIn("private", str(result.exception))
                self.assertEqual(self.environment.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
