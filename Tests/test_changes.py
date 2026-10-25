"""Recovery transport contracts and local tooling use synthetic state only."""

from contextlib import redirect_stderr, redirect_stdout
import io
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import shutil
import tempfile
import threading
import unittest
from unittest.mock import patch

from calendar_mcp.__main__ import main
from calendar_mcp.changes import open_window, read_tool, socket_path
from calendar_mcp.native import NativeBroker, NativeError, RECOVERY_CAPABILITIES, valid_recovery_capabilities
from calendar_mcp.protocol import Protocol
from calendar_mcp.schema import ValidationError, validate_arguments
from calendar_mcp.security import initialize, private_directory


def recovery_preview(action="modify"):
    calendar = {"id": "calendar", "title": "Fixture", "source": "Synthetic", "writable": True, "subscribed": False}
    fields = {"title": "Before fixture", "start": "2026-10-23T09:00:00Z", "end": "2026-10-23T10:00:00Z",
              "time_zone": "Europe/London", "all_day": False, "location": "", "notes": "Fixture"}
    event = {"id": "event", "calendar": calendar, "occurrence": None, "fields": fields,
             "recurring": False, "detached": False, "availability": "busy", "status": "confirmed",
             "has_attendees": False, "has_organizer": False, "fingerprint": "fingerprint", "details": {}}
    return {"envelope": {"version": 1, "nonce": "rollback-nonce", "issued_at": "2026-10-24T00:00:00Z",
                          "expires_at": "2026-10-24T00:10:00Z", "installation_id": "installation",
                          "credential_generation": "generation", "key_id": "key", "action": action,
                          "scope": "this", "calendar": calendar, "before": None if action == "create" else event,
                          "after": fields, "rollback": {"selection_id": "selection", "source_change_ids": ["source"],
                            "source_digest": "a" * 64, "restoration": {"details": {"url": "https://example.invalid/"},
                            "availability": "busy"} if action == "create" else None,
                            "limitations": ["Original provider identifiers cannot be restored."]}},
            "authentication_tag": "synthetic-test-fixture-not-native-authentication"}


