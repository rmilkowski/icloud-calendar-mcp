"""Explicit macOS LaunchServices lifecycle tests; synthetic data only.

Run with CALENDAR_MCP_TEST_LAUNCH_SERVICES=1 after packaging the current app.
Normal unattended tests do not open an application or request TCC access.
"""

import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest

from calendar_mcp.launch_services import bundle_for_helper
from calendar_mcp.native import NativeBroker, NativeError
from calendar_mcp.security import private_directory

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper"
BINDING = hashlib.sha256(b"synthetic-launch-services-test").hexdigest()


class StatusShapeTests(unittest.TestCase):
    def test_eventkit_backend_cannot_disable_launch_services(self):
        with tempfile.TemporaryDirectory() as root:
            executable = Path(root) / "standalone"
            executable.write_text("#!/bin/sh\nexit 1\n")
            executable.chmod(0o700)
            with self.assertRaises(ValueError):
                NativeBroker(executable, root, "eventkit", _launch_services=False)

    def test_status_mapping_is_exact_and_has_no_native_dispatch_escape(self):
        broker = object.__new__(NativeBroker)
        response = {"backend_mode": "eventkit", "authorization_status": "full_access", "authorization_status_raw": 3, "pid": 42}
        calls = []
        broker.call = lambda op, args: (calls.append((op, args)) or response)
        self.assertEqual(broker.authorization_status(), response)
        self.assertEqual(calls, [("authorization_status", {})])
        for change in ({"authorization_status_raw": None}, {"authorization_status_raw": 2},
                       {"authorization_status": "not_applicable", "authorization_status_raw": 0}, {"pid": True}):
            original = dict(response)
            response.update(change)
            with self.subTest(change=change), self.assertRaises(NativeError):
                broker.authorization_status()
            response.clear()
            response.update(original)


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("CALENDAR_MCP_TEST_LAUNCH_SERVICES") == "1" and HELPER.is_file(),
                     "Explicit synthetic LaunchServices tests require the packaged current app")
class LaunchServicesLifecycleTests(unittest.TestCase):
    def broker(self, state):
        return NativeBroker(HELPER, state, "synthetic", timeout=8, credential_binding=BINDING, _launch_services=True)

    def assert_exited(self, pid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)  # Existence check only; no process is signalled.
            except ProcessLookupError:
                return
            time.sleep(0.05)
        self.fail("Native LaunchServices process did not exit")

    def test_clean_close_releases_native_process_and_state_lock(self):
        with tempfile.TemporaryDirectory() as root:
            state = private_directory(Path(root) / "native")
            broker = self.broker(state)
            pid = broker.startup_status["pid"]
            self.assertEqual(broker.startup_status["authorization_status"], "not_applicable")
            self.assertIsNone(broker.startup_status["authorization_status_raw"])
            broker.close()
            self.assert_exited(pid)
            again = self.broker(state)
            again.close()

    def test_gateway_abrupt_death_stops_app_and_releases_state_lock(self):
        with tempfile.TemporaryDirectory() as root:
            state = private_directory(Path(root) / "native")
            program = "import json,sys,time; from calendar_mcp.native import NativeBroker; b=NativeBroker(sys.argv[1],sys.argv[2],'synthetic',credential_binding=sys.argv[3],_launch_services=True); print(json.dumps(b.startup_status),flush=True); time.sleep(120)"
            gateway = subprocess.Popen([sys.executable, "-c", program, str(HELPER), str(state), BINDING],
                                       cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                self.assertTrue(select.select([gateway.stdout], [], [], 10)[0], "Gateway startup timed out")
                metadata = json.loads(gateway.stdout.readline())
                gateway.kill()
                gateway.wait(timeout=3)
                self.assert_exited(metadata["pid"])
                again = self.broker(state)
                again.close()
            finally:
                if gateway.poll() is None:
                    gateway.kill()
                    gateway.wait(timeout=3)
                gateway.stdout.close()

    def test_lifetime_eof_stops_native_when_response_fifo_is_backpressured(self):
        with tempfile.TemporaryDirectory() as root:
            state = private_directory(Path(root) / "native")
            broker = self.broker(state)
            pid = broker.startup_status["pid"]
            try:
                # Fill stdout without consuming it. Native dispatch can block
                # writing responses, but the lifetime watcher must still exit.
                wire = b'{"op":"authorization_status","arguments":{}}\n' * 2000
                view = memoryview(wire)
                deadline = time.monotonic() + 2
                while view and time.monotonic() < deadline:
                    try:
                        view = view[os.write(broker.process.stdin.fileno(), view):]
                    except BlockingIOError:
                        break
                self.assertTrue(select.select([broker.process.stdout], [], [], 3)[0])
                broker.process.lifetime.close()
                self.assert_exited(pid)
            finally:
                broker.close()
            again = self.broker(state)
            again.close()


if __name__ == "__main__":
    unittest.main()
