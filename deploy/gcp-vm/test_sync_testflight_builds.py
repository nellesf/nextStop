from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("sync-testflight-builds.py")
SPEC = importlib.util.spec_from_file_location("sync_testflight_builds", SCRIPT)
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)


class SequenceRunner:
    def __init__(self, *results):
        self.results = list(results)
        self.calls = []

    def __call__(self, command, **options):
        self.calls.append((command, options))
        result = self.results.pop(0)
        if isinstance(result, BaseException):
            raise result
        code, output, error = result
        return subprocess.CompletedProcess(command, code, output, error)


class SynchronizeBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path("/opt/nextstop/operations/testflight-sync")

    def test_reads_before_one_batched_update_and_preserves_argument_boundaries(self):
        runner = SequenceRunner(
            (0, '["10","11","--help"]', ""),
            (0, "Build allowlist applied and verified.\n", ""),
        )
        output = io.StringIO()
        with redirect_stdout(output):
            sync.synchronize(self.directory, runner)
        self.assertEqual(len(runner.calls), 2)
        reader, read_options = runner.calls[0]
        updater, update_options = runner.calls[1]
        self.assertEqual(reader[1], str(self.directory / "read-testflight-builds.py"))
        self.assertEqual(updater[1:], [
            str(self.directory / "allow-testflight-build.py"), "--", "10", "11", "--help",
        ])
        self.assertEqual(read_options["timeout"], 150)
        self.assertEqual(update_options["timeout"], 330)
        self.assertTrue(read_options["capture_output"])
        self.assertTrue(update_options["capture_output"])
        self.assertNotIn("shell", read_options)
        self.assertNotIn("shell", update_options)
        self.assertEqual(output.getvalue(), "Build allowlist applied and verified.\n")

    def test_empty_eligible_build_list_does_not_touch_server_or_log(self):
        runner = SequenceRunner((0, "[]", ""))
        output = io.StringIO()
        with redirect_stdout(output):
            sync.synchronize(self.directory, runner)
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(output.getvalue(), "")

    def test_unchanged_permissions_are_quiet(self):
        runner = SequenceRunner((0, '["10"]', ""), (0, "", ""))
        output = io.StringIO()
        with redirect_stdout(output):
            sync.synchronize(self.directory, runner)
        self.assertEqual(output.getvalue(), "")

    def test_reader_failure_never_calls_updater_or_exposes_child_output(self):
        runner = SequenceRunner((1, "private-reader-output", "private-reader-error"))
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaisesRegex(
            RuntimeError, "existing build permissions were preserved"
        ) as failure:
            sync.synchronize(self.directory, runner)
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("private", str(failure.exception))

    def test_invalid_reader_payload_never_calls_updater(self):
        for payload in (
            "{private-not-json", "null", '"10"', '{"build":"10"}', '[10]',
            '["10","10"]', '["10,11"]', '["a b"]', '[""]',
            json.dumps(["a" * 65]), json.dumps([str(value) for value in range(33)]),
        ):
            with self.subTest(payload=payload):
                runner = SequenceRunner((0, payload, "private-output"))
                with self.assertRaises((RuntimeError, ValueError)):
                    sync.synchronize(self.directory, runner)
                self.assertEqual(len(runner.calls), 1)

    def test_updater_failure_does_not_report_success_or_expose_child_output(self):
        runner = SequenceRunner(
            (0, '["10"]', ""), (1, "private-compose-output", "private-compose-error")
        )
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaisesRegex(
            RuntimeError, "inspect the authentication service"
        ) as failure:
            sync.synchronize(self.directory, runner)
        self.assertEqual(len(runner.calls), 2)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("private", str(failure.exception))

    def assert_cli_failure_is_sanitized(self, runner):
        output = io.StringIO()
        error = io.StringIO()
        with patch.object(subprocess, "run", runner), redirect_stdout(output), \
                redirect_stderr(error), self.assertRaises(SystemExit) as failure:
            runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertEqual(failure.exception.code, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertTrue(error.getvalue().strip())
        self.assertNotIn("private", error.getvalue())
        self.assertNotIn("Traceback", error.getvalue())

    def test_reader_timeout_is_sanitized_at_cli_boundary(self):
        runner = SequenceRunner(subprocess.TimeoutExpired(
            ["private-reader-command"], 150, output="private-response"
        ))
        self.assert_cli_failure_is_sanitized(runner)
        self.assertEqual(len(runner.calls), 1)

    def test_updater_timeout_is_sanitized_at_cli_boundary(self):
        runner = SequenceRunner(
            (0, '["10"]', ""), subprocess.TimeoutExpired(
                ["private-updater-command"], 330, output="private-response"
            ),
        )
        self.assert_cli_failure_is_sanitized(runner)
        self.assertEqual(len(runner.calls), 2)

    def test_os_error_is_sanitized_at_cli_boundary(self):
        self.assert_cli_failure_is_sanitized(SequenceRunner(OSError("private-file-path")))

    def test_json_error_is_sanitized_at_cli_boundary(self):
        self.assert_cli_failure_is_sanitized(SequenceRunner((0, "private-invalid-json", "")))


if __name__ == "__main__":
    unittest.main()
