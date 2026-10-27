# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Resource-scoped ingress and dispatch; synthetic spies and private temporary files."""

from contextlib import redirect_stdout, redirect_stderr
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from calendar_mcp.__main__ import main
from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import NativeBroker, NativeError, REMINDERS_CAPABILITIES
from calendar_mcp.protocol import Protocol, VERSIONS
from calendar_mcp.reminders_schema import REMINDER_TOOLS
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer
from test_reconciliation import AssessmentBroker


def rpc(method, params=None):
    return {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}


def tool(name, arguments=None):
    return rpc("tools/call", {"name": name, "arguments": arguments or {}})


class ResourceBroker(AssessmentBroker):
    reminders_enabled = True

    def __init__(self):
        super().__init__()
        self.calls = []
        self.status_calls = []
        self.reminder_probes = 0

    def reminders_capabilities(self):
        self.reminder_probes += 1
        return dict(REMINDERS_CAPABILITIES)

    def authorization_status(self):
        self.status_calls.append("calendar")
        return {"backend_mode": "synthetic", "authorization_status": "not_applicable", "authorization_status_raw": None, "pid": os.getpid()}

    def reminders_authorization_status(self):
        self.status_calls.append("reminders")
        return {"backend_mode": "eventkit", "authorization_status": "denied", "authorization_status_raw": 2, "pid": os.getpid()}

    def call(self, name, arguments):
        self.calls.append((name, arguments))
        return {"scope": "reminders" if "reminder" in name else "calendar"}


class ResourceProtocolTests(unittest.TestCase):
    def test_catalogs_and_instructions_are_separate_and_reminders_probes_only_own_capability(self):
        broker = ResourceBroker()
        calendar = Protocol(broker)
        self.assertEqual(broker.reminder_probes, 0)
        self.assertEqual(len(calendar.tools), 22)

        class RemindersOnly:
            reminders_enabled = True
            def reminders_capabilities(self):
                return dict(REMINDERS_CAPABILITIES)
            def __getattr__(self, name):
                raise AssertionError("A Reminders view must not probe another resource")
        reminders = Protocol(RemindersOnly(), resource="reminders")
        self.assertEqual(reminders.tools, REMINDER_TOOLS)
        self.assertTrue(set(calendar.tool_names).isdisjoint(reminders.tool_names))
        params = {"protocolVersion": VERSIONS[-1], "capabilities": {}, "clientInfo": {}}
        cal_init = calendar.handle(rpc("initialize", params))["result"]
        rem_init = reminders.handle(rpc("initialize", params))["result"]
        self.assertEqual(cal_init["serverInfo"]["name"], "private-calendar-mcp")
        self.assertEqual(rem_init["serverInfo"]["name"], "private-reminders-mcp")
        self.assertNotIn("commit_reminder_", cal_init["instructions"])
        self.assertNotIn("commit_future_", rem_init["instructions"])
        self.assertNotIn("get_change_status", rem_init["instructions"])

    def test_every_foreign_tool_and_native_metadata_name_is_rejected_before_dispatch(self):
        broker = ResourceBroker(); calendar = Protocol(broker); reminders = Protocol(broker, resource="reminders")
        for protocol, foreign in ((calendar, reminders.tool_names), (reminders, calendar.tool_names)):
            for name in [*foreign, "authorization_status", "reminders_authorization_status", "recovery_capabilities", "reminders_capabilities", "apply", "approve"]:
                with self.subTest(resource=protocol.resource, name=name):
                    response = protocol.handle(tool(name, {"resource": protocol.resource}))
                    self.assertEqual(response["error"]["code"], -32602)
        self.assertEqual(broker.calls, [])
        for protocol in (calendar, reminders):
            self.assertFalse(protocol.handle(tool("list_calendars" if protocol.resource == "calendar" else "list_reminder_lists"))["result"]["isError"])
        self.assertEqual([name for name, _ in broker.calls], ["list_calendars", "list_reminder_lists"])

    def test_unadvertised_tools_on_older_calendar_capabilities_never_dispatch(self):
        class Old:
            def call(self, *_):
                self.fail("Unadvertised operation reached broker")
        protocol = Protocol(Old())
        for name in ("list_unresolved_changes", "commit_future_restore", "commit_series_modify", "commit_reminder_delete"):
            response = protocol.handle(tool(name))
            self.assertTrue("error" in response or response.get("result", {}).get("isError") is True)

    def test_reminders_disabled_or_bad_capability_fails_without_calendar_fallback(self):
        for enabled, capability in ((False, REMINDERS_CAPABILITIES), (True, None), (True, {**REMINDERS_CAPABILITIES, "version": True})):
            broker = ResourceBroker(); broker.reminders_enabled = enabled; broker.reminders_capabilities = lambda: capability
            with self.assertRaises(NativeError):
                Protocol(broker, resource="reminders")
            self.assertEqual(len(Protocol(broker).tools), 22)
        for invalid in (None, "both", "CALENDAR", True):
            with self.assertRaises(ValueError):
                Protocol(ResourceBroker(), resource=invalid)

    def test_caller_resource_parameters_and_metadata_cannot_change_scope(self):
        broker = ResourceBroker(); protocol = Protocol(broker, resource="reminders")
        self.assertIn("error", protocol.handle(rpc("tools/list", {"resource": "calendar"})))
        self.assertIn("error", protocol.handle(rpc("initialize", {"protocolVersion": VERSIONS[-1], "capabilities": {}, "clientInfo": {}, "resource": "calendar"})))
        call = tool("list_calendars"); call["params"]["_meta"] = {"resource": "calendar"}
        self.assertIn("error", protocol.handle(call)); self.assertEqual(broker.calls, [])