class RecoverySchemaTests(unittest.TestCase):
    def test_old_or_unrecognized_native_capability_never_advertises_or_dispatches_recovery(self):
        for native_result in (None, {**RECOVERY_CAPABILITIES, "version": True},
                              {**RECOVERY_CAPABILITIES, "extra": True}, {**RECOVERY_CAPABILITIES, "local_ui": 0}):
            class Broker:
                def recovery_capabilities(self):
                    return native_result

                def call(self, name, arguments):
                    raise AssertionError("Unavailable recovery must not dispatch")
            protocol = Protocol(Broker())
            published = protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
            self.assertEqual(len(published), 9)
            reply = protocol.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                     "params": {"name": "preflight_rollback", "arguments": {"all": True}}})
            self.assertEqual(json.loads(reply["result"]["content"][0]["text"])["code"], "feature_unavailable")

    def test_recovery_contract_accepts_known_storage_and_boolean_local_ui_variation(self):
        for storage_version, local_ui in ((2, False), (2, True), (3, False), (3, True), (4, False), (4, True), (5, False), (5, True), (6, False), (6, True)):
            capabilities = {**RECOVERY_CAPABILITIES, "storage_version": storage_version, "local_ui": local_ui}

            class Broker:
                def recovery_capabilities(self):
                    return capabilities

                def call(self, name, arguments):
                    self.received = name, arguments
                    return {}

            broker = Broker()
            protocol = Protocol(broker)
            published = protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
            self.assertEqual(len(published), 13)
            for name, arguments in (("list_changes", {}), ("get_stored_change", {"change_id": "fixture"}),
                                    ("preflight_rollback", {"all": True}), ("commit_rollback", {"preview": recovery_preview()})):
                result = protocol.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                          "params": {"name": name, "arguments": arguments}})
                self.assertFalse(result["result"]["isError"])
                self.assertEqual(broker.received, (name, arguments))
        invalid = [None, {}, {**RECOVERY_CAPABILITIES, "extra": True}]
        invalid.extend({key: value for key, value in RECOVERY_CAPABILITIES.items() if key != missing}
                       for missing in RECOVERY_CAPABILITIES)
        invalid.extend({**RECOVERY_CAPABILITIES, "local_ui": value} for value in (None, 0, 1, "false", [], {}))
        invalid.extend({**RECOVERY_CAPABILITIES, key: value} for key, value in
                       (("version", True), ("version", 1.0), ("storage_version", 2.0), ("storage_version", 7),
                        ("storage_version", True), ("recovery", 1),
                        ("detail_retention", 1), ("max_selection", 25.0), ("max_selection", 24)))
        for capabilities in invalid:
            with self.subTest(capabilities=capabilities):
                self.assertFalse(valid_recovery_capabilities(capabilities))

    def test_capability_probe_is_cached_and_does_not_authorize_calendar_access(self):
        for reply in (RECOVERY_CAPABILITIES, {**RECOVERY_CAPABILITIES, "local_ui": False},
                      {**RECOVERY_CAPABILITIES, "storage_version": 3, "local_ui": False},
                      {**RECOVERY_CAPABILITIES, "storage_version": 4, "local_ui": False},
                      {**RECOVERY_CAPABILITIES, "storage_version": 5, "local_ui": False},
                      NativeError("unknown_operation", "Unknown operation")):
            broker = object.__new__(NativeBroker)
            calls = []

            def probe(name, arguments):
                calls.append((name, arguments))
                if isinstance(reply, Exception):
                    raise reply
                return reply

            broker.call = probe
            self.assertEqual(broker.recovery_capabilities(), None if isinstance(reply, Exception) else reply)
            self.assertEqual(broker.recovery_capabilities(), None if isinstance(reply, Exception) else reply)
            self.assertEqual(calls, [("recovery_capabilities", {})])

    def test_history_filters_and_bounded_selection(self):
        validate_arguments("list_changes", {"limit": 100, "include_expired": True, "cursor": "opaque",
                           "since": "2026-10-20T00:00:00Z", "until": "2026-10-24T00:00:00Z", "action": "delete"})
        validate_arguments("get_stored_change", {"change_id": "source"})
        validate_arguments("preflight_rollback", {"change_ids": [str(index) for index in range(25)]})
        validate_arguments("preflight_rollback", {"all": True, "action": "modify", "event_id": "event"})
        invalid = [("list_changes", {"limit": item}) for item in (0, 101, True, 2.5)]
        invalid += [("list_changes", {"cursor": "x" * 4097}),
                    ("list_changes", {"retention_days": 365}),
                    ("list_changes", {"since": "2026-10-24T00:00:00Z", "until": "2026-10-23T00:00:00Z"}),
                    ("get_stored_change", {"nonce": "source"}),
                    ("preflight_rollback", {}), ("preflight_rollback", {"all": False}),
                    ("preflight_rollback", {"change_ids": []}),
                    ("preflight_rollback", {"change_ids": ["same", "same"]}),
                    ("preflight_rollback", {"change_ids": [str(index) for index in range(26)]}),
                    ("preflight_rollback", {"change_ids": ["source"], "all": True}),
                    ("preflight_rollback", {"change_ids": ["source"], "action": "delete"}),
                    ("preflight_rollback", {"all": True, "userApproved": True})]
        for name, arguments in invalid:
            with self.subTest(name=name, arguments=arguments), self.assertRaises(ValidationError):
                validate_arguments(name, arguments)

    def test_native_recovery_payload_is_forwarded_unchanged_only_to_matching_tool(self):
        class Broker:
            def recovery_capabilities(self):
                return dict(RECOVERY_CAPABILITIES)

            def call(self, name, arguments):
                self.received = name, arguments
                return {"state": "applied"}
        broker = Broker()
        for action in ("create", "modify"):
            preview = recovery_preview(action)
            arguments = {"preview": preview}
            validate_arguments("commit_rollback", arguments)
            reply = Protocol(broker).handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                           "params": {"name": "commit_rollback", "arguments": arguments}})
            self.assertFalse(reply["result"]["isError"])
            self.assertEqual(broker.received, ("commit_rollback", arguments))
            self.assertIs(broker.received[1]["preview"], preview)
            with self.assertRaises(ValidationError):
                validate_arguments("commit_" + action, arguments)
            with self.assertRaises(ValidationError):
                validate_arguments("commit_rollback", {**arguments, "approved": True})
            malformed = json.loads(json.dumps(preview))
            malformed["envelope"]["rollback"]["restoration"] = None if action == "create" else {"details": {}, "availability": "busy"}
            with self.assertRaises(ValidationError):
                validate_arguments("commit_rollback", {"preview": malformed})
        for forbidden in ("set_retention", "approve_rollback", "open_changes"):
            with self.assertRaises(ValidationError):
                validate_arguments(forbidden, {})


