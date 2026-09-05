#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "ollama_status.py"
PYTHON = "/usr/bin/python3"


def load_helper():
    spec = importlib.util.spec_from_file_location("ollama_status", HELPER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RuntimeBoundaryTests(unittest.TestCase):
    def test_cli_does_not_resolve_curl_from_path(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            sentinel = directory / "path-curl-ran"
            fake_curl = directory / "curl"
            fake_curl.write_text(
                "#!/usr/bin/bash\n"
                f"touch {sentinel}\n"
                "printf '%s\\n' '{\"models\":[]}'\n"
            )
            fake_curl.chmod(0o755)
            environment = {
                "PATH": str(directory),
                "OLLAMA_HOST": "http://127.0.0.1:9",
            }

            completed = subprocess.run(
                [PYTHON, str(HELPER), "status"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
                timeout=8,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(sentinel.exists(), "PATH-injected curl executed")
            self.assertIn('"kind":"transport_error"', completed.stdout)

    def test_curl_receives_only_allowlisted_environment(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            environment_dump = directory / "environment.json"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import json, os\n"
                f"open({str(environment_dump)!r}, 'w').write(json.dumps(dict(os.environ)))\n"
                "print('{\"models\":[]}')\n"
            )
            fake_curl.chmod(0o755)

            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)), mock.patch.dict(
                os.environ,
                {"OLLAMA_HOST": "http://127.0.0.1:11434", "OLLAMA_STATUS_TEST_SECRET": "must-not-leak"},
                clear=False,
            ):
                result = helper.perform("status")

            self.assertTrue(result["ok"])
            child_environment = json.loads(environment_dump.read_text())
            self.assertNotIn("OLLAMA_STATUS_TEST_SECRET", child_environment)
            self.assertEqual(set(child_environment), {"LANG", "LC_ALL"})

    def test_hung_curl_is_killed_and_reaped_after_operation_deadline(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            pid_file = directory / "pid"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import os, signal, time\n"
                f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "time.sleep(0.6)\n"
            )
            fake_curl.chmod(0o755)

            started = time.monotonic()
            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)), mock.patch.object(
                helper, "OPERATION_TIMEOUT_SECONDS", 0.1, create=True
            ), mock.patch.object(helper, "TERM_GRACE_SECONDS", 0.05, create=True):
                result = helper.perform("status")
            elapsed = time.monotonic() - started

            self.assertEqual(result.get("kind"), "operation_timeout")
            self.assertLess(elapsed, 0.4)
            pid = int(pid_file.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_supervisor_term_cleans_up_its_curl_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            child_pid_file = directory / "child-pid"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import os, signal, time\n"
                f"open({str(child_pid_file)!r}, 'w').write(str(os.getpid()))\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "time.sleep(10)\n"
            )
            fake_curl.chmod(0o755)
            runner = directory / "runner.py"
            runner.write_text(
                "import sys\n"
                f"sys.path.insert(0, {str(ROOT)!r})\n"
                "import ollama_status\n"
                f"ollama_status.CURL_PATH = {str(fake_curl)!r}\n"
                "ollama_status.OPERATION_TIMEOUT_SECONDS = 20\n"
                "raise SystemExit(ollama_status.main(['ollama_status.py', 'status']))\n"
            )

            supervisor = subprocess.Popen([PYTHON, str(runner)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child_pid = None
            try:
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline and not child_pid_file.exists():
                    time.sleep(0.01)
                self.assertTrue(child_pid_file.exists(), "curl child did not start")
                child_pid = int(child_pid_file.read_text())

                supervisor.send_signal(signal.SIGTERM)
                supervisor.wait(timeout=1)
                deadline = time.monotonic() + 0.5
                while time.monotonic() < deadline:
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.01)
                else:
                    self.fail("curl process group survived supervisor TERM")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait()
                if child_pid is not None:
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_supervisor_sigkill_cannot_orphan_its_curl_child(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            child_pid_file = directory / "child-pid"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import os, time\n"
                f"open({str(child_pid_file)!r}, 'w').write(str(os.getpid()))\n"
                "time.sleep(10)\n"
            )
            fake_curl.chmod(0o755)
            runner = directory / "runner.py"
            runner.write_text(
                "import sys\n"
                f"sys.path.insert(0, {str(ROOT)!r})\n"
                "import ollama_status\n"
                f"ollama_status.CURL_PATH = {str(fake_curl)!r}\n"
                "ollama_status.OPERATION_TIMEOUT_SECONDS = 20\n"
                "raise SystemExit(ollama_status.main(['ollama_status.py', 'status']))\n"
            )

            supervisor = subprocess.Popen([PYTHON, str(runner)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child_pid = None
            child_group = None
            try:
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline and not child_pid_file.exists():
                    time.sleep(0.01)
                self.assertTrue(child_pid_file.exists(), "curl child did not start")
                child_pid = int(child_pid_file.read_text())
                child_group = os.getpgid(child_pid)

                supervisor.kill()
                supervisor.wait(timeout=1)
                deadline = time.monotonic() + 0.5
                while time.monotonic() < deadline:
                    status_path = Path(f"/proc/{child_pid}/stat")
                    if not status_path.exists() or status_path.read_text().split()[2] == "Z":
                        break
                    time.sleep(0.01)
                else:
                    self.fail("curl child survived abrupt supervisor death")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait()
                if child_group is not None:
                    try:
                        os.killpg(child_group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_deadline_kills_descendants_after_curl_parent_exits(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            child_pid_file = directory / "child-pid"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import os, signal, time\n"
                "child = os.fork()\n"
                "if child:\n"
                "    os._exit(0)\n"
                f"open({str(child_pid_file)!r}, 'w').write(str(os.getpid()))\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "time.sleep(10)\n"
            )
            fake_curl.chmod(0o755)
            child_pid = None
            child_group = None
            try:
                with mock.patch.object(helper, "CURL_PATH", str(fake_curl)), mock.patch.object(
                    helper, "OPERATION_TIMEOUT_SECONDS", 0.1
                ), mock.patch.object(helper, "TERM_GRACE_SECONDS", 0.05):
                    result = helper.perform("status")
                self.assertEqual(result.get("kind"), "operation_timeout")
                child_pid = int(child_pid_file.read_text())
                try:
                    child_group = os.getpgid(child_pid)
                except ProcessLookupError:
                    child_group = None
                if child_group is not None:
                    deadline = time.monotonic() + 0.5
                    while time.monotonic() < deadline:
                        status_path = Path(f"/proc/{child_pid}/stat")
                        if not status_path.exists() or status_path.read_text().split()[2] == "Z":
                            break
                        time.sleep(0.01)
                    else:
                        self.fail("curl descendant remained alive after deadline")
            finally:
                if child_group is not None:
                    try:
                        os.killpg(child_group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_curl_start_failure_returns_structured_error(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            non_executable = Path(directory) / "trusted-curl"
            non_executable.write_text("not executable")

            with mock.patch.object(helper, "CURL_PATH", str(non_executable)):
                result = helper.perform("status")

            self.assertEqual(result.get("kind"), "missing_dependency")

    def test_oversized_stdout_is_stopped_at_the_byte_ceiling(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            fake_curl = Path(directory) / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import sys\n"
                "sys.stdout.buffer.write(b'x' * 200000)\n"
            )
            fake_curl.chmod(0o755)

            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)):
                result = helper.perform("status")

            self.assertEqual(result.get("kind"), "response_too_large")

    def test_status_recovers_on_the_request_after_a_timeout(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "first-request"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import pathlib, signal, time\n"
                f"marker = pathlib.Path({str(marker)!r})\n"
                "if not marker.exists():\n"
                "    marker.touch()\n"
                "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "    time.sleep(1)\n"
                "else:\n"
                "    print('{\"models\":[]}')\n"
            )
            fake_curl.chmod(0o755)

            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)), mock.patch.object(
                helper, "OPERATION_TIMEOUT_SECONDS", 0.1
            ), mock.patch.object(helper, "TERM_GRACE_SECONDS", 0.05):
                timed_out = helper.perform("status")
                recovered = helper.perform("status")

            self.assertEqual(timed_out.get("kind"), "operation_timeout")
            self.assertEqual(recovered.get("ok"), True)
            self.assertEqual(recovered["data"]["models"], [])

    def test_status_returns_sanitized_bounded_model_data(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            fake_curl = Path(directory) / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "print('{\"models\":[{\"name\":\"safe-model\",\"size\":10,\"size_vram\":5,\"context_length\":4096}]}')\n"
            )
            fake_curl.chmod(0o755)

            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)):
                result = helper.perform("status")

            self.assertEqual(
                result,
                {
                    "ok": True,
                    "operation": "status",
                    "data": {
                        "models": [
                            {
                                "name": "safe-model",
                                "action_id": "safe-model",
                                "size": 10,
                                "size_vram": 5,
                                "context_length": 4096,
                            }
                        ],
                        "loadedModelCount": 1,
                        "aggregateVramBytes": 5.0,
                    },
                },
            )

    def test_version_rejects_overlong_untrusted_text(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            fake_curl = Path(directory) / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import json\n"
                "print(json.dumps({'version': 'x' * 81}))\n"
            )
            fake_curl.chmod(0o755)

            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)):
                result = helper.perform("version")

            self.assertEqual(result.get("kind"), "invalid_data")

    def test_unload_uses_validated_model_in_non_streaming_chat_payload(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            arguments_file = directory / "arguments.json"
            fake_curl = directory / "trusted-curl"
            fake_curl.write_text(
                "#!/usr/bin/python3\n"
                "import json, sys\n"
                f"open({str(arguments_file)!r}, 'w').write(json.dumps(sys.argv[1:]))\n"
                "print('{\"done\":true}')\n"
            )
            fake_curl.chmod(0o755)

            with mock.patch.object(helper, "CURL_PATH", str(fake_curl)):
                result = helper.perform("unload", "safe-model")

            self.assertEqual(result, {"ok": True, "operation": "unload", "data": {"done": True}})
            arguments = json.loads(arguments_file.read_text())
            self.assertEqual(arguments[-1], "http://127.0.0.1:11434/api/chat")
            payload = json.loads(arguments[arguments.index("--data") + 1])
            self.assertEqual(
                payload,
                {"model": "safe-model", "messages": [], "keep_alive": 0, "stream": False},
            )

    def test_service_uses_absolute_supervisor_with_allowlisted_environment(self):
        source = (ROOT / "Service.qml").read_text()

        self.assertNotIn('["bash",', source)
        self.assertIn('readonly property string pythonPath: "/usr/bin/python3"', source)
        self.assertGreaterEqual(source.count("clearEnvironment: true"), 3)
        self.assertGreaterEqual(source.count("environment: root.processEnvironment"), 3)

    def test_service_enforces_term_then_kill_operation_deadlines(self):
        source = (ROOT / "Service.qml").read_text()

        for timer_id in ("statusDeadline", "versionDeadline", "actionDeadline"):
            self.assertIn(f"id: {timer_id}", source)
        for timer_id in ("statusKill", "versionKill", "actionKill"):
            self.assertIn(f"id: {timer_id}", source)
        self.assertIn("process.running = false", source)
        self.assertGreaterEqual(source.count("signal(9)"), 3)

    def test_service_deadlines_start_before_process_startup(self):
        source = (ROOT / "Service.qml").read_text()

        self.assertIn("statusDeadline.restart()\n    status.running = true", source)
        self.assertIn("versionDeadline.restart()\n      version.running = true", source)
        self.assertIn("actionDeadline.restart()\n    action.running = true", source)
        self.assertNotIn("onStarted: statusDeadline.restart()", source)

    def test_refresh_supersedes_inflight_status_without_applying_stale_output(self):
        source = (ROOT / "Service.qml").read_text()

        self.assertIn("property bool pendingRefresh: false", source)
        self.assertIn("status.superseded = true", source)
        self.assertIn("if (!wasSuperseded)", source)
        self.assertIn("if (pendingRefresh)", source)

    def test_service_destruction_stops_timers_and_children(self):
        source = (ROOT / "Service.qml").read_text()

        self.assertIn("function shutdown()", source)
        self.assertIn("pollTimer.stop()", source)
        self.assertIn("destroyProcess(status)", source)
        self.assertIn("destroyProcess(version)", source)
        self.assertIn("destroyProcess(action)", source)
        self.assertIn("Component.onDestruction: root.shutdown()", source)

    def test_service_recovers_if_supervisor_fails_to_start(self):
        source = (ROOT / "Service.qml").read_text()

        self.assertGreaterEqual(source.count("onRunningChanged: if (!running && expected)"), 3)
        self.assertIn("function recoverStatusStart()", source)
        self.assertIn("function recoverVersionStart()", source)
        self.assertIn("function recoverActionStart()", source)

    def test_clipboard_helper_has_fixed_identity_minimal_environment_and_cleanup(self):
        source = (ROOT / "Panel.qml").read_text()

        self.assertIn('["/usr/bin/wl-copy", "--foreground",', source)
        self.assertIn("clearEnvironment: true", source)
        self.assertIn("environment: root.clipboardEnvironment", source)
        self.assertNotIn("stdout: StdioCollector", source)
        self.assertNotIn("stderr: StdioCollector", source)
        self.assertIn("id: copyKill", source)
        self.assertIn("copyProcess.running = false", source)
        self.assertIn("copyProcess.signal(9)", source)
        self.assertIn("Component.onDestruction: root.shutdownClipboard()", source)

    def test_runtime_path_uses_bounded_pipes_without_temporary_files(self):
        helper_source = HELPER.read_text()

        self.assertFalse((ROOT / "status.sh").exists())
        self.assertNotIn("tempfile", helper_source)
        self.assertNotIn("mktemp", helper_source)
        self.assertNotIn("rmtree", helper_source)
        self.assertIn("stdout=subprocess.PIPE", helper_source)

    def test_supervisor_result_is_bounded_before_qml_collection(self):
        helper = load_helper()
        self.assertTrue(hasattr(helper, "encode_result"), "bounded result encoder is missing")
        encoded = helper.encode_result(
            {"ok": True, "operation": "status", "data": {"models": ["x" * 100000]}}
        )

        self.assertLessEqual(len(encoded), helper.MAX_RESULT_BYTES)
        self.assertEqual(json.loads(encoded)["kind"], "internal_error")


if __name__ == "__main__":
    unittest.main()