class ResourceCredentialTests(unittest.TestCase):
    def test_explicit_init_creates_two_distinct_private_credentials_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "private"
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(main(["init", "--state-dir", str(state)]), 0)
                self.assertFalse((state / "reminders.token").exists())
                calendar = read_token(state)
                self.assertEqual(main(["init", "--state-dir", str(state), "--enable-reminders"]), 0)
                reminders = read_token(state, "reminders")
            self.assertNotEqual(calendar, reminders); self.assertEqual(read_token(state), calendar)
            self.assertEqual((state / "reminders.token").stat().st_mode & 0o777, 0o600)
            self.assertNotIn(calendar, output.getvalue()); self.assertNotIn(reminders, output.getvalue())
            initialize(state, "reminders"); self.assertEqual(read_token(state, "reminders"), reminders)

    def test_reminder_token_uses_same_hardened_fixed_file_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            state = initialize(Path(directory) / "private"); initialize(state, "reminders")
            original = state / "original"
            (state / "reminders.token").rename(original)
            (state / "reminders.token").symlink_to(original)
            with self.assertRaises(OSError):
                read_token(state, "reminders")
            (state / "reminders.token").unlink(); os.link(original, state / "reminders.token")
            with self.assertRaises(ValueError):
                read_token(state, "reminders")
            for invalid in ("../gateway.token", "both", True, None):
                with self.assertRaises(ValueError):
                    read_token(state, invalid)

    def test_enabled_native_binding_is_required_independent_and_checked_before_spawn(self):
        for enabled, reminder, calendar in ((True, None, "a" * 64), (True, "bad", "a" * 64), (True, True, "a" * 64), (True, "a" * 64, "a" * 64), (False, "b" * 64, "a" * 64)):
            with self.subTest(enabled=enabled, binding=type(reminder).__name__), patch("calendar_mcp.native.subprocess.Popen") as spawn, self.assertRaises(ValueError):
                NativeBroker("/nonexistent", "/unused", credential_binding=calendar, enable_reminders=enabled, reminders_credential_binding=reminder)
            spawn.assert_not_called()

    def test_serve_never_creates_missing_or_accepts_equal_scoped_token(self):
        with tempfile.TemporaryDirectory() as directory:
            state = initialize(Path(directory) / "private")
            command = ["serve", "--state-dir", str(state), "--helper", "/unused", "--enable-reminders"]
            with patch("calendar_mcp.__main__.NativeBroker") as native, redirect_stderr(io.StringIO()):
                self.assertEqual(main(command), 1)
                self.assertFalse((state / "reminders.token").exists()); native.assert_not_called()
                initialize(state, "reminders")
                (state / "reminders.token").write_text(read_token(state))
                self.assertEqual(main(command), 1); native.assert_not_called()

    def test_serve_binds_each_native_domain_to_only_its_own_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            state = initialize(Path(directory) / "private"); initialize(state, "reminders")
            for enabled in (False, True):
                broker = ResourceBroker(); broker.close = lambda: None
                with patch("calendar_mcp.__main__.NativeBroker", return_value=broker) as native, patch("calendar_mcp.__main__.GatewayServer") as gateway, patch("calendar_mcp.__main__.signal.signal"), redirect_stderr(io.StringIO()):
                    self.assertEqual(main(["serve", "--state-dir", str(state), "--helper", "/unused", *(["--enable-reminders"] if enabled else [])]), 0)
                self.assertEqual(native.call_args.kwargs["credential_binding"], hashlib.sha256(read_token(state).encode()).hexdigest())
                self.assertEqual(native.call_args.kwargs["reminders_credential_binding"], hashlib.sha256(read_token(state, "reminders").encode()).hexdigest() if enabled else None)
                self.assertEqual(gateway.call_args.kwargs["reminders_token"], read_token(state, "reminders") if enabled else None)
                self.assertEqual(broker.reminder_probes, int(enabled))

    def test_stdio_failure_guidance_uses_only_selected_resource_status_tool(self):
        class Broken:
            def __init__(self, resource):
                self.resource = resource
            def send(self, *_):
                raise OSError("Private fixture must not escape")
        for resource, name in (("calendar", "get_change_status"), ("reminders", "get_reminder_change_status")):
            sink = io.BytesIO(); self.assertEqual(run_stdio(Broken(resource), io.BytesIO(json.dumps(rpc("ping")).encode() + b"\n"), sink), 0)
            text = json.loads(sink.getvalue())["error"]["message"]
            self.assertIn(name, text); self.assertNotIn("Private", text)
            self.assertNotIn("get_change_status" if resource == "reminders" else "get_reminder_change_status", text)


class ResourceHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = initialize(Path(self.temporary.name) / "private"); initialize(self.state, "reminders")
        self.tokens = {resource: read_token(self.state, resource) for resource in ("calendar", "reminders")}
        self.broker = ResourceBroker()
        self.calendar, self.reminders = Protocol(self.broker), Protocol(self.broker, resource="reminders")
        self.server = GatewayServer(0, self.tokens["calendar"], self.calendar, state_directory=self.state,
                                    reminders_token=self.tokens["reminders"], reminders_protocol=self.reminders)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True); self.thread.start()
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()

    def http(self, path, token, body=None, *, repeated=False, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        method = "GET" if path.endswith("status") else "POST"
        wire = json.dumps(body or rpc("tools/list")).encode()
        connection.putrequest(method, path)
        if token is not None:
            connection.putheader("Authorization", "Bearer " + token)
            if repeated:
                connection.putheader("Authorization", "Bearer " + token)
        connection.putheader("Content-Type", "application/json"); connection.putheader("Accept", "application/json")
        connection.putheader("Content-Length", str(len(wire)))
        for name, value in (headers or {}).items():
            connection.putheader(name, value)
        connection.endheaders(wire)
        response = connection.getresponse(); result = response.status, response.read(); connection.close(); return result

    def test_wrong_route_credentials_repeated_headers_and_unknown_paths_never_dispatch(self):
        for resource, paths in (("calendar", ("/mcp", "/status")), ("reminders", ("/reminders/mcp", "/reminders/status"))):
            wrong = "reminders" if resource == "calendar" else "calendar"
            for path in paths:
                for token in (self.tokens[wrong], "bad", None):
                    self.assertEqual(self.http(path, token)[0], 401)
                self.assertEqual(self.http(path, self.tokens[resource], repeated=True)[0], 401)
        for path in ("/both/mcp", "/mcp?resource=reminders", "/reminders/mcp/", "/reminders/status?resource=calendar", "/%72eminders/mcp"):
            self.assertNotEqual(self.http(path, self.tokens["calendar"])[0], 200)
            self.assertNotEqual(self.http(path, self.tokens["reminders"])[0], 200)
        self.assertEqual(self.broker.calls, []); self.assertEqual(self.broker.status_calls, [])

    def test_each_scoped_unix_client_sees_only_own_catalog_status_and_stdio(self):
        for resource, expected, key in (("calendar", self.calendar.tools, "native"), ("reminders", REMINDER_TOOLS, "reminders")):
            client = GatewayClient(self.state, self.server.server_port, resource=resource)
            self.assertEqual(client.send(json.dumps(rpc("tools/list")).encode())["result"]["tools"], expected)
            status = client.status(); self.assertEqual(set(status), {"gateway", key})
            other = self.reminders.tool_names if resource == "calendar" else self.calendar.tool_names
            for name in other:
                self.assertIn("error", client.send(json.dumps(tool(name)).encode()))
            sink = io.BytesIO(); self.assertEqual(run_stdio(client, io.BytesIO(json.dumps(rpc("tools/list")).encode() + b"\n"), sink), 0)
            self.assertEqual(json.loads(sink.getvalue())["result"]["tools"], expected)
        self.assertEqual(self.broker.calls, []); self.assertEqual(self.broker.status_calls, ["calendar", "reminders"])

    def test_header_cannot_select_resource_and_status_cannot_cross_probe(self):
        status, body = self.http("/status", self.tokens["calendar"], headers={"X-Resource": "reminders"})
        self.assertEqual(status, 200); self.assertEqual(set(json.loads(body)), {"gateway", "native"})
        status, body = self.http("/reminders/status", self.tokens["reminders"], headers={"X-Resource": "calendar"})
        self.assertEqual(status, 200); self.assertEqual(set(json.loads(body)), {"gateway", "reminders"})
        self.assertEqual(self.broker.status_calls, ["calendar", "reminders"])

    def test_duplicate_credentials_wrong_scope_protocol_and_second_native_owner_are_rejected(self):
        for token, protocol in ((self.tokens["calendar"], self.reminders), (self.tokens["reminders"], self.calendar), (self.tokens["reminders"], Protocol(ResourceBroker(), resource="reminders"))):
            with self.assertRaises(ValueError):
                GatewayServer(0, self.tokens["calendar"], self.calendar, reminders_token=token, reminders_protocol=protocol)
        with self.assertRaises(ValueError):
            GatewayServer(0, self.tokens["reminders"], self.reminders)

    def test_disabled_routes_do_not_exist_and_do_not_load_reminder_credentials(self):
        with GatewayServer(0, self.tokens["calendar"], self.calendar) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True); thread.start()
            try:
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
                connection.request("POST", "/reminders/mcp", body=b"{}", headers={"Authorization": "Bearer " + self.tokens["calendar"]})
                response = connection.getresponse(); self.assertEqual(response.status, 404); response.read(); connection.close()
            finally:
                server.shutdown(); thread.join()


