"""Actual broker + HTTP + stdio integration, always synthetic and temporary."""

import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
import unittest

from calendar_mcp.adapter import GatewayClient
from calendar_mcp.native import NativeBroker
from calendar_mcp.protocol import Protocol
from calendar_mcp.security import initialize, private_directory, read_token
from calendar_mcp.server import GatewayServer

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HELPER = next((path for path in (ROOT / ".build/out/Products/Debug/CalendarHelper", ROOT / ".build/debug/CalendarHelper") if path.is_file()), ROOT / ".build/debug/CalendarHelper")
HELPER = Path(os.environ.get("CALENDAR_MCP_TEST_HELPER", str(DEFAULT_HELPER)))


@unittest.skipUnless(HELPER.is_file(), "Build native helper with swift build before end-to-end synthetic validation")
class NativeIntegrationTests(unittest.TestCase):
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
                    completed = stdio_tool("commit_" + action, prepared)
                    self.assertEqual(completed["state"], "applied")
                    self.assertEqual(completed, stdio_tool("commit_" + action, prepared))
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
                rejected = client.send(json.dumps({"jsonrpc": "2.0", "id": 91, "method": "tools/call", "params": {"name": "commit_create", "arguments": unexecuted}}).encode())
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


if __name__ == "__main__":
    unittest.main()
