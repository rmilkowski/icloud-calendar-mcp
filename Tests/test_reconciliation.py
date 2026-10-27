# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Journal assessment schemas and transports use synthetic data only."""
from copy import deepcopy
import io
import json
from pathlib import Path
import tempfile
import sqlite3
import hashlib
import threading
import unittest

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import (RECONCILIATION_CAPABILITIES, RECOVERY_CAPABILITIES,
    valid_reconciliation_capabilities, NativeBroker)
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.schema import (RECONCILIATION_LIMITATIONS, RECONCILIATION_TOOL_NAMES,
    ValidationError, validate_arguments)
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from Tests.test_alerts import request
from Tests.test_all_day_dates import CivilBroker
from Tests.test_recurrence import ordinary_preview
from Tests.test_native_integration import HELPER


class AssessmentBroker(CivilBroker):
    def reconciliation_capabilities(self): return deepcopy(RECONCILIATION_CAPABILITIES)


def assessment_preview():
    original = ordinary_preview("create")["envelope"]
    return {"envelope": {"version": 1, "kind": "journal_reconciliation", "action": "reconcile",
        "nonce": "01234567-0123-4567-8901-234567890ABC", "issued_at": "2028-01-01T10:00:00Z",
        "expires_at": "2028-01-01T10:10:00Z", "installation_id": "installation",
        "credential_generation": "generation", "key_id": "key",
        "source": {"change_id": "source", "payload_digest": "a" * 64, "result_digest": "b" * 64,
                   "payload": original, "result": {"nonce": "source", "state": "unknown"}},
        "assessment": {"outcome": "applied", "evidence": "The user inspected the exact event."},
        "limitations": list(RECONCILIATION_LIMITATIONS)}, "authentication_tag": "signed-by-native"}


class ReconciliationTests(unittest.TestCase):
    def test_exact_capability_types_floor_and_legacy_contracts(self):
        self.assertTrue(valid_reconciliation_capabilities(RECONCILIATION_CAPABILITIES))
        current = Protocol(AssessmentBroker()); old = Protocol(CivilBroker())
        self.assertEqual(len(current.tools), 22); self.assertEqual(len(old.tools), 19)
        self.assertEqual([tool for tool in current.tools if tool["name"] not in RECONCILIATION_TOOL_NAMES], old.tools)
        for floor in (6, 7):
            broker = AssessmentBroker()
            broker.recovery_capabilities = lambda floor=floor: {**RECOVERY_CAPABILITIES, "storage_version": floor}
            upgraded = Protocol(broker)
            self.assertTrue(upgraded.reconciliation)
            self.assertTrue(upgraded.all_day_dates)
            self.assertEqual(upgraded.tools, current.tools)
            guidance = upgraded.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {}}})["result"]["instructions"]
            if floor == 7:
                self.assertIn("provider_mutation:not_entered", guidance)
                self.assertIn("refresh the calendar plugin tool definitions", guidance)
                self.assertIn("can hold the entire calendar", guidance)
            else:
                self.assertNotIn("provider_mutation:not_entered", guidance)
        for key, value in RECONCILIATION_CAPABILITIES.items():
            bad = deepcopy(RECONCILIATION_CAPABILITIES)
            if type(value) is bool: bad[key] = int(value)
            elif type(value) is int: bad[key] = True
            elif type(value) is list: bad[key] = [1]
            else: bad[key] = None
            self.assertFalse(valid_reconciliation_capabilities(bad))
            broker = AssessmentBroker(); broker.reconciliation_capabilities = lambda: bad
            self.assertFalse(Protocol(broker).reconciliation)
        for floor in (2, 3, 4, 5, 8, True, 6.0):
            broker = AssessmentBroker(); broker.recovery_capabilities = lambda: {**RECOVERY_CAPABILITIES, "storage_version": floor}
            broker.reconciliation_capabilities = lambda: self.fail("Unrecognized floor must not probe assessment")
            self.assertFalse(Protocol(broker).reconciliation)
        reply = old.handle(request("commit_reconciliation", {"preview": assessment_preview()}))
        self.assertTrue(reply["result"]["isError"])

    def test_exact_schema_assessment_limits_and_annotations(self):
        for tool in Protocol(AssessmentBroker()).tools:
            if tool["name"] in RECONCILIATION_TOOL_NAMES:
                self.assertEqual(tool["annotations"], {"readOnlyHint": tool["name"] != "commit_reconciliation",
                    "destructiveHint": tool["name"] == "commit_reconciliation", "idempotentHint": True, "openWorldHint": False})
        validate_arguments("commit_reconciliation", {"preview": assessment_preview()}, reconciliation=True)
        for args in ({"change_id": "source", "outcome": "applied", "evidence": " "},
                     {"change_id": "source", "outcome": "unknown", "evidence": "evidence"},
                     {"change_id": "source", "outcome": "applied", "evidence": "x" * 2001},
                     {"change_id": "source", "outcome": "applied", "evidence": "evidence", "approved": True}):
            with self.assertRaises(ValidationError): validate_arguments("preflight_reconciliation", args, reconciliation=True)
        for mutate in (lambda p: p.update(extra=True), lambda p: p["envelope"].update(extra=True),
                       lambda p: p["envelope"].update(kind="calendar_change"),
                       lambda p: p["envelope"]["limitations"].reverse(),
                       lambda p: p["envelope"]["assessment"].update(evidence=" ")):
            p = assessment_preview(); mutate(p)
            with self.assertRaises(ValidationError): validate_arguments("commit_reconciliation", {"preview": p}, reconciliation=True)

    def test_complete_twenty_two_tool_http_stdio_and_preview_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="calendar journal transport ") as directory:
            state = initialize(Path(directory) / "state"); broker = AssessmentBroker()
            broker.recovery_capabilities = lambda: {**RECOVERY_CAPABILITIES, "storage_version": 7}
            protocol = Protocol(broker)
            server = GatewayServer(0, read_token(state), protocol, state_directory=state)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True); thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                result = client.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode())
                self.assertEqual(len(result["result"]["tools"]), 22)
                self.assertLess(len(json.dumps(result).encode()), MAX_RESPONSE)
                self.assertEqual(loads(json.dumps(result), max_depth=32), result)
                for name, args in (("list_unresolved_changes", {"limit": 100}),
                                   ("preflight_reconciliation", {"change_id": "source", "outcome": "applied", "evidence": "User assessment"}),
                                   ("commit_reconciliation", {"preview": assessment_preview()})):
                    call = request(name, args); sink = io.BytesIO()
                    self.assertEqual(run_stdio(client, io.BytesIO(json.dumps(call).encode() + b"\n"), sink), 0)
                    self.assertFalse(json.loads(sink.getvalue())["result"]["isError"])
                    self.assertEqual(broker.received, (name, args))
                initialized = protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {}}})["result"]["instructions"]
                self.assertIn("commit_reconciliation", initialized); self.assertNotIn("require evidence-based local reconciliation", initialized)
                self.assertIn("original source change_id", initialized); self.assertIn("reconciliation nonce is not a Calendar execution nonce", initialized)
            finally:
                server.shutdown(); server.server_close(); thread.join()


