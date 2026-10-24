"""One resident native broker. Failed/uncertain calls are never retried."""

import json
import os
from pathlib import Path
import select
import subprocess
import threading
import time

from .launch_services import LaunchServicesProcess

MAX_NATIVE = 4 * 1024 * 1024
RECOVERY_CAPABILITIES = {"version": 1, "storage_version": 2, "recovery": True,
                         "detail_retention": True, "local_ui": True, "max_selection": 25}
ALERTS_CAPABILITIES = {"version": 1, "alerts": True, "max_alerts": 10, "preview_version": 2}
RECURRENCE_CAPABILITIES = {"version": 1, "recurrence": True, "preview_version": 3,
                           "create_series": True, "modify_occurrence": True,
                           "delete_occurrence": True, "future_scope": False,
                           "series_modify_delete": False, "delete_recovery": "standalone_copy",
                           "max_count": 1000}


class NativeError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class NativeBroker:
    def __init__(self, helper, state, backend="synthetic", timeout=45, credential_binding=None, *, _launch_services=None):
        helper = Path(helper).expanduser().resolve(strict=True)
        if not helper.is_file() or not os.access(helper, os.X_OK):
            raise ValueError("Native helper must be an executable file")
        self.timeout = timeout
        self.lock = threading.Lock()
        self.failed = False
        command = [str(helper), "--serve", "--state-dir", str(state), "--backend", backend]
        if credential_binding is not None:
            command.extend(["--credential-binding", credential_binding])
        # The private test override may exercise LaunchServices with synthetic
        # data; it cannot disable LaunchServices for the production backend.
        self.launch_services = backend == "eventkit" or _launch_services is True
        self.process = (LaunchServicesProcess(helper, command[1:]) if self.launch_services else
                        subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, bufsize=0, close_fds=True))
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.startup_status = None
        if self.launch_services:
            try:
                self.startup_status = self.authorization_status()
                if self.startup_status["backend_mode"] != backend:
                    raise ValueError("Native backend handshake mismatch")
            except BaseException:
                self.close()
                raise

    def close(self):
        if self.launch_services:
            self.process.close()
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()

    def authorization_status(self):
        result = self.call("authorization_status", {})
        if (set(result) != {"backend_mode", "authorization_status", "authorization_status_raw", "pid"}
                or result["backend_mode"] not in ("eventkit", "synthetic")
                or isinstance(result["pid"], bool) or not isinstance(result["pid"], int) or result["pid"] <= 1
                or result["authorization_status"] not in ("full_access", "not_determined", "denied", "restricted", "write_only", "unknown", "not_applicable")
                or (result["authorization_status_raw"] is not None and (isinstance(result["authorization_status_raw"], bool) or not isinstance(result["authorization_status_raw"], int)))):
            raise NativeError("invalid_status", "Native status handshake invalid; no request automatically retried")
        expected = {0: "not_determined", 1: "restricted", 2: "denied", 3: "full_access", 4: "write_only"}
        if result["backend_mode"] == "synthetic":
            valid = result["authorization_status"] == "not_applicable" and result["authorization_status_raw"] is None
        else:
            raw = result["authorization_status_raw"]
            valid = raw is not None and result["authorization_status"] == expected.get(raw, "unknown")
        if not valid:
            raise NativeError("invalid_status", "Native authorization/backend status mismatch")
        return result

    def recovery_capabilities(self):
        """Probe once per resident process; old or unexpected helpers fail closed."""
        if not getattr(self, "_recovery_capabilities_checked", False):
            self._recovery_capabilities_checked = True
            self._recovery_capabilities = None
            try:
                result = self.call("recovery_capabilities", {})
            except (NativeError, ValueError, OSError):
                return None
            if (isinstance(result, dict) and result == RECOVERY_CAPABILITIES
                    and all(type(result[key]) is type(value) for key, value in RECOVERY_CAPABILITIES.items())):
                self._recovery_capabilities = result
        return self._recovery_capabilities

    def alerts_capabilities(self):
        """Metadata-only probe; never infer alert support from recovery support."""
        if not getattr(self, "_alerts_capabilities_checked", False):
            self._alerts_capabilities_checked = True
            self._alerts_capabilities = None
            try:
                result = self.call("alerts_capabilities", {})
            except (NativeError, ValueError, OSError):
                return None
            if (isinstance(result, dict) and result == ALERTS_CAPABILITIES
                    and all(type(result[key]) is type(value) for key, value in ALERTS_CAPABILITIES.items())):
                self._alerts_capabilities = result
        return self._alerts_capabilities

    def recurrence_capabilities(self):
        """Probe recurrence independently, without Calendar access or a write."""
        if not getattr(self, "_recurrence_capabilities_checked", False):
            self._recurrence_capabilities_checked = True
            self._recurrence_capabilities = None
            try:
                result = self.call("recurrence_capabilities", {})
            except (NativeError, ValueError, OSError):
                return None
            if (isinstance(result, dict) and result == RECURRENCE_CAPABILITIES
                    and all(type(result[key]) is type(value) for key, value in RECURRENCE_CAPABILITIES.items())):
                self._recurrence_capabilities = result
        return self._recurrence_capabilities

    def _wait_io(self, readers, writers, deadline):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            ready = select.select(readers, writers, [], min(remaining, 0.1))
            if ready[0] or ready[1]:
                return
            if self.process.poll() is not None:
                raise OSError("Native process exited")

    def call(self, name, arguments):
        if not self.lock.acquire(timeout=1):
            raise NativeError("broker_busy", "Native broker busy; no request submitted")
        submitted = False
        try:
            if self.failed or self.process.poll() is not None:
                raise NativeError("broker_unavailable", "Native broker unavailable; restart the gateway and check get_change_status before another write")
            wire = json.dumps({"op": name, "arguments": arguments}, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8") + b"\n"
            deadline = time.monotonic() + self.timeout
            view = memoryview(wire)
            submitted = True
            while view:
                self._wait_io([], [self.process.stdin], deadline)
                try:
                    view = view[os.write(self.process.stdin.fileno(), view):]
                except BlockingIOError:
                    continue
            response = bytearray()
            while b"\n" not in response:
                self._wait_io([self.process.stdout], [], deadline)
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk or len(response) + len(chunk) > MAX_NATIVE:
                    raise ValueError()
                response.extend(chunk)
            if response.count(b"\n") != 1 or not response.endswith(b"\n"):
                raise ValueError()
            payload = json.loads(response)
            if not isinstance(payload, dict) or set(payload) not in ({"result"}, {"error"}):
                raise ValueError()
            if "error" in payload:
                error = payload["error"]
                if not isinstance(error, dict) or set(error) != {"code", "message"} or not all(isinstance(error[x], str) for x in error):
                    raise ValueError()
                raise NativeError(error["code"], error["message"])
            if not isinstance(payload["result"], dict):
                raise ValueError()
            return payload["result"]
        except NativeError:
            raise
        except (OSError, ValueError, TimeoutError):
            self.failed = True
            self.close()
            raise NativeError("outcome_unknown" if submitted else "broker_unavailable",
                              "Broker transport failed; no automatic retry. Restart gateway and use get_change_status with the preview nonce before any new write") from None
        finally:
            self.lock.release()
