# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Protocol and boundary tests use no EventKit and request no OS permissions."""

import contextlib
import http.client
import io
import json
import os
from pathlib import Path
import socket
import stat
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import ALERTS_CAPABILITIES, NativeBroker, NativeError, RECOVERY_CAPABILITIES
from calendar_mcp.protocol import Protocol, VERSIONS, loads
from calendar_mcp.schema import TOOLS, ValidationError, validate, validate_arguments
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_BODY


class FakeBroker:
    def __init__(self):
        self.calls = []

    def call(self, name, arguments):
        self.calls.append((name, arguments))
        return {"calendars": []}

    def recovery_capabilities(self):
        return dict(RECOVERY_CAPABILITIES)

    def authorization_status(self):
        return {"backend_mode": "synthetic", "authorization_status": "not_applicable", "authorization_status_raw": None, "pid": os.getpid()}


def request(method, params=None, identifier=1):
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}}


class SchemaTests(unittest.TestCase):
    def test_write_policy_and_no_approval_surface(self):
        self.assertEqual(len(TOOLS), 13)
        for tool in TOOLS:
            hints = tool["annotations"]
            self.assertFalse(hints["openWorldHint"])
            if tool["name"].startswith("commit_"):
                self.assertFalse(hints["readOnlyHint"])
                self.assertTrue(hints["idempotentHint"])
                self.assertEqual(set(tool["inputSchema"]["properties"]), {"preview"})
            elif tool["name"].startswith("preflight_"):
                self.assertTrue(hints["readOnlyHint"])
                self.assertFalse(hints["destructiveHint"])
        for name in ("apply", "approve", "calendars", "run_command"):
            with self.assertRaises(ValidationError):
                validate_arguments(name, {})

    def test_unknown_types_and_extra_fields_fail(self):
        invalid = [("list_calendars", {"userApproved": True}),
                   ("get_event", {"event_id": True}),
                   ("query_events", {"start": "2026-10-23T10:00:00", "end": "2026-10-23T11:00:00Z"}),
                   ("query_events", {"start": "2026-10-23T10:00:00Z", "end": "2026-10-23T11:00:00Z", "time_zone": "../etc/passwd"}),
                   ("preflight_change", {"action": "delete", "scope": "this", "event_id": "x", "fields": {}}),
                   ("preflight_change", {"action": "create", "scope": "this", "calendar_id": "x", "fields": {"title": "x"}})]
        for name, arguments in invalid:
            with self.subTest(name=name, arguments=arguments), self.assertRaises(ValidationError):
                validate_arguments(name, arguments)

    def test_duplicate_keys_nonfinite_and_deep_json_rejected(self):
        for wire in ('{"x":1,"x":2}', '{"x":NaN}', '{"x":1e999}', '{"x":-1e999}',
                     '{"x":[{"nested":1e999}]}', '{"x":"\\ud800"}', '{"\\udfff":0}',
                     '[' * 25 + '1' + ']' * 25):
            with self.assertRaises(ValueError):
                loads(wire)
        self.assertEqual(loads('{"🗓":"\\ud83d\\uddd3"}'), {"🗓": "🗓"})

    def test_direct_schema_validation_checks_unrestricted_nested_json(self):
        schema = {"type": "object", "properties": {}, "required": [], "additionalProperties": True}
        for value in ({"title": "\ud800"}, {"\udfff": 0}, {"nested": [{"number": float("inf")}]},
                      {"nested": {1: "not a string key"}}):
            with self.subTest(value=repr(value)), self.assertRaises(ValidationError):
                validate(value, schema)
        with self.assertRaises(ValidationError):
            validate_arguments("get_event", {"event_id": "\ud800"})
        validate_arguments("get_event", {"event_id": "🗓"})


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.broker = FakeBroker()
        self.protocol = Protocol(self.broker)

    def test_supported_versions_and_capabilities(self):
        for version in VERSIONS:
            response = self.protocol.handle(request("initialize", {"protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}))
            self.assertEqual(response["result"]["protocolVersion"], version)
            self.assertEqual(set(response["result"]["capabilities"]), {"tools"})
        response = self.protocol.handle(request("initialize", {"protocolVersion": "2020-01-01", "capabilities": {}, "clientInfo": {}}))
        self.assertEqual(response["error"]["code"], -32602)

    def test_invalid_calls_never_dispatch(self):
        wires = [[], request("apply"), request("tools/call", {"name": "apply", "arguments": {}}),
                 request("tools/call", {"name": "list_calendars", "arguments": {"approved": True}}),
                 {"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "commit_delete", "arguments": {}}}]
        for wire in wires:
            self.protocol.handle(wire)
        self.assertEqual(self.broker.calls, [])

    def test_direct_invalid_unicode_and_nonfinite_requests_never_dispatch(self):
        for value in ("\ud800", {"\udfff": 0}, {"nested": [float("inf")]}):
            response = self.protocol.handle(request("tools/call", {"name": "get_event", "arguments": {"event_id": value}}))
            self.assertEqual(response["error"]["code"], -32600)
        self.assertEqual(self.broker.calls, [])

    def test_native_errors_are_tool_errors(self):
        class Broken:
            def call(self, name, arguments):
                raise NativeError("stale_preview", "Create a new preview")
        result = Protocol(Broken()).handle(request("tools/call", {"name": "list_calendars"}))["result"]
        self.assertTrue(result["isError"])
        self.assertNotIn("structuredContent", result)

    def test_calendar_deletion_requests_never_dispatch(self):
        calls = [
            ("delete_calendar", {"calendar_id": "calendar"}),
            ("commit_delete_calendar", {"calendar_id": "calendar"}),
            ("preflight_change", {"action": "delete_calendar", "scope": "this", "calendar_id": "calendar"}),
            ("preflight_change", {"action": "delete", "scope": "this", "calendar_id": "calendar"}),
            ("preflight_change", {"action": "delete", "scope": "this", "calendar_id": "calendar", "event_id": "event"}),
            ("preflight_change", {"action": "delete", "scope": "all", "event_id": "event"}),
        ]
        for name, arguments in calls:
            with self.subTest(name=name, arguments=arguments):
                response = self.protocol.handle(request("tools/call", {"name": name, "arguments": arguments}))
                self.assertEqual(response["error"]["code"], -32602)
        self.assertEqual(self.broker.calls, [])


class CredentialTests(unittest.TestCase):
    def test_credential_init_permissions_reuse_no_echo(self):
        with tempfile.TemporaryDirectory() as directory:
            state = initialize(Path(directory) / "state with spaces")
            token = read_token(state)
            self.assertEqual(len(token), 64)
            self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((state / "gateway.token").stat().st_mode), 0o600)
            initialize(state)
            self.assertEqual(token, read_token(state))
            os.chmod(state / "gateway.token", 0o644)
            with self.assertRaises(ValueError):
                read_token(state)

    def test_symlink_hardlink_and_public_directory_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = initialize(root / "state")
            (state / "gateway.token").rename(state / "original")
            (state / "gateway.token").symlink_to(state / "original")
            with self.assertRaises(OSError):
                read_token(state)
            (state / "gateway.token").unlink()
            os.link(state / "original", state / "gateway.token")
            with self.assertRaises(ValueError):
                read_token(state)
            os.chmod(state, 0o755)
            with self.assertRaises(ValueError):
                initialize(state)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = initialize(Path(self.temp.name) / "state")
        self.token = read_token(self.state)
        self.broker = FakeBroker()
        self.server = GatewayServer(0, self.token, Protocol(self.broker), state_directory=self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.port = self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def http(self, method="POST", body=None, headers=None, path="/mcp"):
        payload = json.dumps(request("ping")).encode() if body is None else body
        defaults = {"Authorization": "Bearer " + self.token, "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream"}
        defaults.update(headers or {})
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request(method, path, body=payload, headers=defaults)
        response = connection.getresponse()
        result = response.status, response.read(), dict(response.getheaders())
        connection.close()
        return result

    def test_auth_required_on_every_http_method_and_path(self):
        for method in ("GET", "POST", "DELETE", "OPTIONS", "HEAD", "PATCH", "TRACE", "CUSTOM"):
            self.assertEqual(self.http(method, headers={"Authorization": "bad"})[0], 401)
            self.assertEqual(self.http(method, headers={"Authorization": "bad"}, path="/approve")[0], 401)
            if method != "POST":
                self.assertEqual(self.http(method)[0], 405)
        self.assertEqual(self.broker.calls, [])

    def test_complete_alert_schema_discovery_survives_http_and_stdio_response_parsing(self):
        class AlertBroker(FakeBroker):
            def alerts_capabilities(self):
                return dict(ALERTS_CAPABILITIES)
        self.server.protocol = Protocol(AlertBroker())
        wire = json.dumps(request("tools/list")).encode()
        client = GatewayClient(self.state, self.port)
        result = client.send(wire)
        self.assertEqual(result["result"]["tools"], TOOLS)
        sink = io.BytesIO()
        self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
        self.assertEqual(json.loads(sink.getvalue())["result"]["tools"], TOOLS)
        # The expanded response allowance must not relax incoming requests.
        with self.assertRaises(ValueError):
            loads("[" * 21 + "1" + "]" * 21)

    def test_host_origin_path_and_protocol_fail_closed(self):
        for headers, expected in [({"Host": "evil.example"}, 403), ({"Host": "localhost:" + str(self.port)}, 403),
                                  ({"Origin": "https://evil.example"}, 403), ({"Origin": "null"}, 403),
                                  ({"MCP-Protocol-Version": "future"}, 400), ({"Content-Type": "text/plain"}, 415),
                                  ({"Accept": "text/html"}, 406)]:
            self.assertEqual(self.http(headers=headers)[0], expected)
        self.assertEqual(self.http(headers={"Origin": "http://127.0.0.1:" + str(self.port)})[0], 200)
        self.assertEqual(self.http(path="/mcp?target=https://evil.example")[0], 404)
        self.assertNotIn("Access-Control-Allow-Origin", self.http()[2])

    def test_authenticated_status_only_reads_native_metadata(self):
        client = GatewayClient(self.state, self.port)
        result = client.status()
        self.assertEqual(result["gateway"], "reachable")
        self.assertEqual(result["native"]["authorization_status"], "not_applicable")
        self.assertEqual(self.http("GET", path="/status", headers={"Authorization": "bad"})[0], 401)
        self.assertEqual(self.http("GET", path="/status", headers={"Origin": "null"})[0], 403)
        self.assertEqual(self.http("POST", path="/status")[0], 405)
        self.assertEqual(self.broker.calls, [])

    def test_bounded_body_encoding_and_json(self):
        self.assertEqual(self.http(headers={"Content-Length": str(MAX_BODY + 1)})[0], 413)
        self.assertEqual(self.http(headers={"Transfer-Encoding": "chunked"})[0], 400)
        self.assertEqual(self.http(body=b'{"x":1,"x":2}')[0], 400)
        self.assertEqual(self.http(body=b'{"x":NaN}')[0], 400)
        self.assertEqual(self.http(body=b'{"x":1e999}')[0], 400)
        self.assertEqual(self.http(body=b'{"x":"\\ud800"}')[0], 400)
        self.assertEqual(self.http(body=b'{"\\udfff":0}')[0], 400)
        self.assertEqual(self.http(body=b'{')[0], 400)

    def test_duplicate_security_headers_rejected(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.putrequest("POST", "/mcp")
        connection.putheader("Host", "127.0.0.1:" + str(self.port))
        connection.putheader("Authorization", "Bearer " + self.token)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Accept", "application/json, text/event-stream")
        connection.putheader("Content-Length", "2")
        connection.endheaders(b"{}")
        response = connection.getresponse()
        self.assertEqual(response.status, 403)
        response.read()
        connection.close()

    def test_initialize_notification_list_and_stdio_adapter(self):
        client = GatewayClient(self.state, self.port)
        init = request("initialize", {"protocolVersion": VERSIONS[-1], "capabilities": {}, "clientInfo": {"name": "tests", "version": "1"}})
        notice = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        source = io.BytesIO(b"".join(json.dumps(x).encode() + b"\n" for x in [init, notice, request("tools/list", identifier=2), request("tools/call", {"name": "list_calendars"}, 3)]))
        sink = io.BytesIO()
        self.assertEqual(run_stdio(client, source, sink), 0)
        replies = [json.loads(x) for x in sink.getvalue().splitlines()]
        self.assertEqual(len(replies), 3)
        self.assertEqual(len(replies[1]["result"]["tools"]), 13)
        self.assertEqual(replies[2]["result"]["structuredContent"], {"calendars": []})
        self.assertNotIn(self.token.encode(), sink.getvalue())
        self.assertEqual(self.broker.calls, [("list_calendars", {})])

    def test_stdio_oversize_ends_framing_without_forwarding(self):
        sink = io.BytesIO()
        self.assertEqual(run_stdio(GatewayClient(self.state, self.port), io.BytesIO(b"x" * (MAX_BODY + 1)), sink), 1)
        self.assertEqual(self.broker.calls, [])


class AdapterTests(unittest.TestCase):
    def test_gateway_response_decode_failure_has_uncertain_outcome_guidance(self):
        class Response:
            status = 200

            def __init__(self, body):
                self.body = body

            def read(self, limit):
                return self.body

        class Connection:
            def __init__(self, response):
                self.response = response

            def request(self, *args, **kwargs):
                pass

            def getresponse(self):
                return self.response

            def close(self):
                pass

        for bad in (b'{"result":1e999}', b'{"result":"\\ud800"}', b'{'):
            with self.subTest(response=bad):
                client = GatewayClient.__new__(GatewayClient)
                client.token, client.port, client.state = "synthetic-fixture-token", 8765, "synthetic-state"
                client.resource, client.mcp_path, client.status_path = "calendar", "/mcp", "/status"
                responses = [Connection(Response(bad)), Connection(Response(b'{"jsonrpc":"2.0","id":2,"result":{}}'))]
                sink = io.BytesIO()
                source = io.BytesIO(b"".join(json.dumps(request("ping", identifier=index)).encode() + b"\n" for index in (1, 2)))
                with patch("calendar_mcp.adapter.LocalHTTPConnection", side_effect=responses) as connections:
                    self.assertEqual(run_stdio(client, source, sink), 0)
                first, second = [loads(line) for line in sink.getvalue().splitlines()]
                self.assertEqual(first["id"], 1)
                self.assertEqual(first["error"]["code"], -32603)
                self.assertIn("no retry", first["error"]["message"])
                self.assertIn("get_change_status", first["error"]["message"])
                self.assertEqual(second, {"jsonrpc": "2.0", "id": 2, "result": {}})
                self.assertEqual(connections.call_count, 2)

    def test_invalid_ids_and_malformed_initialize_preserve_next_frame(self):
        class Client:
            def __init__(self):
                self.calls = []
                self.protocol = Protocol(FakeBroker())

            def send(self, wire, version):
                self.calls.append((loads(wire), version))
                return self.protocol.handle(loads(wire))

        client = Client()
        frames = []
        expected = []
        for index, identifier in enumerate((None, True, False, 1.5, [], {})):
            frames.extend((request("initialize", {"protocolVersion": VERSIONS[0]}, identifier), request("ping", identifier=index)))
            expected.extend(((None, -32600), (index, None)))
        for index, params in enumerate((None, [], 7, "invalid", True), start=20):
            frames.extend(({"jsonrpc": "2.0", "id": index, "method": "initialize", "params": params}, request("ping", identifier=str(index))))
            expected.extend(((index, -32602), (str(index), None)))
        # Exponent overflow fails decoding, so its identifier is never reflected.
        raw = b'{"jsonrpc":"2.0","id":1e999,"method":"initialize","params":null}\n'
        frames.append(request("ping", identifier=-1))
        expected.extend(((None, -32700), (-1, None)))
        source = io.BytesIO(b"".join(json.dumps(frame).encode() + b"\n" for frame in frames[:-1]) + raw + json.dumps(frames[-1]).encode() + b"\n")
        sink = io.BytesIO()
        self.assertEqual(run_stdio(client, source, sink), 0)
        replies = [loads(line) for line in sink.getvalue().splitlines()]
        self.assertEqual([(reply["id"], reply.get("error", {}).get("code")) for reply in replies], expected)
        self.assertEqual(len(client.calls), 17)
        self.assertTrue(all(version == VERSIONS[-1] for _, version in client.calls))

    def test_invalid_gateway_result_serialization_is_contained_without_retry(self):
        for invalid in ({"number": float("inf")}, {"text": "\ud800"}, {"unsupported": object()}, {1: "key"}):
            with self.subTest(invalid=repr(invalid)):
                class Client:
                    def __init__(self):
                        self.calls = 0

                    def send(self, wire, version):
                        self.calls += 1
                        return invalid if self.calls == 1 else {"jsonrpc": "2.0", "id": 2, "result": {}}

                client = Client()
                sink = io.BytesIO()
                source = io.BytesIO(b"".join(json.dumps(request("ping", identifier=index)).encode() + b"\n" for index in (1, 2)))
                self.assertEqual(run_stdio(client, source, sink), 0)
                first, second = [loads(line) for line in sink.getvalue().splitlines()]
                self.assertEqual(first["id"], 1)
                self.assertEqual(first["error"]["code"], -32603)
                self.assertIn("no retry", first["error"]["message"])
                self.assertIn("get_change_status", first["error"]["message"])
                self.assertEqual(second, {"jsonrpc": "2.0", "id": 2, "result": {}})
                self.assertEqual(client.calls, 2)


class NativeTransportTests(unittest.TestCase):
    def helper(self, root, program):
        import sys
        path = Path(root) / "fake helper"
        path.write_text("#!" + sys.executable + "\n" + program)
        path.chmod(0o700)
        return path

    def test_one_resident_process_and_serialized_calls(self):
        with tempfile.TemporaryDirectory() as root:
            helper = self.helper(root, 'import sys,json,os\nfor line in sys.stdin:\n r=json.loads(line); print(json.dumps({"result":{"pid":os.getpid(),"op":r["op"]}}),flush=True)\n')
            broker = NativeBroker(helper, root, timeout=2)
            try:
                first = broker.call("list_calendars", {})
                second = broker.call("get_change_status", {"nonce": "x"})
                self.assertEqual(first["pid"], second["pid"])
                self.assertEqual(second["op"], "get_change_status")
            finally:
                broker.close()

    def test_presubmission_validation_preserves_healthy_resident_channel(self):
        with tempfile.TemporaryDirectory() as root:
            helper = self.helper(root, 'import sys,json,os\ncount=0\nfor line in sys.stdin:\n count+=1; print(json.dumps({"result":{"pid":os.getpid(),"count":count}}),flush=True)\n')
            broker = NativeBroker(helper, root, timeout=2)
            try:
                first = broker.call("list_calendars", {})
                for invalid in ({"text": "\ud800"}, {"\udfff": "key"}, {"nested": [float("inf")]},
                                {"nested": [float("nan")]}, {"unsupported": object()}, {1: "key"}):
                    with self.subTest(invalid=repr(invalid)), self.assertRaises(NativeError) as raised:
                        broker.call("commit_create", invalid)
                    self.assertEqual(raised.exception.code, "invalid_arguments")
                    self.assertFalse(broker.failed)
                    self.assertIsNone(broker.process.poll())
                second = broker.call("list_calendars", {})
                self.assertEqual(second, {"pid": first["pid"], "count": 2})
            finally:
                broker.close()

    def test_nonreading_child_bounded_timeout_no_restart_no_retry(self):
        with tempfile.TemporaryDirectory() as root:
            helper = self.helper(root, 'import time\ntime.sleep(60)\n')
            broker = NativeBroker(helper, root, timeout=0.15)
            start = time.monotonic()
            try:
                with self.assertRaises(NativeError) as raised:
                    broker.call("commit_create", {"payload": "x" * MAX_BODY})
                self.assertEqual(raised.exception.code, "outcome_unknown")
                self.assertLess(time.monotonic() - start, 3)
                original_pid = broker.process.pid
                with self.assertRaises(NativeError) as second:
                    broker.call("commit_create", {})
                self.assertEqual(second.exception.code, "broker_unavailable")
                self.assertEqual(broker.process.pid, original_pid)
            finally:
                broker.close()

    def test_large_unicode_review_uses_utf8_within_native_frame_limit(self):
        # Existing snapshot text may exceed editable field limits; it must remain
        # visible and unchanged in a delete preview instead of being truncated.
        calendar = {"id": "calendar", "title": "Fixture", "source": "Synthetic", "writable": True, "subscribed": False}
        fields = {"title": "", "start": "2026-10-23T09:00:00Z", "end": "2026-10-23T10:00:00Z",
                  "time_zone": "GMT+0100", "all_day": False, "location": "", "notes": "🗓" * 60000}
        before = {"id": "event", "calendar": calendar, "occurrence": None, "fields": fields, "recurring": False,
                  "detached": False, "availability": "busy", "status": "confirmed", "has_attendees": False,
                  "has_organizer": False, "fingerprint": "fixture", "details": {}}
        preview = {"envelope": {"version": 1, "nonce": "nonce", "issued_at": "2026-10-23T00:00:00Z",
                                "expires_at": "2026-10-23T00:10:00Z", "installation_id": "installation",
                                "credential_generation": "generation", "key_id": "key", "action": "delete",
                                "scope": "this", "calendar": calendar, "before": before, "after": None},
                   "authentication_tag": "synthetic-wire-fixture-not-an-authenticated-native-preview"}
        arguments = {"preview": preview}
        validate_arguments("commit_delete", arguments)
        with tempfile.TemporaryDirectory() as root:
            helper = self.helper(root, 'import sys,json\nfor line in sys.stdin.buffer:\n r=json.loads(line); print(json.dumps({"result":{"bytes":len(line),"notes":r["arguments"]["preview"]["envelope"]["before"]["fields"]["notes"]}},ensure_ascii=False),flush=True)\n')
            broker = NativeBroker(helper, root, timeout=3)
            try:
                result = broker.call("commit_delete", arguments)
                self.assertLess(result["bytes"], 524288)
                self.assertEqual(result["notes"], fields["notes"])
            finally:
                broker.close()


class ProtectedLocalTransportTests(unittest.TestCase):
    """All fixtures use private temporary state and synthetic credentials only."""
    def setUp(self):
        from calendar_mcp import local_ipc
        self.ipc = local_ipc
        self.temp = tempfile.TemporaryDirectory(prefix="cmgw-test-", dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.state = initialize(self.root / "state")
        self.base = self.root / "base"
        self.base.mkdir(mode=0o700)
        # Exercise the real base validator while isolating every test endpoint.
        self.confstr = patch("calendar_mcp.local_ipc.os.confstr", return_value=str(self.base))
        self.confstr.start()
        self.addCleanup(self.confstr.stop)
        self.addCleanup(self.temp.cleanup)

    def server(self):
        server = GatewayServer(0, read_token(self.state), Protocol(FakeBroker()), state_directory=self.state)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        def close():
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
        self.addCleanup(close)
        return server

    def test_fake_tcp_listener_receives_zero_connections_when_unix_missing_or_unsafe(self):
        import select
        with socket.socket() as fake:
            fake.bind(("127.0.0.1", 0))
            fake.listen(1)
            port = fake.getsockname()[1]
            client = GatewayClient(self.state, port)
            path = self.ipc.gateway_path(self.state, port)
            for mode in ("missing", "public-parent", "regular-file", "symlink", "hardlink"):
                with self.subTest(mode=mode):
                    if mode != "missing":
                        path.parent.mkdir(mode=0o700, exist_ok=True)
                    if mode == "public-parent":
                        path.parent.chmod(0o755)
                    elif mode == "regular-file":
                        path.write_bytes(b"fixture")
                        path.chmod(0o600)
                    elif mode == "symlink":
                        path.symlink_to(self.state / "gateway.token")
                    elif mode == "hardlink":
                        os.link(self.state / "gateway.token", path)
                    for operation in (lambda: client.send(b'{"jsonrpc":"2.0","id":1,"method":"ping"}'), client.status):
                        with self.assertRaises((ValueError, OSError)):
                            operation()
                        self.assertEqual(select.select([fake], [], [], 0)[0], [])
                    if path.exists() or path.is_symlink():
                        path.unlink()
                    if path.parent.exists():
                        path.parent.chmod(0o700)

    def test_connect_rejects_wrong_peer_before_any_http_bytes_and_does_not_retry(self):
        path = self.ipc.gateway_path(self.state, 24680)
        path.parent.mkdir(mode=0o700)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as fake:
            fake.bind(str(path)); path.chmod(0o600); fake.listen(1)
            for operation in (lambda client: client.send(b'{"id":1}'), lambda client: client.status()):
                client = GatewayClient(self.state, 24680)
                with patch("calendar_mcp.local_ipc.peer_uid", return_value=os.getuid() + 1) as check:
                    with self.assertRaises(OSError):
                        operation(client)
                self.assertEqual(check.call_count, 1)
                connection, _ = fake.accept()
                with connection:
                    connection.settimeout(1)
                    self.assertEqual(connection.recv(4096), b"")
            fake.settimeout(0.02)
            with self.assertRaises(TimeoutError):
                fake.accept()

    def test_server_rejects_wrong_peer_before_constructing_http_handler(self):
        server = self.server()
        path = self.ipc.gateway_path(self.state, server.server_port)
        with patch("calendar_mcp.server.require_peer", side_effect=OSError("rejected")), \
                patch("calendar_mcp.server.Handler") as handler:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(1)
                connection.connect(str(path))
                self.assertEqual(connection.recv(4096), b"")
            handler.assert_not_called()
        self.assertEqual(server.protocol.broker.calls, [])

    def test_peer_wrapper_fails_closed_and_real_darwin_pair_has_current_uid(self):
        from unittest.mock import Mock
        left, right = socket.socketpair()
        try:
            self.assertEqual(self.ipc.peer_uid(left), os.getuid())
            library = Mock()
            library.getpeereid.return_value = -1
            with patch("calendar_mcp.local_ipc.ctypes.CDLL", return_value=library), \
                    patch("calendar_mcp.local_ipc.ctypes.get_errno", return_value=13):
                with self.assertRaises(OSError):
                    self.ipc.require_peer(left)
            with patch("calendar_mcp.local_ipc.ctypes.CDLL", side_effect=OSError("unavailable")):
                with self.assertRaises(OSError):
                    self.ipc.require_peer(left)
            with patch("calendar_mcp.local_ipc.sys.platform", "unsupported"):
                with self.assertRaises(OSError):
                    self.ipc.require_peer(left)
        finally:
            left.close(); right.close()

    def test_derivation_uses_canonical_utf8_state_port_and_ignores_tmpdir(self):
        import hashlib
        state = initialize(self.root / ("Unicode e\u0301 👩🏽‍💻 " + "long" * 35))
        canonical = os.path.realpath(state)
        expected = hashlib.sha256(canonical.encode("utf-8") + b"\0" + b"24680").hexdigest()[:20]
        with patch.dict(os.environ, {"TMPDIR": "/tmp/attacker"}):
            path = self.ipc.gateway_path(state, 24680)
        self.assertEqual(path, self.base / ("cmgw-" + expected) / "s")
        self.assertNotEqual(path, self.ipc.gateway_path(state, 24681))
        self.assertLess(len(os.fsencode(path)), 104)
        with patch("calendar_mcp.local_ipc.temporary_base", return_value=self.root / ("x" * 100)):
            with self.assertRaises(ValueError):
                self.ipc.gateway_path(state, 24680)

    def test_unsafe_os_base_and_child_fail_closed(self):
        public = self.root / "public"; public.mkdir(mode=0o755); public.chmod(0o755)
        link = self.root / "link"; link.symlink_to(self.base, target_is_directory=True)
        for value in (str(public), str(link), "relative", None):
            with self.subTest(value=value), patch("calendar_mcp.local_ipc.os.confstr", return_value=value):
                with self.assertRaises(ValueError):
                    self.ipc.gateway_path(self.state, 24680)
        with patch("calendar_mcp.local_ipc.os.getuid", return_value=os.getuid() + 1):
            with self.assertRaises(ValueError):
                self.ipc.temporary_base()
        path = self.ipc.gateway_path(self.state, 24680)
        path.parent.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.ipc.LocalHTTPConnection(self.state, 24680).connect()

    def test_authentic_unix_requests_repeat_path_and_peer_validation(self):
        server = self.server()
        client = GatewayClient(self.state, server.server_port)
        with patch("calendar_mcp.local_ipc.require_peer", wraps=self.ipc.require_peer) as peer, \
                patch("calendar_mcp.local_ipc.validate_socket", wraps=self.ipc.validate_socket) as path:
            self.assertEqual(client.send(json.dumps(request("ping")).encode())["result"], {})
            self.assertEqual(client.status()["gateway"], "reachable")
        self.assertEqual(peer.call_count, 2)
        self.assertEqual(path.call_count, 2)
        # Both listeners share protocol and the same eight-slot budget.
        self.assertIs(server._unix.protocol, server.protocol)
        self.assertIs(server._unix.slots, server.slots)
        # The response can arrive before the request worker's finally releases its
        # slot. Wait for that cleanup before reserving the full shared budget.
        for _ in range(8):
            self.assertTrue(server.slots.acquire(timeout=1))
        try:
            with self.assertRaises((OSError, http.client.HTTPException)):
                client.status(timeout=1)
            self.assertFalse(server.slots.acquire(False))
        finally:
            for _ in range(8):
                server.slots.release()

    def test_startup_refuses_unsafe_existing_nodes_and_closes_tcp_on_failure(self):
        path = self.ipc.gateway_path(self.state, 24680)
        path.parent.mkdir(mode=0o700)
        captured = []
        original = GatewayServer.server_bind
        def bind(server):
            original(server)
            captured.append(server.socket)
        for node in ("regular", "symlink", "hardlink", "public-socket"):
            with self.subTest(node=node):
                connection = None
                if node == "regular":
                    path.write_bytes(b"fixture"); path.chmod(0o600)
                elif node == "symlink":
                    path.symlink_to(self.state / "gateway.token")
                elif node == "hardlink":
                    os.link(self.state / "gateway.token", path)
                else:
                    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    connection.bind(str(path)); path.chmod(0o666)
                try:
                    with patch("calendar_mcp.server.gateway_path", return_value=path), \
                            patch.object(GatewayServer, "server_bind", bind):
                        with self.assertRaises(ValueError):
                            GatewayServer(0, "fixture", Protocol(FakeBroker()), state_directory=self.state)
                    self.assertEqual(captured[-1].fileno(), -1)
                    self.assertTrue(path.exists())
                finally:
                    if connection is not None:
                        connection.close()
                    path.unlink()

    def test_socket_metadata_and_startup_lock_reject_links_modes_and_wrong_owner(self):
        path = self.ipc.gateway_path(self.state, 24680)
        path.parent.mkdir(mode=0o700)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as endpoint:
            endpoint.bind(str(path)); path.chmod(0o600)
            actual = path.lstat()
            with patch("calendar_mcp.local_ipc.Path.lstat", side_effect=lambda item=None: actual):
                # Wrong-owner check is isolated from directory validation.
                with patch("calendar_mcp.local_ipc.validate_directory"), \
                        patch("calendar_mcp.local_ipc.os.getuid", return_value=actual.st_uid + 1):
                    with self.assertRaises(ValueError):
                        self.ipc.validate_socket(path)
            twin = path.parent / "linked"
            os.link(path, twin)
            with self.assertRaises(ValueError):
                self.ipc.validate_socket(path)
            twin.unlink()
        path.unlink()
        lock = path.parent / "owner.lock"
        for kind in ("symlink", "hardlink", "public"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    lock.symlink_to(self.state / "gateway.token")
                elif kind == "hardlink":
                    os.link(self.state / "gateway.token", lock)
                else:
                    lock.write_bytes(b"fixture"); lock.chmod(0o644)
                with patch("calendar_mcp.server.gateway_path", return_value=path):
                    with self.assertRaises((ValueError, OSError)):
                        GatewayServer(0, "fixture", Protocol(FakeBroker()), state_directory=self.state)
                self.assertTrue(lock.exists())
                self.assertFalse(path.exists())
                lock.unlink()

    def test_exclusive_startup_and_inode_safe_cleanup_preserve_replacements(self):
        from calendar_mcp.server import UnixGatewayServer
        path = self.ipc.gateway_path(self.state, 24680)
        with patch("calendar_mcp.server.gateway_path", return_value=path):
            first = GatewayServer(0, "fixture", Protocol(FakeBroker()), state_directory=self.state)
            try:
                with self.assertRaises(OSError):
                    GatewayServer(0, "fixture", Protocol(FakeBroker()), state_directory=self.state)
                identity = path.lstat().st_ino
                self.assertEqual(identity, first._endpoint_identity[1])
                path.unlink()
                path.write_bytes(b"replacement")
                first.shutdown()  # Must be safe before serving starts.
            finally:
                first.server_close()
            self.assertEqual(path.read_bytes(), b"replacement")
            path.unlink()
            # Reclaim a genuine stale owned socket only under exclusive lock.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
                stale.bind(str(path)); path.chmod(0o600)
            again = GatewayServer(0, "fixture", Protocol(FakeBroker()), state_directory=self.state)
            again.server_close()
            self.assertFalse(path.exists())
            with patch.object(UnixGatewayServer, "server_activate", side_effect=OSError("fixture")):
                with self.assertRaises(OSError):
                    GatewayServer(0, "fixture", Protocol(FakeBroker()), state_directory=self.state)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