@unittest.skipUnless(HELPER.is_file(), "Build native helper for synthetic journal integration")
class NativeReconciliationTests(unittest.TestCase):
    def test_actual_native_unknown_creation_assessment_full_http_stdio_and_replay(self):
        with tempfile.TemporaryDirectory(prefix="calendar journal native transport ") as directory:
            state = initialize(Path(directory) / "gateway"); native = Path(directory) / "native"
            binding = hashlib.sha256(b"journal-native-synthetic").hexdigest()
            broker = NativeBroker(HELPER, native, "synthetic", credential_binding=binding)
            try:
                calendar = broker.call("list_calendars", {})["calendars"][0]["id"]
                original = broker.call("preflight_change", {"action": "create", "scope": "this", "calendar_id": calendar,
                    "fields": {"title": "Synthetic journal fixture", "start": "2030-01-01T10:00:00Z",
                               "end": "2030-01-01T11:00:00Z", "time_zone": "UTC"}})["preview"]
                created = broker.call("commit_create", {"preview": original})
                self.assertEqual(created["state"], "applied")
            finally: broker.close()
            # Offline synthetic crash fixture: startup must recover the stranded intent
            # conservatively, producing its own encrypted unknown result.
            with sqlite3.connect(native / "state.sqlite3") as connection:
                connection.execute("UPDATE executions SET state='intent_recorded' WHERE nonce=?", (created["nonce"],))
            broker = NativeBroker(HELPER, native, "synthetic", credential_binding=binding)
            protocol = Protocol(broker); self.assertTrue(protocol.reconciliation)
            server = GatewayServer(0, read_token(state), protocol, state_directory=state)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True); thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                def call(name, args=None, stdio=False):
                    wire = json.dumps(request(name, args), ensure_ascii=False).encode()
                    if stdio:
                        sink = io.BytesIO(); self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                        response = json.loads(sink.getvalue())
                    else: response = client.send(wire)
                    self.assertNotIn("error", response, response); self.assertFalse(response["result"]["isError"], response)
                    return response["result"]["structuredContent"]
                for stdio in (False, True):
                    wire = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
                    if stdio:
                        sink = io.BytesIO(); run_stdio(client, io.BytesIO(wire + b"\n"), sink); response = json.loads(sink.getvalue())
                    else: response = client.send(wire)
                    self.assertEqual(len(response["result"]["tools"]), 22)
                    self.assertEqual(response["result"]["tools"], protocol.tools)
                inventory = call("list_unresolved_changes", {"limit": 1})
                self.assertEqual(inventory["changes"][0]["change_id"], created["nonce"])
                unknown = call("get_stored_change", {"change_id": created["nonce"]})["execution_result"]
                self.assertEqual(unknown["state"], "unknown")
                assessment = call("preflight_reconciliation", {"change_id": created["nonce"], "outcome": "applied",
                    "evidence": "Synthetic user assessment é😀"}, stdio=True)["preview"]
                self.assertEqual(assessment["envelope"]["source"]["payload"], original["envelope"])
                self.assertEqual(assessment["envelope"]["source"]["result"], unknown)
                receipt = call("commit_reconciliation", {"preview": assessment})
                self.assertEqual(receipt["state"], "reconciled")
                self.assertEqual(call("commit_reconciliation", {"preview": assessment}, stdio=True), receipt)
                reconciled = call("get_change_status", {"nonce": created["nonce"]})
                self.assertEqual(reconciled["previous_result"], unknown)
                self.assertEqual(call("commit_create", {"preview": original}), reconciled)
                self.assertEqual(call("list_unresolved_changes")["changes"], [])
            finally:
                server.shutdown(); server.server_close(); thread.join(); broker.close()
