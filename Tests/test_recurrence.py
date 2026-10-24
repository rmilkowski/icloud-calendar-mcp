"""Recurring contracts and native lifecycles use synthetic state exclusively."""

from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import (ALERTS_CAPABILITIES, RECOVERY_CAPABILITIES,
                                 RECURRENCE_CAPABILITIES, NativeBroker, NativeError)
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.schema import (COPY_RECOVERY_LIMITATION, OCCURRENCE_RECOVERY_LIMITATION,
                                 RECURRING_DELETE_LIMITATION, RECURRENCE_TOOLS,
                                 TOOLS, LEGACY_TOOLS, ValidationError, validate_arguments)
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from Tests.test_alerts import request
from Tests.test_changes import recovery_preview
from Tests.test_native_integration import HELPER


def ordinary_preview(action="create", *, recurring=True):
    preview = recovery_preview(action)
    envelope = preview["envelope"]
    del envelope["rollback"]
    envelope["version"] = 3
    if action == "create":
        envelope["after"] = {**envelope["after"], "alerts": []}
        envelope["scope"] = "series" if recurring else "this"
        if recurring:
            envelope["after"]["recurrence"] = {"frequency": "weekly", "interval": 1,
                                                   "end": {"count": 10}, "days_of_week": [2, 4]}
        envelope["recovery"] = {"mode": "not_applicable", "limitations": []}
    else:
        envelope["before"]["recurring"] = recurring
        envelope["before"]["occurrence"] = "2026-10-23T09:00:00Z" if recurring else None
        envelope["recovery"] = {"mode": "occurrence_fields", "limitations": [OCCURRENCE_RECOVERY_LIMITATION] if recurring else []}
        if action == "delete":
            envelope["after"] = None
            envelope["recovery"] = {"mode": "standalone_copy", "limitations": [COPY_RECOVERY_LIMITATION, *([RECURRING_DELETE_LIMITATION] if recurring else [])]}
    return preview


class RecurrenceBroker:
    def recovery_capabilities(self):
        return dict(RECOVERY_CAPABILITIES)

    def alerts_capabilities(self):
        return dict(ALERTS_CAPABILITIES)

    def recurrence_capabilities(self):
        return dict(RECURRENCE_CAPABILITIES)

    def call(self, name, arguments):
        self.received = name, arguments
        return {"state": "applied"}