class LocalChangesTests(unittest.TestCase):
    def test_open_checks_gateway_capability_before_contacting_native_socket(self):
        class Client:
            def __init__(self, state, port):
                pass

            def send(self, wire):
                self.request = json.loads(wire)
                return {"jsonrpc": "2.0", "id": 1, "result": {"tools": []}}
        with patch("calendar_mcp.changes.GatewayClient", Client), patch("calendar_mcp.changes.open_window") as opener:
            with redirect_stderr(io.StringIO()):
                self.assertEqual(main(["changes", "open", "--state-dir", "/tmp/unused"]), 1)
            opener.assert_not_called()

    def test_open_rejects_malformed_discovery_result_or_boolean_reply_id(self):
        for result, identifier in ((None, 1), ([], 1), ({"tools": []}, True)):
            class Client:
                def __init__(self, state, port):
                    pass

                def send(self, wire):
                    return {"jsonrpc": "2.0", "id": identifier, "result": result}
            with self.subTest(result=result, identifier=identifier), patch("calendar_mcp.changes.GatewayClient", Client):
                with patch("calendar_mcp.changes.open_window") as opener, redirect_stderr(io.StringIO()):
                    self.assertEqual(main(["changes", "open", "--state-dir", "/tmp/unused"]), 1)
                opener.assert_not_called()

    def test_cli_history_calls_authenticated_gateway_with_strict_inputs(self):
        class Client:
            def __init__(self, state, port):
                self.state, self.port = state, port

            def send(self, wire):
                calls.append(json.loads(wire))
                return {"jsonrpc": "2.0", "id": 1, "result": {"isError": False, "structuredContent": {"fixture": True}}}
        calls = []
        output = io.StringIO()
        with patch("calendar_mcp.changes.GatewayClient", Client), redirect_stdout(output):
            self.assertEqual(main(["changes", "list", "--state-dir", "/tmp/unused", "--port", "18765", "--limit", "20",
                                   "--action", "delete", "--event-id", "fixture", "--include-expired", "--cursor", "page"]), 0)
            self.assertEqual(main(["changes", "show", "source", "--state-dir", "/tmp/unused"]), 0)
        self.assertEqual(calls[0]["params"], {"name": "list_changes", "arguments": {
                         "limit": 20, "include_expired": True, "action": "delete", "event_id": "fixture", "cursor": "page"}})
        self.assertEqual(calls[1]["params"], {"name": "get_stored_change", "arguments": {"change_id": "source"}})
        with patch("calendar_mcp.changes.GatewayClient", Client), redirect_stderr(io.StringIO()):
            self.assertEqual(main(["changes", "list", "--limit", "101"]), 1)
        self.assertEqual(len(calls), 2)

    def test_open_socket_is_protected_and_sends_only_window_activation(self):
        with tempfile.TemporaryDirectory(prefix="cmcp-", dir="/tmp") as directory:
            state = initialize(Path(directory) / ("long-state-path-" * 10))
            native = private_directory(state / "native-synthetic")
            self.assertGreater(len(str(native).encode("utf-8")), 104)
            path = socket_path(native)
            self.assertLess(len(str(path).encode("utf-8")), 104)
            private_directory(path.parent)
            self.addCleanup(shutil.rmtree, path.parent)
            messages = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                os.chmod(path, 0o600)
                server.listen(1)

                def respond():
                    connection, _ = server.accept()
                    with connection:
                        messages.append(connection.recv(1024))
                        connection.sendall(b'{"opened":true}\n')

                thread = threading.Thread(target=respond)
                thread.start()
                self.assertEqual(open_window(state, "synthetic"), {"opened": True})
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
            self.assertEqual(messages, [b'{"op":"open_changes"}\n'])
            os.chmod(path.parent, 0o500)
            with self.assertRaises(ValueError):
                open_window(state, "synthetic")
            os.chmod(path.parent, 0o700)
            os.chmod(path, 0o644)
            with self.assertRaises(ValueError):
                open_window(state, "synthetic")
            path.unlink()
            path.write_text("not a socket")
            path.chmod(0o600)
            with self.assertRaises(ValueError):
                open_window(state, "synthetic")

    def test_socket_derivation_ignores_public_legacy_preclaim_and_tmpdir(self):
        with tempfile.TemporaryDirectory(prefix="cmcp-", dir="/tmp") as directory:
            native = private_directory(Path(directory) / ("Unicode e\u0301 👩🏽‍💻 " + "long" * 40))
            fingerprint = hashlib.sha256(str(native.resolve()).encode("utf-8")).hexdigest()[:20]
            legacy = Path("/private/tmp") / ("calendar-mcp-ui-" + str(os.getuid()) + "-" + fingerprint)
            legacy.mkdir(mode=0o755)
            self.addCleanup(shutil.rmtree, legacy)
            with patch.dict(os.environ, {"TMPDIR": str(legacy)}):
                endpoint = socket_path(native)
            self.assertNotEqual(endpoint.parent, legacy)
            self.assertEqual(endpoint.parent.name, "cmui-" + fingerprint)
            self.assertEqual(endpoint.name, "s")
            base = endpoint.parent.parent.lstat()
            self.assertEqual(base.st_uid, os.getuid())
            self.assertEqual(stat.S_IMODE(base.st_mode) & 0o077, 0)
            self.assertLess(len(os.fsencode(endpoint)), 104)

    def test_socket_derivation_rejects_unsafe_os_temporary_base(self):
        with tempfile.TemporaryDirectory(prefix="cmcp-", dir="/tmp") as directory:
            base = Path(directory)
            native = private_directory(base / "state")
            public = base / "public"; public.mkdir(mode=0o755); public.chmod(0o755)
            link = base / "link"; link.symlink_to(native, target_is_directory=True)
            for supplied in (str(public), str(link), "relative", None):
                with self.subTest(supplied=supplied), patch("calendar_mcp.changes.os.confstr", return_value=supplied):
                    with self.assertRaises(ValueError):
                        socket_path(native)
            with patch("calendar_mcp.changes.os.getuid", return_value=os.getuid() + 1):
                with self.assertRaises(ValueError):
                    socket_path(native)

    def test_history_errors_do_not_expose_native_details(self):
        class Client:
            def send(self, wire):
                return {"jsonrpc": "2.0", "id": 1, "result": {"isError": True,
                         "content": [{"type": "text", "text": "sensitive native failure"}]}}
        with self.assertRaisesRegex(Exception, "Native change history could not be read"):
            read_tool(Client(), "get_stored_change", {"change_id": "fixture"})

    def test_open_requires_exact_boolean_acknowledgement(self):
        with tempfile.TemporaryDirectory(prefix="cmcp-", dir="/tmp") as directory:
            state = initialize(Path(directory) / "state")
            native = private_directory(state / "native-synthetic")
            path = socket_path(native)
            private_directory(path.parent)
            self.addCleanup(shutil.rmtree, path.parent)
            for acknowledgement in (b'{"opened":1}\n', b'{"opened":true,"approved":true}\n'):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(str(path))
                    os.chmod(path, 0o600)
                    server.listen(1)

                    def respond():
                        connection, _ = server.accept()
                        with connection:
                            connection.recv(1024)
                            connection.sendall(acknowledgement)

                    thread = threading.Thread(target=respond)
                    thread.start()
                    with self.assertRaises(ValueError):
                        open_window(state, "synthetic")
                    thread.join(timeout=3)
                    self.assertFalse(thread.is_alive())
                path.unlink()


if __name__ == "__main__":
    unittest.main()