RESOURCE_HELPER = Path(os.environ.get("CALENDAR_MCP_TEST_HELPER", "/nonexistent-resource-test-helper"))


@unittest.skipUnless(RESOURCE_HELPER.is_file(), "Set CALENDAR_MCP_TEST_HELPER to the resource-scoped synthetic helper")
class ResourceNativeIntegrationTests(unittest.TestCase):
    def test_each_credential_rotation_changes_only_its_native_signing_generation_and_preserves_history(self):
        import sqlite3
        from contextlib import closing

        with tempfile.TemporaryDirectory(prefix="resource-native-synthetic-") as directory:
            state = initialize(Path(directory) / "private"); initialize(state, "reminders")
            native = state / "native-synthetic"

            def open_broker():
                return NativeBroker(RESOURCE_HELPER, native, "synthetic", enable_reminders=True,
                    credential_binding=hashlib.sha256(read_token(state).encode()).hexdigest(),
                    reminders_credential_binding=hashlib.sha256(read_token(state, "reminders").encode()).hexdigest())

            def snapshot(resource):
                file = native / "state.sqlite3" if resource == "calendar" else native / "reminders" / "reminders.sqlite3"
                with closing(sqlite3.connect(file)) as connection:
                    names = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
                    tables = {name: connection.execute('SELECT rowid,* FROM "' + name.replace('"', '""') + '" ORDER BY rowid').fetchall() for name in names if name != "metadata"}
                    metadata = dict(connection.execute("SELECT key,value FROM metadata"))
                return metadata, tables

            def signing(metadata):
                return {key: metadata[key] for key in ("installation_id", "credential_generation", "key_id", "signing_key")}

            def call(protocol, name, arguments=None):
                response = protocol.handle(tool(name, arguments))
                self.assertNotIn("error", response)
                self.assertFalse(response["result"]["isError"], response)
                return response["result"]["structuredContent"]

            broker = open_broker()
            try:
                calendar, reminders = Protocol(broker), Protocol(broker, resource="reminders")
                calendar_id = call(calendar, "list_calendars")["calendars"][0]["id"]
                calendar_preview = call(calendar, "preflight_change", {"action": "create", "scope": "this", "calendar_id": calendar_id,
                    "fields": {"title": "Synthetic scope fixture", "start": "2027-01-05T10:00:00Z", "end": "2027-01-05T11:00:00Z", "time_zone": "Europe/London"}})["preview"]
                self.assertEqual(call(calendar, "commit_create", {"preview": calendar_preview})["state"], "applied")
                reminder_list = call(reminders, "list_reminder_lists")["lists"][0]["id"]
                reminder_preview = call(reminders, "preflight_reminder_change", {"action": "create", "scope": "this", "list_id": reminder_list,
                    "fields": {"title": "Synthetic reminder scope fixture"}})["preview"]
                self.assertEqual(call(reminders, "commit_reminder_create", {"preview": reminder_preview})["state"], "applied")
            finally:
                broker.close()
            before = {resource: snapshot(resource) for resource in ("calendar", "reminders")}
            self.assertEqual(len(before["calendar"][1]["executions"]), 1)
            self.assertEqual(len(before["reminders"][1]["executions"]), 1)
            for changed, filename in (("reminders", "reminders.token"), ("calendar", "gateway.token")):
                previous = {resource: snapshot(resource) for resource in ("calendar", "reminders")}
                (state / filename).write_text("d" * 64 if changed == "reminders" else "e" * 64)
                broker = open_broker()
                try:
                    self.assertEqual(len(Protocol(broker).tools), 22)
                    self.assertEqual(len(Protocol(broker, resource="reminders").tools), 17)
                finally:
                    broker.close()
                for resource in ("calendar", "reminders"):
                    metadata, tables = snapshot(resource)
                    old_metadata, old_tables = previous[resource]
                    if resource == changed:
                        self.assertNotEqual(signing(metadata)["credential_generation"], signing(old_metadata)["credential_generation"])
                        self.assertNotEqual(metadata["signing_key"], old_metadata["signing_key"])
                        self.assertEqual(metadata["installation_id"], old_metadata["installation_id"])
                    else:
                        self.assertEqual(signing(metadata), signing(old_metadata))
                    self.assertEqual(set(tables), set(old_tables))
                    for name, rows in old_tables.items():
                        if name == "audit":
                            self.assertEqual(tables[name][:len(rows)], rows)
                        else:
                            self.assertEqual(tables[name], rows, resource + ":" + name)
