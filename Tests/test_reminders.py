# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Optional Reminders contracts use synthetic fixtures and temporary state only."""

import json
from copy import deepcopy
from contextlib import closing, redirect_stdout, redirect_stderr
import io
import os
import hashlib
from pathlib import Path
import sys
import tempfile
import threading
import subprocess
import sqlite3
import unittest
from unittest.mock import patch

from calendar_mcp.native import NativeBroker, NativeError, REMINDERS_CAPABILITIES, valid_reminders_capabilities
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.reminders_schema import (REMINDER_FIELDS, MAX_REMINDER_SNAPSHOT, REMINDER_LIMITATIONS,
    REMINDER_RECONCILIATION_LIMITATIONS, REMINDER_MASK_NAMES, REMINDER_TOOLS, REMINDER_TOOL_NAMES,
    bound_reminder_json, validate_civil_date, validate_reminder_date, validate_reminder_arguments)
from calendar_mcp.schema import ValidationError, validate
from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from calendar_mcp.security import initialize, read_token
from calendar_mcp.__main__ import main
from calendar_mcp import reminders
from Tests.test_reconciliation import AssessmentBroker
from Tests.test_recurrence import ordinary_preview
from Tests.test_alerts import request


def reminder_snapshot(completed=False):
    return {"id": "reminder-fixture", "list_id": "list-fixture", "fields": {
        "title": "Reminder fixture", "notes": "", "priority": 0, "start": None, "due": None},
        "completed": completed, "completion_date": "2028-01-01T10:00:00Z" if completed else None,
        "details": {"alarms": []}, "fingerprint": "a" * 64, "unsupported_reasons": []}


def reminder_preview(action="modify", *, source_action=None):
    before = None if action == "create" else reminder_snapshot(completed=action == "reopen")
    after = None if action == "delete" else {"fields": deepcopy((before or reminder_snapshot())["fields"]), "completed": action == "complete"}
    masks = {"create": list(REMINDER_MASK_NAMES), "modify": ["title"], "complete": ["completed"], "reopen": ["completed"], "delete": []}
    if action == "create":
        after["fields"]["alerts"] = []
    elif action == "modify":
        after["fields"]["title"] = "Changed reminder"
    envelope = {"version": 1, "domain": "reminders", "nonce": "reminder-nonce",
        "issued_at": "2028-01-01T10:00:00Z", "expires_at": "2028-01-01T10:10:00Z",
        "installation_id": "reminders-installation", "credential_generation": "generation", "key_id": "key",
        "action": action, "scope": "this", "list": {"id": "list-fixture", "title": "Fixture list", "source": "Synthetic", "writable": True},
        "before": before, "after": after, "changed_fields": masks[action],
        "completion_date_policy": {"create": "clear", "modify": "preserve", "complete": "set_on_commit", "reopen": "clear", "delete": "none"}[action],
        "recovery": {"mode": {"create": "delete_created", "delete": "limited_copy"}.get(action, "inverse_fields"), "limitations": list(REMINDER_LIMITATIONS)},
        "rollback": None}
    if source_action is not None:
        envelope["recovery"]["mode"] = "none"
        envelope["rollback"] = {"source_change_id": "source", "source_digest": "b" * 64,
            "completion_date": None, "alarm_restoration": None, "restoration_details": None}
        if source_action == "create":
            envelope.update(action="delete", before=reminder_snapshot(), after=None, changed_fields=[], completion_date_policy="none")
        elif source_action == "delete":
            envelope.update(action="create", before=None, after={"fields": reminder_snapshot()["fields"], "completed": False},
                            changed_fields=list(REMINDER_MASK_NAMES), completion_date_policy="restore")
            envelope["rollback"].update(alarm_restoration=[], restoration_details=reminder_snapshot()["details"])
        else:
            envelope["action"] = "modify"
            envelope["completion_date_policy"] = "restore"
            envelope["rollback"]["restoration_details"] = reminder_snapshot()["details"]
    return {"envelope": envelope, "authentication_tag": "synthetic-native-tag"}