class RecurrenceSchemaTests(unittest.TestCase):
    def test_creation_bounds_and_scope_rules(self):
        base = {"action": "create", "scope": "series", "calendar_id": "fixture",
                "fields": {"title": "Fixture", "start": "2026-11-02T10:00:00Z", "end": "2026-11-02T11:00:00Z"}}
        for rule in ({"frequency": "daily"}, {"frequency": "weekly", "interval": 999, "end": None, "days_of_week": [1, 7]},
                     {"frequency": "monthly", "end": {"count": 1000}},
                     {"frequency": "yearly", "end": {"until": "2027-11-02T10:00:00+00:00"}}):
            validate_arguments("preflight_change", {**base, "fields": {**base["fields"], "recurrence": rule}}, recurrence=True)
        invalid_rules = [None, {}, {"frequency": "hourly"}, {"frequency": "daily", "interval": True},
                         {"frequency": "daily", "interval": 0}, {"frequency": "daily", "interval": 1000},
                         {"frequency": "weekly", "days_of_week": []}, {"frequency": "weekly", "days_of_week": [2, 2]},
                         {"frequency": "weekly", "days_of_week": [0]}, {"frequency": "weekly", "days_of_week": [True]},
                         {"frequency": "daily", "days_of_week": [2]}, {"frequency": "daily", "end": {}},
                         {"frequency": "daily", "end": {"count": 0}}, {"frequency": "daily", "end": {"count": 1001}},
                         {"frequency": "daily", "end": {"count": 3, "until": "2027-11-02T10:00:00Z"}},
                         {"frequency": "daily", "end": {"until": "2027-11-02T10:00:00"}},
                         {"frequency": "daily", "by_month": [2]}]
        for rule in invalid_rules:
            with self.subTest(rule=rule), self.assertRaises(ValidationError):
                validate_arguments("preflight_change", {**base, "fields": {**base["fields"], "recurrence": rule}}, recurrence=True)
        invalid = [base, {**base, "scope": "future"},
                   {**base, "scope": "this", "fields": {**base["fields"], "recurrence": {"frequency": "daily"}}},
                   {"action": "modify", "scope": "this", "event_id": "fixture", "fields": {"recurrence": {"frequency": "daily"}}},
                   {"action": "modify", "scope": "series", "event_id": "fixture", "fields": {"title": "Fixture"}},
                   {"action": "delete", "scope": "series", "event_id": "fixture"}]
        for arguments in invalid:
            with self.subTest(arguments=arguments), self.assertRaises(ValidationError):
                validate_arguments("preflight_change", arguments, recurrence=True)

    def test_complete_signed_v3_disclosures_and_legacy_recovery_shapes(self):
        for recurring in (False, True):
            for action in ("create", "modify", "delete"):
                preview = ordinary_preview(action, recurring=recurring)
                validate_arguments("commit_" + action, {"preview": preview}, recurrence=True)
                for key in ("recovery",):
                    malformed = deepcopy(preview)
                    del malformed["envelope"][key]
                    with self.assertRaises(ValidationError):
                        validate_arguments("commit_" + action, {"preview": malformed}, recurrence=True)
                malformed = deepcopy(preview)
                malformed["envelope"]["recovery"]["mode"] = "not_applicable" if action != "create" else "standalone_copy"
                with self.assertRaises(ValidationError):
                    validate_arguments("commit_" + action, {"preview": malformed}, recurrence=True)
                with self.assertRaises(ValidationError):
                    validate_arguments("commit_" + action, {"preview": preview}, recurrence=False)
        deleted = ordinary_preview("delete")
        deleted["envelope"]["recovery"]["limitations"].pop()
        with self.assertRaises(ValidationError):
            validate_arguments("commit_delete", {"preview": deleted}, recurrence=True)
        create = ordinary_preview()
        del create["envelope"]["after"]["recurrence"]["interval"]
        with self.assertRaises(ValidationError):
            validate_arguments("commit_create", {"preview": create}, recurrence=True)
        old = recovery_preview()
        validate_arguments("commit_rollback", {"preview": old}, recurrence=True)
        old["envelope"]["version"] = 2
        old["envelope"]["rollback"]["alarm_restoration"] = []
        validate_arguments("commit_rollback", {"preview": old}, recurrence=True)
        old["envelope"]["version"] = 3
        with self.assertRaises(ValidationError):
            validate_arguments("commit_rollback", {"preview": old}, recurrence=True)

    def test_capability_fallback_is_exact_and_never_dispatches_recurrence(self):
        invalid = [None, {**RECURRENCE_CAPABILITIES, "version": True},
                   {**RECURRENCE_CAPABILITIES, "extra": True}, {**RECURRENCE_CAPABILITIES, "max_count": 999},
                   {**RECURRENCE_CAPABILITIES, "future_scope": 0}]
        for alerts in (False, True):
            for value in [*invalid, RECURRENCE_CAPABILITIES] if not alerts else invalid:
                class Broker(RecurrenceBroker):
                    def alerts_capabilities(self):
                        return dict(ALERTS_CAPABILITIES) if alerts else None

                    def recurrence_capabilities(self):
                        return value

                    def call(self, name, arguments):
                        raise AssertionError("Unsupported recurrence must never dispatch")
                protocol = Protocol(Broker())
                self.assertEqual(protocol.tools, TOOLS if alerts else LEGACY_TOOLS)
                for name, arguments in (("commit_create", {"preview": ordinary_preview()}),
                                        ("preflight_change", {"action": "create", "scope": "series", "fields": {}}),
                                        ("preflight_change", {"action": "modify", "scope": "this", "fields": {"recurrence": None}})):
                    reply = protocol.handle(request(name, arguments))["result"]
                    self.assertTrue(reply["isError"])
                    self.assertEqual(json.loads(reply["content"][0]["text"])["code"], "feature_unavailable")

    def test_probe_is_cached_independent_and_full_preview_is_forwarded_unchanged(self):
        for value in (RECURRENCE_CAPABILITIES, {**RECURRENCE_CAPABILITIES, "version": True},
                      NativeError("unknown_operation", "Old helper")):
            broker = object.__new__(NativeBroker)
            calls = []
            def call(name, arguments):
                calls.append((name, arguments))
                if isinstance(value, Exception):
                    raise value
                return value
            broker.call = call
            expected = RECURRENCE_CAPABILITIES if value is RECURRENCE_CAPABILITIES else None
            self.assertEqual(broker.recurrence_capabilities(), expected)
            self.assertEqual(broker.recurrence_capabilities(), expected)
            self.assertEqual(calls, [("recurrence_capabilities", {})])
        broker = RecurrenceBroker()
        protocol = Protocol(broker)
        self.assertEqual(protocol.tools, RECURRENCE_TOOLS)
        preview = ordinary_preview("delete")
        result = protocol.handle(request("commit_delete", {"preview": preview}))["result"]
        self.assertFalse(result["isError"])
        self.assertIs(broker.received[1]["preview"], preview)
        broker.recovery_capabilities = lambda: None
        self.assertEqual(len(Protocol(broker).tools), 9)
        reply = Protocol(broker).handle(request("preflight_rollback", {"all": True}))["result"]
        self.assertTrue(reply["isError"])


