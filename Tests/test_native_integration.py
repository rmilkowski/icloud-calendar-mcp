"""Actual broker + HTTP + stdio integration, always synthetic and temporary."""

import hashlib
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

from calendar_mcp.adapter import GatewayClient
from calendar_mcp.changes import socket_path
from calendar_mcp.native import NativeBroker
from calendar_mcp.protocol import Protocol
from calendar_mcp.security import initialize, private_directory, read_token
from calendar_mcp.server import GatewayServer

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HELPER = next((path for path in (ROOT / ".build/out/Products/Debug/CalendarHelper", ROOT / ".build/debug/CalendarHelper") if path.is_file()), ROOT / ".build/debug/CalendarHelper")
HELPER = Path(os.environ.get("CALENDAR_MCP_TEST_HELPER", str(DEFAULT_HELPER)))


@unittest.skipUnless(HELPER.is_file(), "Build native helper with swift build before end-to-end synthetic validation")
class NativeIntegrationTests(unittest.TestCase):
    def test_invalid_json_keeps_synthetic_native_http_stdio_channel_healthy(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic invalid json ") as directory:
            state = initialize(Path(directory) / "gateway")
            token = read_token(state)
            native = private_directory(state / "native-synthetic")
            broker = NativeBroker(HELPER, native, "synthetic", credential_binding=hashlib.sha256(token.encode()).hexdigest())
            server = GatewayServer(0, token, Protocol(broker))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            adapter = None
            try:
                client = GatewayClient(state, server.server_port)
                original_pid = broker.process.pid
                good = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_calendars"}}).encode()
                bad = [b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_event","arguments":{"event_id":"\\ud800"}}}',
                       b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_event","arguments":{"\\udfff":0}}}',
                       b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_event","arguments":{"event_id":{"nested":[1e999]}}}}']
                for wire in bad:
                    with self.assertRaises(ValueError):
                        client.send(wire)
                    self.assertFalse(client.send(good)["result"]["isError"])
                    self.assertFalse(broker.failed)
                    self.assertEqual(broker.process.pid, original_pid)
                adapter = subprocess.Popen([sys.executable, "-m", "calendar_mcp", "stdio", "--state-dir", str(state), "--port", str(server.server_port)],
                                           cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                for wire in bad:
                    adapter.stdin.write(wire + b"\n")
                    adapter.stdin.flush()
                    self.assertTrue(select.select([adapter.stdout], [], [], 5)[0], "stdio rejection timed out")
                    self.assertEqual(json.loads(adapter.stdout.readline())["error"]["code"], -32700)
                    adapter.stdin.write(good + b"\n")
                    adapter.stdin.flush()
                    self.assertTrue(select.select([adapter.stdout], [], [], 5)[0], "stdio recovery timed out")
                    self.assertFalse(json.loads(adapter.stdout.readline())["result"]["isError"])
                self.assertFalse(broker.failed)
                self.assertEqual(broker.process.pid, original_pid)
                adapter.stdin.close()
                self.assertEqual(adapter.wait(timeout=3), 0)
                self.assertEqual(adapter.stderr.read(), b"")
            finally:
                if adapter is not None:
                    if adapter.poll() is None:
                        adapter.terminate()
                        adapter.wait(timeout=3)
                    for pipe in (adapter.stdin, adapter.stdout, adapter.stderr):
                        pipe.close()
                server.shutdown()
                server.server_close()
                thread.join()
                broker.close()

    def test_native_http_retained_history_pagination_and_signed_recovery(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic recovery ") as directory:
            state = initialize(Path(directory) / "gateway")
            token = read_token(state)
            native = private_directory(state / "native-synthetic")
            broker = NativeBroker(HELPER, native, "synthetic", credential_binding=hashlib.sha256(token.encode()).hexdigest())
            if broker.recovery_capabilities() is None:
                broker.close()
                self.skipTest("Selected native helper does not implement recovery storage v2")
            # Match the real native endpoint across Python/POSIX canonicalization,
            # using a long state path; no review window or Apply control is opened.
            try:
                endpoint = socket_path(native)
                endpoint_info = endpoint.lstat()
                self.assertTrue(stat.S_ISSOCK(endpoint_info.st_mode))
                self.assertEqual(stat.S_IMODE(endpoint_info.st_mode), 0o600)
                self.assertEqual(endpoint_info.st_uid, os.getuid())
                self.assertEqual(endpoint_info.st_nlink, 1)
                self.assertEqual(stat.S_IMODE(endpoint.parent.lstat().st_mode), 0o700)
            except BaseException:
                broker.close()
                raise
            server = GatewayServer(0, token, Protocol(broker))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                counter = 0

                def tool(name, arguments=None):
                    nonlocal counter
                    counter += 1
                    response = client.send(json.dumps({"jsonrpc": "2.0", "id": counter, "method": "tools/call",
                               "params": {"name": name, "arguments": arguments or {}}}).encode())
                    self.assertNotIn("error", response, response)
                    self.assertFalse(response["result"]["isError"], response)
                    return response["result"]["structuredContent"]

                calendar = tool("list_calendars")["calendars"][0]["id"]
                created = []
                for index in range(2):
                    preview = tool("preflight_change", {"action": "create", "scope": "this", "calendar_id": calendar,
                                   "fields": {"title": f"Recovery original {index}", "start": "2026-10-25T10:00:00Z",
                                              "end": "2026-10-25T11:00:00Z", "notes": f"Retained fixture {index}"}})["preview"]
                    created.append(tool("commit_create", {"preview": preview})["event"])
                sources = []
                for action, event in (("modify", created[0]), ("delete", created[1])):
                    arguments = {"action": action, "scope": "this", "event_id": event["id"]}
                    if action == "modify":
                        arguments["fields"] = {"title": "Modified recovery fixture"}
                    preview = tool("preflight_change", arguments)["preview"]
                    completed = tool("commit_" + action, {"preview": preview})
                    sources.append(completed["nonce"])
                first = tool("list_changes", {"limit": 1})
                self.assertEqual(len(first["changes"]), 1)
                self.assertIsNotNone(first["next_cursor"])
                second = tool("list_changes", {"limit": 1, "cursor": first["next_cursor"]})
                self.assertEqual(first["snapshot_at"], second["snapshot_at"])
                self.assertIsNone(second["next_cursor"])
                self.assertEqual({first["changes"][0]["change_id"], second["changes"][0]["change_id"]}, set(sources))
                stored = tool("get_stored_change", {"change_id": sources[0]})
                self.assertEqual(stored["before"]["fields"]["title"], "Recovery original 0")
                self.assertEqual(stored["proposed_after"]["title"], "Modified recovery fixture")
                self.assertFalse(stored["change"]["details_expired"])
                plan = tool("preflight_rollback", {"change_ids": sources})
                self.assertFalse(plan["atomic"])
                self.assertEqual(plan["selected_count"], 2)
                self.assertEqual(plan["step_count"], 2)
                self.assertEqual(set(plan["selected_change_ids"]), set(sources))
                for step in plan["steps"]:
                    preview = step["preview"]
                    # The ordinary tools cannot bypass the separate recovery contract.
                    counter += 1
                    rejected = client.send(json.dumps({"jsonrpc": "2.0", "id": counter, "method": "tools/call",
                                           "params": {"name": "commit_" + preview["envelope"]["action"],
                                                      "arguments": {"preview": preview}}}).encode())
                    self.assertEqual(rejected["error"]["code"], -32602)
                    completed = tool("commit_rollback", {"preview": preview})
                    self.assertEqual(completed["state"], "applied")
                    self.assertEqual(tool("commit_rollback", {"preview": preview}), completed)
                    self.assertEqual(tool("get_change_status", {"nonce": completed["nonce"]}), completed)
                events = tool("query_events", {"start": "2026-10-25T00:00:00Z", "end": "2026-10-26T00:00:00Z"})["events"]
                self.assertEqual({event["fields"]["title"] for event in events}, {"Recovery original 0", "Recovery original 1"})
                for source in sources:
                    detail = tool("get_stored_change", {"change_id": source})
                    self.assertIsNotNone(detail["change"]["rolled_back_by"])
                    self.assertFalse(detail["change"]["recovery_eligible"])
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                broker.close()

    def test_native_http_stdio_full_lifecycle_replay_and_tamper(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic integration ") as directory:
            state = initialize(Path(directory) / "gateway")
            token = read_token(state)
            native = private_directory(state / "native-synthetic")
            broker = NativeBroker(HELPER, native, "synthetic", credential_binding=hashlib.sha256(token.encode()).hexdigest())
            server = GatewayServer(0, token, Protocol(broker))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            adapter = None
            try:
                client = GatewayClient(state, server.server_port)
                counter = 0

                def http_tool(name, arguments=None):
                    nonlocal counter
                    counter += 1
                    response = client.send(json.dumps({"jsonrpc": "2.0", "id": counter, "method": "tools/call", "params": {"name": name, "arguments": arguments or {}}}).encode())
                    self.assertNotIn("error", response, response)
                    self.assertFalse(response["result"].get("isError"), response)
                    return response["result"]["structuredContent"]

                calendars = http_tool("list_calendars")["calendars"]
                self.assertEqual(calendars[0]["source"], "Synthetic")
                draft = http_tool("preflight_change", {"action": "create", "scope": "this", "calendar_id": calendars[0]["id"],
                                                       "fields": {"title": "Synthetic transport fixture", "start": "2026-10-23T10:00:00+01:00", "end": "2026-10-23T11:00:00+01:00"}})
                preview = draft["preview"]
                self.assertEqual(preview["envelope"]["after"]["time_zone"], "Europe/London")
                # Complete native preview is round-tripped unchanged through published strict schema.
                created = http_tool("commit_create", {"preview": preview})
                self.assertEqual(created["state"], "applied")
                self.assertEqual(created, http_tool("commit_create", {"preview": preview}))
                self.assertEqual(created, http_tool("get_change_status", {"nonce": preview["envelope"]["nonce"]}))

                altered = json.loads(json.dumps(preview))
                altered["envelope"]["after"]["title"] = "Tampered fixture"
                raw = client.send(json.dumps({"jsonrpc": "2.0", "id": 90, "method": "tools/call", "params": {"name": "commit_create", "arguments": {"preview": altered}}}).encode())
                self.assertTrue(raw["result"]["isError"])

                adapter = subprocess.Popen([sys.executable, "-m", "calendar_mcp", "stdio", "--state-dir", str(state), "--port", str(server.server_port)],
                                           cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)

                def stdio(method, params=None):
                    nonlocal counter
                    counter += 1
                    adapter.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter, "method": method, "params": params or {}}).encode() + b"\n")
                    adapter.stdin.flush()
                    self.assertTrue(select.select([adapter.stdout], [], [], 5)[0], "stdio reply timed out")
                    reply = json.loads(adapter.stdout.readline())
                    self.assertNotIn("error", reply, reply)
                    return reply["result"]

                def stdio_tool(name, arguments=None):
                    reply = stdio("tools/call", {"name": name, "arguments": arguments or {}})
                    self.assertFalse(reply.get("isError"), reply)
                    return reply["structuredContent"]

                stdio("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "integration", "version": "1"}})
                event_id = created["event"]["id"]
                self.assertEqual(stdio_tool("get_event", {"event_id": event_id})["event"]["fields"]["title"], "Synthetic transport fixture")
                window = {"start": "2026-10-23T00:00:00Z", "end": "2026-10-24T00:00:00Z", "calendar_ids": [calendars[0]["id"]]}
                self.assertEqual(len(stdio_tool("query_events", window)["events"]), 1)
                availability = stdio_tool("get_availability", window)
                self.assertTrue(availability["snapshot_only"])
                self.assertEqual(len(availability["busy"]), 1)

                for action, patch in [("modify", {"fields": {"title": "Modified fixture"}}), ("delete", {})]:
                    prepared = stdio_tool("preflight_change", {"action": action, "scope": "this", "event_id": event_id, **patch})
                    self.assertIn("details", prepared["preview"]["envelope"]["before"])
                    completed = stdio_tool("commit_" + action, {"preview": prepared["preview"]})
                    self.assertEqual(completed["state"], "applied")
                    self.assertEqual(completed, stdio_tool("commit_" + action, {"preview": prepared["preview"]}))
                self.assertEqual(stdio_tool("query_events", window)["events"], [])
                adapter.stdin.close()
                self.assertEqual(adapter.wait(timeout=3), 0)
                self.assertEqual(adapter.stderr.read(), b"")

                # Rotate the actual local credential with both processes stopped. Native
                # launch binding must invalidate old previews and retain durable outcomes.
                unexecuted = http_tool("preflight_change", {"action": "create", "scope": "this", "calendar_id": calendars[0]["id"],
                                                           "fields": {"title": "Rotate fixture", "start": "2026-10-23T12:00:00+01:00", "end": "2026-10-23T13:00:00+01:00"}})
                server.shutdown()
                server.server_close()
                thread.join()
                broker.close()
                (state / "gateway.token").unlink()
                initialize(state)
                new_token = read_token(state)
                self.assertNotEqual(token, new_token)
                broker = NativeBroker(HELPER, native, "synthetic", credential_binding=hashlib.sha256(new_token.encode()).hexdigest())
                server = GatewayServer(0, new_token, Protocol(broker))
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
                thread.start()
                client = GatewayClient(state, server.server_port)
                rejected = client.send(json.dumps({"jsonrpc": "2.0", "id": 91, "method": "tools/call", "params": {"name": "commit_create", "arguments": {"preview": unexecuted["preview"]}}}).encode())
                self.assertTrue(rejected["result"]["isError"])
                self.assertEqual(http_tool("get_change_status", {"nonce": completed["nonce"]}), completed)
            finally:
                if adapter is not None:
                    if adapter.poll() is None:
                        adapter.terminate()
                        adapter.wait(timeout=3)
                    for pipe in (adapter.stdin, adapter.stdout, adapter.stderr):
                        pipe.close()
                server.shutdown()
                server.server_close()
                thread.join()
                broker.close()

    def test_native_http_quota_feedback_and_commit_recheck(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic safety ") as directory:
            state = initialize(Path(directory) / "gateway")
            token = read_token(state)
            native = private_directory(state / "native-synthetic")
            broker = NativeBroker(HELPER, native, "synthetic", credential_binding=hashlib.sha256(token.encode()).hexdigest())
            server = GatewayServer(0, token, Protocol(broker))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                counter = 0

                def tool(name, arguments=None, error=None):
                    nonlocal counter
                    counter += 1
                    response = client.send(json.dumps({"jsonrpc": "2.0", "id": counter, "method": "tools/call", "params": {"name": name, "arguments": arguments or {}}}).encode())
                    self.assertNotIn("error", response, response)
                    if error:
                        self.assertTrue(response["result"]["isError"], response)
                        failure = json.loads(response["result"]["content"][0]["text"])
                        self.assertEqual(failure["code"], error)
                        return failure
                    self.assertFalse(response["result"]["isError"], response)
                    return response["result"]["structuredContent"]

                calendar = tool("list_calendars")["calendars"][0]["id"]
                events = []
                for index in range(2):
                    draft = tool("preflight_change", {"action": "create", "scope": "this", "calendar_id": calendar,
                                "fields": {"title": f"Safety fixture {index}", "start": "2026-10-25T10:00:00Z", "end": "2026-10-25T11:00:00Z"}})
                    self.assertFalse(draft["safety"]["applies"])
                    events.append(tool("commit_create", {"preview": draft["preview"]})["event"]["id"])
                drafts = [tool("preflight_change", {"action": "delete", "scope": "this", "event_id": event}) for event in events]
                self.assertEqual(drafts[0]["safety"]["policy"]["delete_hour"], 50)
                # A policy can tighten after preflight; authenticated payload stays exact.
                policy = native / "write-safety.json"
                policy.write_text(json.dumps({"version": 1, "delete_hour": 1, "delete_day": 1, "destructive_hour": 1, "destructive_day": 1}))
                policy.chmod(0o600)
                applied = tool("commit_delete", {"preview": drafts[0]["preview"]})
                self.assertEqual(applied["state"], "applied")
                self.assertEqual(tool("commit_delete", {"preview": drafts[0]["preview"]}), applied)
                failure = tool("commit_delete", {"preview": drafts[1]["preview"]}, error="write_safety_limit")
                self.assertIn("retry no earlier than", failure["message"])
                nonce = drafts[1]["preview"]["envelope"]["nonce"]
                self.assertEqual(tool("get_change_status", {"nonce": nonce})["state"], "not_received")
                feedback = tool("preflight_change", {"action": "delete", "scope": "this", "event_id": events[1]})["safety"]
                self.assertFalse(feedback["allowed_now"])
                self.assertEqual(feedback["usage"]["delete_hour"]["used"], 1)
                policy.unlink()
                tool("preflight_change", {"action": "delete", "scope": "this", "event_id": events[1]}, error="write_safety_configuration")
                self.assertEqual(tool("commit_delete", {"preview": drafts[0]["preview"]}), applied)
                self.assertEqual(tool("get_event", {"event_id": events[1]})["event"]["id"], events[1])
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                broker.close()


if __name__ == "__main__":
    unittest.main()