def reminder_assessment_preview():
    payload = reminder_preview()["envelope"]
    return {"envelope": {**{key: payload[key] for key in ("version", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id")},
        "domain": "reminders_reconciliation", "source": {"change_id": "reminder-nonce", "payload_digest": "a" * 64,
            "result_digest": "b" * 64, "payload": payload, "result": {"state": "unknown", "nonce": "reminder-nonce"}},
        "assessment": {"outcome": "not_applied", "evidence": "The user inspected the exact synthetic fixture."},
        "limitations": list(REMINDER_RECONCILIATION_LIMITATIONS)}, "authentication_tag": "synthetic-native-tag"}


class ReminderBroker(AssessmentBroker):
    reminders_enabled = True

    def reminders_capabilities(self):
        return deepcopy(REMINDERS_CAPABILITIES)

    def reminders_authorization_status(self):
        return {"backend_mode": "eventkit", "authorization_status": "denied", "authorization_status_raw": 2, "pid": 42}

    def authorization_status(self):
        return {"backend_mode": "eventkit", "authorization_status": "full_access", "authorization_status_raw": 3, "pid": 42}

    def call(self, name, arguments):
        self.received = name, arguments
        if name in ("query_reminders", "get_reminder", "list_reminder_lists", "preflight_reminder_change"):
            raise NativeError("reminders_access_required", "Reminders access is required")
        return {"fixture": True}


class ReminderActivationTests(unittest.TestCase):
    def test_capability_is_exact_cached_and_disabled_probe_is_absent(self):
        self.assertTrue(valid_reminders_capabilities(REMINDERS_CAPABILITIES))
        invalid = [None, {}, {**REMINDERS_CAPABILITIES, "extra": True}]
        for key, value in REMINDERS_CAPABILITIES.items():
            invalid.append({**REMINDERS_CAPABILITIES, key: int(value) if type(value) is bool else True})
            invalid.append({item: expected for item, expected in REMINDERS_CAPABILITIES.items() if item != key})
        for value in invalid:
            self.assertFalse(valid_reminders_capabilities(value))
        for enabled, value in ((False, REMINDERS_CAPABILITIES), (True, REMINDERS_CAPABILITIES),
                               (True, {**REMINDERS_CAPABILITIES, "version": True}),
                               (True, NativeError("unknown_operation", "Old helper"))):
            broker = object.__new__(NativeBroker)
            broker.reminders_enabled = enabled
            calls = []

            def call(name, arguments):
                calls.append((name, arguments))
                if isinstance(value, Exception):
                    raise value
                return value

            broker.call = call
            expected = value if enabled and value is REMINDERS_CAPABILITIES else None
            self.assertEqual(broker.reminders_capabilities(), expected)
            self.assertEqual(broker.reminders_capabilities(), expected)
            self.assertEqual(calls, [("reminders_capabilities", {})] if enabled else [])

    def test_native_opt_in_flag_is_absent_by_default_and_never_authorizes(self):
        with tempfile.TemporaryDirectory(prefix="reminders synthetic activation ") as directory:
            helper = Path(directory) / "fixture-helper"
            helper.write_text("#!" + sys.executable + "\nimport json,sys\nfor line in sys.stdin:\n r=json.loads(line); print(json.dumps({'result':{'argv':sys.argv[1:],'op':r['op']}}),flush=True)\n")
            helper.chmod(0o700)
            for enabled in (False, True):
                broker = NativeBroker(helper, directory, "synthetic", enable_reminders=enabled, reminders_credential_binding="b" * 64 if enabled else None)
                try:
                    reply = broker.call("list_calendars", {})
                    self.assertIs(broker.reminders_enabled, enabled)
                    self.assertEqual(reply["argv"].count("--enable-reminders"), int(enabled))
                    self.assertNotIn("--authorize-reminders", reply["argv"])
                    self.assertEqual(reply["argv"].count("--reminders-credential-binding"), int(enabled))
                    if enabled:
                        self.assertEqual(reply["argv"][reply["argv"].index("--reminders-credential-binding") + 1], "b" * 64)
                    self.assertEqual(reply["op"], "list_calendars")
                finally:
                    broker.close()
            for invalid in (None, 0, 1, "true"):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    NativeBroker(helper, directory, "synthetic", enable_reminders=invalid)

    def test_default_protocol_preserves_calendar_tools_and_never_probes_reminders(self):
        class Broker(AssessmentBroker):
            def reminders_capabilities(self):
                raise AssertionError("Disabled Reminders must not be probed")

            def reminders_authorization_status(self):
                raise AssertionError("Disabled Reminders must not check authorization")

        current = Protocol(Broker())
        self.assertEqual(len(current.tools), 22)
        self.assertEqual(current.tools, Protocol(AssessmentBroker()).tools)


class ReminderDateTests(unittest.TestCase):
    def test_exact_gregorian_civil_components_and_floating_semantics(self):
        for value in (None, {"date": "2024-02-29", "time": None, "time_zone": None},
                      {"date": "1582-10-05", "time": "12:34:56", "time_zone": None},
                      {"date": "0001-01-01", "time": None, "time_zone": "UTC"},
                      {"date": "9999-12-31", "time": "23:59:59", "time_zone": None}):
            validate_reminder_date(value)
        for value in ("2023-02-29", "1900-02-29", "0000-01-01", "2024-2-01", "2024-02-30", "٢٠٢٤-01-01"):
            with self.subTest(value=value), self.assertRaises(ValidationError):
                validate_civil_date(value)
        base = {"date": "2024-02-29", "time": None, "time_zone": None}
        for value in ({"date": "2024-02-29"}, {**base, "extra": True},
                      {**base, "time": "24:00:00"}, {**base, "time": "12:30"},
                      {**base, "time": "12:30:00Z"}, {**base, "time_zone": "Not/A_Timezone"}):
            with self.subTest(value=value), self.assertRaises(ValidationError):
                validate_reminder_date(value)

    def test_named_timed_gaps_and_folds_are_rejected_without_normalizing(self):
        for day, clock in (("2024-03-31", "01:30:00"), ("2024-10-27", "01:30:00")):
            with self.subTest(day=day), self.assertRaises(ValidationError):
                validate_reminder_date({"date": day, "time": clock, "time_zone": "Europe/London"})
            validate_reminder_date({"date": day, "time": clock, "time_zone": None})
            validate_reminder_date({"date": day, "time": None, "time_zone": "Europe/London"})
        validate_reminder_date({"date": "2024-03-31", "time": "02:30:00", "time_zone": "Europe/London"})

    def test_priority_is_integer_and_snapshot_limits_measure_utf8_bytes(self):
        for priority in (0, 9):
            validate({"priority": priority}, REMINDER_FIELDS)
        for priority in (True, 1.0, -1, 10):
            with self.subTest(priority=priority), self.assertRaises(ValidationError):
                validate({"priority": priority}, REMINDER_FIELDS)
        with self.assertRaises(ValidationError):
            validate({"completed": True}, REMINDER_FIELDS)
        bound_reminder_json({"fixture": "short"}, MAX_REMINDER_SNAPSHOT, "Reminder snapshot")
        with self.assertRaises(ValidationError):
            bound_reminder_json({"fixture": "🗓" * (MAX_REMINDER_SNAPSHOT // 4)}, MAX_REMINDER_SNAPSHOT, "Reminder snapshot")


class ReminderContractTests(unittest.TestCase):
    def test_enabled_catalog_is_independent_and_missing_grant_keeps_history(self):
        broker = ReminderBroker()
        protocol = Protocol(broker, resource="reminders")
        calendar = Protocol(AssessmentBroker()).tools
        self.assertEqual(len(protocol.tools), 17)
        self.assertEqual(protocol.tools, REMINDER_TOOLS)
        self.assertEqual(Protocol(broker).tools, calendar)
        for item in REMINDER_TOOLS:
            hints = item["annotations"]
            self.assertFalse(hints["openWorldHint"])
            self.assertEqual(hints["readOnlyHint"], not item["name"].startswith("commit_"))
            if item["name"].startswith("commit_"):
                self.assertEqual(set(item["inputSchema"]["properties"]), {"preview"})
        reply = protocol.handle(request("query_reminders", {"list_id": "list-fixture"}))["result"]
        self.assertTrue(reply["isError"])
        self.assertEqual(json.loads(reply["content"][0]["text"])["code"], "reminders_access_required")
        self.assertFalse(protocol.handle(request("list_reminder_changes", {}))["result"]["isError"])
        self.assertFalse(protocol.handle(request("list_unresolved_reminder_changes", {}))["result"]["isError"])
        for invalid in (None, {**REMINDERS_CAPABILITIES, "version": True}, {**REMINDERS_CAPABILITIES, "extra": True}):
            broker = ReminderBroker(); broker.reminders_capabilities = lambda: invalid
            broker.call = lambda *_: self.fail("Unavailable Reminders must not dispatch")
            with self.assertRaises(NativeError):
                Protocol(broker, resource="reminders")
            fallback = Protocol(broker)
            self.assertEqual(fallback.tools, calendar)
            self.assertIn("error", fallback.handle(request("list_reminder_changes", {})))

    def test_strict_preflight_query_fields_and_absolute_alerts(self):
        valid = [("preflight_reminder_change", {"action": "create", "scope": "this", "list_id": "list", "fields": {"title": "Fixture"}}),
                 ("preflight_reminder_change", {"action": "modify", "scope": "this", "reminder_id": "reminder", "fields": {
                     "due": {"date": "2028-01-01", "time": None, "time_zone": None},
                     "alerts": [{"at": "2028-01-01T10:00:00Z"}]}}),
                 ("query_reminders", {"list_id": "list", "due_from": "2028-01-01", "due_to": "2028-02-01", "include_undated": True, "limit": 100})]
        for name, arguments in valid:
            validate_reminder_arguments(name, arguments)
        invalid = [("preflight_reminder_change", {"action": "create", "scope": "this", "list_id": "l", "reminder_id": "r", "fields": {"title": "Fixture"}}),
                   ("preflight_reminder_change", {"action": "modify", "scope": "this", "reminder_id": "r", "fields": {}}),
                   ("preflight_reminder_change", {"action": "complete", "scope": "this", "reminder_id": "r", "fields": {"title": "Unexpected"}}),
                   ("preflight_reminder_change", {"action": "delete", "scope": "series", "reminder_id": "r"}),
                   ("preflight_reminder_change", {"action": "modify", "scope": "this", "reminder_id": "r", "fields": {"completion_date": None}}),
                   ("preflight_reminder_change", {"action": "modify", "scope": "this", "reminder_id": "r", "fields": {"alerts": [{"relative_minutes": -15}]}}),
                   ("preflight_reminder_change", {"action": "modify", "scope": "this", "reminder_id": "r", "fields": {"alerts": [{"at": "2028-01-01T10:00:00Z"}, {"at": "2028-01-01T11:00:00+01:00"}]}}),
                   ("query_reminders", {"list_id": "l", "limit": True}),
                   ("query_reminders", {"list_id": "l", "due_from": "2028-02-01", "due_to": "2028-01-01"}),
                   ("preflight_reminder_rollback", {"change_ids": ["a", "b"]})]
        for name, arguments in invalid:
            with self.subTest(name=name, arguments=arguments), self.assertRaises(ValidationError):
                validate_reminder_arguments(name, arguments)

    def test_full_signed_actions_inverse_and_cross_domain_routes(self):
        broker = ReminderBroker(); protocol = Protocol(broker, resource="reminders")
        for action in ("create", "modify", "complete", "reopen", "delete"):
            preview = reminder_preview(action)
            name = "commit_reminder_" + action
            validate_reminder_arguments(name, {"preview": preview})
            result = protocol.handle(request(name, {"preview": preview}))["result"]
            self.assertFalse(result["isError"])
            self.assertIs(broker.received[1]["preview"], preview)
            self.assertEqual(protocol.handle(request("commit_modify", {"preview": preview}))["error"]["code"], -32602)
        for source_action in ("create", "modify", "delete"):
            validate_reminder_arguments("commit_reminder_rollback", {"preview": reminder_preview(source_action=source_action)})
        foreign = ordinary_preview("modify")
        self.assertEqual(protocol.handle(request("commit_reminder_modify", {"preview": foreign}))["error"]["code"], -32602)
        assessment = reminder_assessment_preview()
        validate_reminder_arguments("commit_reminder_reconciliation", {"preview": assessment})
        self.assertFalse(protocol.handle(request("commit_reminder_reconciliation", {"preview": assessment}))["result"]["isError"])
        self.assertEqual(protocol.handle(request("commit_reconciliation", {"preview": assessment}))["error"]["code"], -32602)

    def test_preview_semantics_full_bounds_and_no_hidden_restoration(self):
        mutations = [lambda e: e.update(domain="calendar"), lambda e: e.update(scope="future"),
                     lambda e: e.update(rollback={}), lambda e: e.update(changed_fields=[]),
                     lambda e: e.update(completion_date_policy="restore"),
                     lambda e: e["recovery"]["limitations"].reverse(),
                     lambda e: e["after"]["fields"].update(priority=1),
                     lambda e: e["before"].update(unsupported_reasons=["recurring"]),
                     lambda e: e["before"].update(list_id="other"),
                     lambda e: e.update(expires_at="2028-01-01T10:11:00Z")]
        for mutation in mutations:
            preview = reminder_preview(); mutation(preview["envelope"])
            with self.assertRaises(ValidationError):
                validate_reminder_arguments("commit_reminder_modify", {"preview": preview})
        inverse = reminder_preview(source_action="modify")
        del inverse["envelope"]["rollback"]["restoration_details"]
        with self.assertRaises(ValidationError):
            validate_reminder_arguments("commit_reminder_rollback", {"preview": inverse})
        preview = reminder_preview(); preview["envelope"]["before"]["details"]["oversize"] = "x" * MAX_REMINDER_SNAPSHOT
        with self.assertRaises(ValidationError):
            validate_reminder_arguments("commit_reminder_modify", {"preview": preview})
        escaped = reminder_preview()
        escaped["envelope"]["before"]["fields"]["notes"] = "\x7f" * 40000
        escaped["envelope"]["after"]["fields"]["notes"] = "\x7f" * 40000
        with self.assertRaises(ValidationError):
            validate_reminder_arguments("commit_reminder_modify", {"preview": escaped})
        assessment = reminder_assessment_preview()
        assessment["envelope"]["source"]["result"]["synthetic_padding"] = "\x7f" * 5500
        with self.assertRaises(ValidationError):
            validate_reminder_arguments("commit_reminder_reconciliation", {"preview": assessment})


class ReminderTransportTests(unittest.TestCase):
    def test_scoped_17_tool_unix_http_stdio_and_separate_status(self):
        with tempfile.TemporaryDirectory(prefix="reminders synthetic transport ") as directory:
            state = initialize(Path(directory) / "state"); initialize(state, "reminders")
            broker = ReminderBroker()
            server = GatewayServer(0, read_token(state), Protocol(broker), state_directory=state,
                                   reminders_token=read_token(state, "reminders"), reminders_protocol=Protocol(broker, resource="reminders"))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port, resource="reminders")
                status = client.status()
                self.assertNotIn("native", status)
                self.assertEqual(GatewayClient(state, server.server_port).status()["native"]["authorization_status"], "full_access")
                self.assertEqual(status["reminders"]["authorization_status"], "denied")
                discovery = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
                result = client.send(json.dumps(discovery).encode())
                self.assertEqual(len(result["result"]["tools"]), 17)
                self.assertLess(len(json.dumps(result).encode()), MAX_RESPONSE)
                self.assertEqual(loads(json.dumps(result), max_depth=32), result)
                for call in (discovery, request("commit_reminder_modify", {"preview": reminder_preview()}),
                             request("commit_reminder_rollback", {"preview": reminder_preview(source_action="delete")}),
                             request("commit_reminder_reconciliation", {"preview": reminder_assessment_preview()})):
                    wire = json.dumps(call).encode()
                    self.assertEqual(loads(wire), call)
                    sink = io.BytesIO()
                    self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                    self.assertNotIn("error", loads(sink.getvalue(), max_depth=32))
                class EchoBroker(ReminderBroker):
                    def call(self, name, arguments):
                        return {"preview": arguments["preview"]}
                echo = EchoBroker()
                server.protocol = Protocol(echo)
                server.reminders_protocol = Protocol(echo, resource="reminders")
                for text in ("中" * 30000, "🗓" * 16000):
                    ordinary = reminder_preview()
                    ordinary["envelope"]["before"]["fields"]["notes"] = text
                    ordinary["envelope"]["after"]["fields"]["notes"] = text
                    assessment = reminder_assessment_preview()
                    assessment["envelope"]["source"]["payload"] = ordinary["envelope"]
                    for name, preview in (("commit_reminder_modify", ordinary), ("commit_reminder_reconciliation", assessment)):
                        validate_reminder_arguments(name, {"preview": preview})
                        wire = json.dumps(request(name, {"preview": preview}), ensure_ascii=True).encode()
                        self.assertLess(len(wire), 1024 * 1024)
                        sink = io.BytesIO(); self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                        reply = loads(sink.getvalue(), max_depth=32)
                        self.assertFalse(reply["result"]["isError"])
                        self.assertEqual(reply["result"]["structuredContent"]["preview"], preview)
                        self.assertEqual(json.loads(reply["result"]["content"][0]["text"])["preview"], preview)
            finally:
                server.shutdown(); server.server_close(); thread.join()

    def test_cli_uses_protected_mcp_history_and_has_no_commit_route(self):
        calls = []

        class Client:
            def __init__(self, state, port, *, resource="calendar"):
                if resource != "reminders":
                    raise AssertionError("Reminder CLI must use its own resource credential")

            def send(self, wire):
                calls.append(loads(wire))
                return {"jsonrpc": "2.0", "id": 1, "result": {"isError": False, "structuredContent": {"fixture": True}}}

            def status(self):
                return {"gateway": "reachable", "native": {}, "reminders": {"authorization_status": "denied"}}

        with patch("calendar_mcp.reminders.GatewayClient", Client), redirect_stdout(io.StringIO()):
            self.assertEqual(main(["reminders", "status", "--state-dir", "/tmp/unused"]), 0)
            for args in (("list", "--action", "complete"), ("show", "source"), ("status", "nonce"), ("unresolved",), ("prepare", "source")):
                self.assertEqual(main(["reminders", "changes", *args, "--state-dir", "/tmp/unused"]), 0)
        self.assertEqual([call["params"]["name"] for call in calls], ["list_reminder_changes", "get_stored_reminder_change",
            "get_reminder_change_status", "list_unresolved_reminder_changes", "preflight_reminder_rollback"])
        with self.assertRaises(ValueError):
            reminders.read_tool(Client(None, None, resource="reminders"), "commit_reminder_delete", {"preview": reminder_preview("delete")})


REMINDERS_HELPER = Path(os.environ.get("CALENDAR_MCP_TEST_HELPER", "/nonexistent-reminders-test-helper"))


@unittest.skipUnless(REMINDERS_HELPER.is_file(), "Set CALENDAR_MCP_TEST_HELPER to the new synthetic Reminders helper")
class NativeReminderIntegrationTests(unittest.TestCase):
    def test_native_large_unknown_assessment_and_receipt_replay_without_provider(self):
        products = REMINDERS_HELPER.resolve().parent
        bundles = list(products.glob("*.xctest"))
        self.assertEqual(len(bundles), 1, "The raw-helper integration requires its matching built XCTest fixture bundle")
        for kind, expected in (("del", "\x7f" * 30000), ("bmp", "中" * 30000), ("nonbmp", "🗓" * 14000)):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="reminders-synthetic-export-") as directory:
                state = initialize(Path(directory) / "gateway"); initialize(state, "reminders")
                token = read_token(state)
                reminder_token = read_token(state, "reminders")
                native = state / "native-synthetic"
                env = os.environ.copy()
                env.update(CALENDAR_MCP_REMINDER_EXPORT_ROOT=str(native),
                           CALENDAR_MCP_REMINDER_EXPORT_BINDING=hashlib.sha256(reminder_token.encode()).hexdigest(),
                           CALENDAR_MCP_REMINDER_EXPORT_TEXT=kind)
                log = Path(directory) / "fixture-export.log"
                descriptor = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as output:
                    seeded = subprocess.run(["/usr/bin/xcrun", "xctest", "-XCTest",
                        "CalendarHelperTests.ReminderExportFixtureTests/testSyntheticUnknownFixtureCanBeExportedClosed", str(bundles[0])],
                        env=env, stdout=output, stderr=subprocess.STDOUT, timeout=30)
                self.assertEqual(seeded.returncode, 0, "Synthetic XCTest export failed; inspect its private fixture log")
                manifest = native / "synthetic-fixture.json"
                self.assertTrue(manifest.is_file(), "The selected XCTest must actually execute the closed synthetic fixture export")
                nonce = loads(manifest.read_bytes())["nonce"]
                database = native / "reminders" / "reminders.sqlite3"
                with closing(sqlite3.connect(database)) as connection:
                    original_cipher = connection.execute("SELECT payload_cipher FROM details WHERE nonce=?", (nonce,)).fetchone()[0]
                    self.assertEqual(connection.execute("SELECT COUNT(*) FROM executions").fetchone()[0], 1)
                    self.assertEqual(connection.execute("SELECT COUNT(*) FROM quota").fetchone()[0], 1)
                broker = NativeBroker(REMINDERS_HELPER, native, "synthetic", enable_reminders=True,
                    credential_binding=hashlib.sha256(token.encode()).hexdigest(),
                    reminders_credential_binding=hashlib.sha256(reminder_token.encode()).hexdigest())
                server = GatewayServer(0, token, Protocol(broker), state_directory=state,
                    reminders_token=reminder_token, reminders_protocol=Protocol(broker, resource="reminders"))
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True); thread.start()
                try:
                    client = GatewayClient(state, server.server_port, resource="reminders")

                    def call(name, arguments):
                        wire = json.dumps(request(name, arguments), ensure_ascii=True).encode()
                        self.assertLess(len(wire), 1024 * 1024)
                        sink = io.BytesIO(); self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                        reply = loads(sink.getvalue(), max_depth=32)
                        self.assertNotIn("error", reply)
                        self.assertFalse(reply["result"]["isError"], reply)
                        content = reply["result"]["structuredContent"]
                        self.assertEqual(json.loads(reply["result"]["content"][0]["text"]), content)
                        return content

                    rows = call("list_unresolved_reminder_changes", {})["changes"]
                    self.assertEqual([row["change_id"] for row in rows], [nonce])
                    stored = call("get_stored_reminder_change", {"change_id": nonce})
                    self.assertEqual(stored["state"], "unknown")
                    self.assertEqual(stored["payload"]["before"]["fields"]["notes"], expected)
                    preview = call("preflight_reminder_reconciliation", {"change_id": nonce, "outcome": "not_applied",
                        "evidence": "Explicit synthetic user assessment; no provider verification."})["preview"]
                    self.assertEqual(preview["envelope"]["source"]["payload"], stored["payload"])
                    self.assertEqual(preview["envelope"]["source"]["result"], stored["result"])
                    receipt = call("commit_reminder_reconciliation", {"preview": preview})
                    self.assertEqual(receipt["verification"], "not_performed")
                    self.assertEqual(call("commit_reminder_reconciliation", {"preview": preview}), receipt)
                    status = call("get_reminder_change_status", {"nonce": nonce})
                    self.assertEqual(status["state"], "reconciled")
                    self.assertEqual(status["previous_result"], stored["result"])
                    self.assertEqual(call("list_unresolved_reminder_changes", {})["changes"], [])
                finally:
                    server.shutdown(); server.server_close(); thread.join(); broker.close()
                with closing(sqlite3.connect(database)) as connection:
                    self.assertEqual(connection.execute("SELECT payload_cipher FROM details WHERE nonce=?", (nonce,)).fetchone()[0], original_cipher)
                    self.assertEqual(connection.execute("SELECT COUNT(*) FROM executions").fetchone()[0], 1)
                    self.assertEqual(connection.execute("SELECT COUNT(*) FROM quota").fetchone()[0], 1)
                    self.assertEqual(connection.execute("SELECT COUNT(*) FROM assessments").fetchone()[0], 1)

    def test_native_all_actions_history_inverse_copy_and_full_transport(self):
        with tempfile.TemporaryDirectory(prefix="reminders synthetic native ") as directory:
            state = initialize(Path(directory) / "gateway"); initialize(state, "reminders")
            token = read_token(state)
            reminder_token = read_token(state, "reminders")
            native = state / "native-synthetic"; native.mkdir(mode=0o700)
            broker = NativeBroker(REMINDERS_HELPER, native, "synthetic", enable_reminders=True,
                                  credential_binding=hashlib.sha256(token.encode()).hexdigest(),
                    reminders_credential_binding=hashlib.sha256(reminder_token.encode()).hexdigest())
            self.addCleanup(broker.close)
            self.assertIsNotNone(broker.reminders_capabilities(), "The configured final helper must implement Reminders")
            server = GatewayServer(0, token, Protocol(broker), state_directory=state,
                    reminders_token=reminder_token, reminders_protocol=Protocol(broker, resource="reminders"))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True); thread.start()
            try:
                client = GatewayClient(state, server.server_port, resource="reminders")
                self.assertEqual(client.status()["reminders"]["authorization_status"], "not_applicable")
                listed = client.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode())
                self.assertEqual(len(listed["result"]["tools"]), 17)
                discovery = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
                sink = io.BytesIO(); self.assertEqual(run_stdio(client, io.BytesIO(discovery + b"\n"), sink), 0)
                self.assertEqual(len(loads(sink.getvalue(), max_depth=32)["result"]["tools"]), 17)

                def call(name, arguments=None):
                    wire = json.dumps(request(name, arguments or {})).encode()
                    sink = io.BytesIO()
                    self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                    reply = loads(sink.getvalue())
                    self.assertNotIn("error", reply, reply)
                    self.assertFalse(reply["result"]["isError"], reply)
                    return reply["result"]["structuredContent"]

                list_id = call("list_reminder_lists")["lists"][0]["id"]
                draft = call("preflight_reminder_change", {"action": "create", "scope": "this", "list_id": list_id,
                    "fields": {"title": "Synthetic reminder fixture", "notes": "Original note", "priority": 2,
                               "due": {"date": "2030-06-03", "time": None, "time_zone": None},
                               "alerts": [{"at": "2030-06-03T09:00:00Z"}]}})["preview"]
                validate_reminder_arguments("commit_reminder_create", {"preview": draft})
                created = call("commit_reminder_create", {"preview": draft})
                self.assertEqual(created["state"], "applied")
                self.assertEqual(call("commit_reminder_create", {"preview": draft}), created)
                reminder_id = created["reminder"]["id"]
                queried = call("query_reminders", {"list_id": list_id, "status": "all"})
                self.assertFalse(queried["truncated"])
                self.assertIn(reminder_id, [item["id"] for item in queried["reminders"]])
                call("get_reminder", {"reminder_id": reminder_id})
                results = []
                for action, fields in (("modify", {"title": "Changed synthetic fixture", "due": {
                        "date": "2030-06-04", "time": "10:00:00", "time_zone": "Europe/London"},
                        "alerts": [{"at": "2030-06-03T09:00:00Z"}]}),
                                       ("complete", None), ("reopen", None)):
                    args = {"action": action, "scope": "this", "reminder_id": reminder_id}
                    if fields is not None: args["fields"] = fields
                    preview = call("preflight_reminder_change", args)["preview"]
                    if action == "modify":
                        self.assertNotIn("alerts", preview["envelope"]["changed_fields"])
                        self.assertNotIn("alerts", preview["envelope"]["after"]["fields"])
                    result = call("commit_reminder_" + action, {"preview": preview})
                    self.assertEqual(result["state"], "applied")
                    self.assertEqual(call("get_reminder_change_status", {"nonce": result["nonce"]}), result)
                    results.append(result)
                plan = call("preflight_reminder_rollback", {"change_id": results[-1]["nonce"]})
                self.assertEqual(len(plan["steps"]), 1)
                self.assertEqual(plan["steps"][0]["commit_tool"], "commit_reminder_rollback")
                restored = call("commit_reminder_rollback", {"preview": plan["steps"][0]["preview"]})
                self.assertTrue(restored["reminder"]["completed"])
                preview = call("preflight_reminder_change", {"action": "delete", "scope": "this", "reminder_id": reminder_id})["preview"]
                deleted = call("commit_reminder_delete", {"preview": preview})
                plan = call("preflight_reminder_rollback", {"change_id": deleted["nonce"]})
                copy = call("commit_reminder_rollback", {"preview": plan["steps"][0]["preview"]})
                self.assertEqual(copy["state"], "applied")
                self.assertNotEqual(copy["reminder"]["id"], reminder_id)
                self.assertTrue(call("list_reminder_changes", {"include_expired": True})["changes"])
                call("get_stored_reminder_change", {"change_id": deleted["nonce"]})
                self.assertEqual(call("list_unresolved_reminder_changes", {})["changes"], [])
                utc = call("preflight_reminder_change", {"action": "create", "scope": "this", "list_id": list_id,
                    "fields": {"title": "Synthetic UTC fixture", "due": {"date": "2030-06-03", "time": "10:00:00", "time_zone": "UTC"}}})["preview"]
                self.assertEqual(utc["envelope"]["after"]["fields"]["due"]["time_zone"], "GMT")
                utc_result = call("commit_reminder_create", {"preview": utc})
                self.assertEqual(utc_result["reminder"]["fields"]["due"], utc["envelope"]["after"]["fields"]["due"])
                with self.assertRaises(NativeError):
                    broker.call("preflight_reminder_change", {"action": "create", "scope": "this", "list_id": list_id,
                        "fields": {"title": "Synthetic invalid timezone", "due": {"date": "2030-06-03", "time": "10:00:00", "time_zone": "GMT+0100"}}})
                self.assertTrue((native / "reminders" / "reminders.sqlite3").is_file())
            finally:
                server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    unittest.main()