class RecurrenceHTTPTests(unittest.TestCase):
    def test_complete_v3_discovery_and_commit_round_trip_http_and_stdio(self):
        with tempfile.TemporaryDirectory(prefix="calendar recurring transport ") as directory:
            state = initialize(Path(directory) / "state")
            broker = RecurrenceBroker()
            server = GatewayServer(0, read_token(state), Protocol(broker))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                discovery = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
                wire = json.dumps(discovery).encode()
                result = client.send(wire)
                self.assertEqual(result["result"]["tools"], RECURRENCE_TOOLS)
                self.assertEqual(len(result["result"]["tools"]), 13)
                response = json.dumps(result).encode()
                self.assertLess(len(response), MAX_RESPONSE)
                self.assertEqual(loads(response, max_depth=32), result)
                sink = io.BytesIO()
                self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                self.assertEqual(json.loads(sink.getvalue()), result)
                preview = ordinary_preview("delete")
                call_wire = json.dumps(request("commit_delete", {"preview": preview})).encode()
                sink = io.BytesIO()
                self.assertEqual(run_stdio(client, io.BytesIO(call_wire + b"\n"), sink), 0)
                self.assertFalse(json.loads(sink.getvalue())["result"]["isError"])
                self.assertEqual(broker.received, ("commit_delete", {"preview": preview}))
                with self.assertRaises(ValueError):
                    loads("[" * 21 + "1" + "]" * 21)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


@unittest.skipUnless(HELPER.is_file(), "Build native helper before synthetic recurrence validation")
class NativeRecurrenceIntegrationTests(unittest.TestCase):
    def test_native_series_occurrence_edit_delete_copy_recovery_and_replay(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic recurrence ") as directory:
            state = initialize(Path(directory) / "native")
            broker = NativeBroker(HELPER, state, "synthetic", credential_binding=hashlib.sha256(b"synthetic-recurrence-fixture").hexdigest())
            self.addCleanup(broker.close)
            if broker.recurrence_capabilities() is None:
                self.skipTest("Selected helper does not support recurrence")
            protocol = Protocol(broker)
            def tool(name, arguments=None, *, error=False):
                reply = protocol.handle(request(name, arguments))
                self.assertNotIn("error", reply, reply)
                self.assertEqual(reply["result"]["isError"], error, reply)
                return reply["result"] if error else reply["result"]["structuredContent"]
            calendar = tool("list_calendars")["calendars"][0]["id"]
            preview = tool("preflight_change", {"action": "create", "scope": "series", "calendar_id": calendar,
                "fields": {"title": "Synthetic recurring fixture", "start": "2026-11-02T10:00:00Z", "end": "2026-11-02T11:00:00Z",
                           "time_zone": "Europe/London", "recurrence": {"frequency": "weekly", "days_of_week": [4, 2], "end": {"count": 4}},
                           "alerts": [{"relative_minutes": -15}]}})["preview"]
            self.assertEqual(preview["envelope"]["version"], 3)
            self.assertEqual(preview["envelope"]["after"]["recurrence"],
                             {"frequency": "weekly", "interval": 1, "end": {"count": 4}, "days_of_week": [2, 4]})
            tampered = deepcopy(preview)
            tampered["envelope"]["after"]["recurrence"]["interval"] = 2
            tool("commit_create", {"preview": tampered}, error=True)
            created = tool("commit_create", {"preview": preview})
            self.assertEqual(tool("commit_create", {"preview": preview}), created)
            events = tool("query_events", {"start": "2026-11-01T00:00:00Z", "end": "2026-11-20T00:00:00Z"})["events"]
            occurrences = [event for event in events if event["fields"]["title"] == "Synthetic recurring fixture"]
            # SyntheticBackend stores the anchor fixture and rule; it does not
            # simulate EventKit recurrence expansion or provider exclusions.
            self.assertEqual(len(occurrences), 1)
            self.assertTrue(occurrences[0]["recurring"])
            self.assertIsNotNone(occurrences[0]["occurrence"])
            event_id = occurrences[0]["id"]
            original = tool("get_event", {"event_id": event_id})["event"]
            draft = tool("preflight_change", {"action": "modify", "scope": "this", "event_id": event_id,
                         "fields": {"notes": "Only this occurrence"}})["preview"]
            self.assertEqual(draft["envelope"]["recovery"]["mode"], "occurrence_fields")
            changed = tool("commit_modify", {"preview": draft})
            plan = tool("preflight_rollback", {"change_ids": [changed["nonce"]]})
            rollback = plan["steps"][0]["preview"]
            self.assertEqual(rollback["envelope"]["version"], 2)
            restored = tool("commit_rollback", {"preview": rollback})["event"]
            self.assertEqual(restored["fields"], original["fields"])
            draft = tool("preflight_change", {"action": "delete", "scope": "this", "event_id": restored["id"]})["preview"]
            self.assertIn(RECURRING_DELETE_LIMITATION, draft["envelope"]["recovery"]["limitations"])
            deleted = tool("commit_delete", {"preview": draft})
            self.assertEqual(tool("commit_delete", {"preview": draft}), deleted)
            plan = tool("preflight_rollback", {"change_ids": [deleted["nonce"]]})
            rollback = plan["steps"][0]["preview"]
            self.assertEqual(rollback["envelope"]["version"], 2)
            self.assertIn(RECURRING_DELETE_LIMITATION, rollback["envelope"]["rollback"]["limitations"])
            recovered = tool("commit_rollback", {"preview": rollback})
            self.assertEqual(tool("commit_rollback", {"preview": rollback}), recovered)
            copy = recovered["event"]
            self.assertFalse(copy["recurring"])
            self.assertFalse(copy["detached"])
            # The registry may preserve the opaque integration reference while
            # rebinding it to the new provider event; provider IDs stay private.
            self.assertIsNone(copy["occurrence"])
            self.assertEqual(copy["fields"], original["fields"])
            self.assertEqual(copy["details"]["alarms"], original["details"]["alarms"])


if __name__ == "__main__":
    unittest.main()
