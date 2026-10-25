"""Current-pattern field contracts use synthetic views and isolated transports."""

from copy import deepcopy
import io
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import (NativeBroker, NativeError, RECOVERY_CAPABILITIES, SERIES_MODIFICATION_CAPABILITIES,
                                 valid_series_modification_capabilities)
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.schema import (RECURRENCE_TOOLS, SERIES_LIMITATIONS, SERIES_MODIFICATION_TOOLS,
                                 ValidationError, validate_arguments)
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from Tests.test_alerts import request
from Tests.test_changes import recovery_preview
from Tests.test_recurrence import RecurrenceBroker, ordinary_preview
from Tests.test_native_integration import HELPER


def series_preview(*, rollback=False, changed_fields=None):
    changed_fields = changed_fields or ["title"]
    preview = ordinary_preview("modify")
    envelope = preview["envelope"]
    envelope["version"], envelope["scope"] = 4, "series"
    envelope["after"] = {**envelope["before"]["fields"], "title": "Renamed pattern"}
    envelope["series"] = {"provider_scope": "current_pattern_from_first_occurrence",
                          "selected": deepcopy(envelope["before"]), "changed_fields": changed_fields}
    if not rollback:
        envelope["series"]["selected"]["id"] = "selected-occurrence"
    envelope["recovery"] = {"mode": "series_default_fields", "limitations": list(SERIES_LIMITATIONS)}
    if "alerts" in changed_fields and not rollback:
        envelope["after"]["alerts"] = [{"relative_minutes": -15}]
    if rollback:
        envelope["rollback"] = {**recovery_preview()["envelope"]["rollback"], "restoration": None,
                                "limitations": list(SERIES_LIMITATIONS),
                                "alarm_restoration": [] if "alerts" in changed_fields else None}
    return preview


class SeriesBroker(RecurrenceBroker):
    def recovery_capabilities(self):
        return {**RECOVERY_CAPABILITIES, "storage_version": 3}

    def series_modification_capabilities(self):
        return deepcopy(SERIES_MODIFICATION_CAPABILITIES)


class SeriesModificationSchemaTests(unittest.TestCase):
    def validate(self, name, arguments):
        validate_arguments(name, arguments, recurrence=True, series_modification=True)

    def test_preflight_allows_only_explicit_nonstructural_fields(self):
        base = {"action": "modify", "scope": "series", "event_id": "selected"}
        for fields in ({"title": "Rename"}, {"notes": "", "location": "Plain place"}, {"alerts": []},
                       {"title": "Rename", "notes": "Description", "location": "", "alerts": [{"relative_minutes": -10}]}):
            self.validate("preflight_change", {**base, "fields": fields})
        invalid = [{**base, "fields": {}}, {**base, "fields": {"title": "  "}},
                   {**base, "calendar_id": "calendar", "fields": {"title": "Rename"}},
                   {**base, "action": "delete"}, {**base, "scope": "future", "fields": {"title": "Rename"}}]
        for field, value in (("start", "2026-11-02T10:00:00Z"), ("end", "2026-11-02T11:00:00Z"),
                             ("time_zone", "Europe/London"), ("all_day", False), ("recurrence", {"frequency": "daily"})):
            invalid.append({**base, "fields": {"title": "Rename", field: value}})
        for arguments in invalid:
            with self.subTest(arguments=arguments), self.assertRaises(ValidationError):
                self.validate("preflight_change", arguments)
        with self.assertRaises(ValidationError):
            validate_arguments("preflight_change", {**base, "fields": {"title": "Rename"}}, recurrence=True)

    def test_complete_v4_preview_and_inverse_acceptance_preserves_legacy(self):
        for rollback in (False, True):
            for changed in (["title"], ["alerts", "title"]):
                preview = series_preview(rollback=rollback, changed_fields=changed)
                self.validate("commit_series_rollback" if rollback else "commit_series_modify", {"preview": preview})
                with self.assertRaises(ValidationError):
                    validate_arguments("commit_series_rollback" if rollback else "commit_series_modify", {"preview": preview}, recurrence=True)
                with self.assertRaises(ValidationError):
                    self.validate("commit_rollback" if rollback else "commit_modify", {"preview": preview})
        for action in ("create", "modify", "delete"):
            self.validate("commit_" + action, {"preview": ordinary_preview(action)})
        self.validate("commit_rollback", {"preview": recovery_preview()})
        for name in ("commit_series_modify", "commit_series_rollback"):
            with self.assertRaises(ValidationError):
                self.validate(name, {"preview": ordinary_preview("modify")})

    def test_mask_and_structural_tampering_are_rejected(self):
        mutations = [lambda e: e["series"].update(changed_fields=[]),
                     lambda e: e["series"].update(changed_fields=["title", "alerts"]),
                     lambda e: e["series"].update(changed_fields=["title", "title"]),
                     lambda e: e["series"].update(provider_scope="future"),
                     lambda e: e["after"].update(start="2026-10-24T09:00:00Z"),
                     lambda e: e["after"].update(notes="Unmasked change"),
                     lambda e: e["after"].update(alerts=[]),
                     lambda e: e["after"].update(recurrence={"frequency": "daily"}),
                     lambda e: e["before"].update(detached=True),
                     lambda e: e["before"].update(recurring=False),
                     lambda e: e["series"]["selected"].update(detached=True),
                     lambda e: e["series"]["selected"].update(occurrence=None),
                     lambda e: e["series"]["selected"].update(occurrence="2026-10-22T09:00:00Z"),
                     lambda e: e["series"]["selected"]["calendar"].update(id="different"),
                     lambda e: e["recovery"]["limitations"].reverse(),
                     lambda e: e["recovery"].update(mode="occurrence_fields"),
                     lambda e: e.update(scope="this"),
                     lambda e: e.update(action="delete")]
        for mutation in mutations:
            preview = series_preview()
            mutation(preview["envelope"])
            with self.subTest(mutation=mutation), self.assertRaises(ValidationError):
                self.validate("commit_series_modify", {"preview": preview})
        preview = series_preview(changed_fields=["alerts", "title"])
        del preview["envelope"]["after"]["alerts"]
        with self.assertRaises(ValidationError):
            self.validate("commit_series_modify", {"preview": preview})

    def test_snapshot_text_is_preserved_and_inverse_has_exact_one_source_and_alarms(self):
        preview = series_preview()
        preview["envelope"]["before"]["fields"]["notes"] = "n" * 20000
        preview["envelope"]["after"]["notes"] = "n" * 20000
        self.validate("commit_series_modify", {"preview": preview})
        preview["envelope"]["after"]["title"] = "t" * 1001
        with self.assertRaises(ValidationError):
            self.validate("commit_series_modify", {"preview": preview})
        inverse = series_preview(rollback=True)
        inverse["envelope"]["after"]["title"] = "t" * 20000
        self.validate("commit_series_rollback", {"preview": inverse})
        mutations = [lambda e: e["rollback"].update(source_change_ids=["one", "two"]),
                     lambda e: e["rollback"].update(alarm_restoration=[]),
                     lambda e: e["rollback"].update(restoration={"details": {}, "availability": "busy"}),
                     lambda e: e["rollback"]["limitations"].reverse(),
                     lambda e: e["series"]["selected"].update(id="different"),
                     lambda e: e["after"].update(alerts=[])]
        for mutation in mutations:
            preview = series_preview(rollback=True)
            mutation(preview["envelope"])
            with self.assertRaises(ValidationError):
                self.validate("commit_series_rollback", {"preview": preview})
        inverse = series_preview(rollback=True, changed_fields=["alerts", "title"])
        inverse["envelope"]["rollback"]["alarm_restoration"] = None
        with self.assertRaises(ValidationError):
            self.validate("commit_series_rollback", {"preview": inverse})
        unchanged = series_preview()
        unchanged["envelope"]["after"] = deepcopy(unchanged["envelope"]["before"]["fields"])
        with self.assertRaises(ValidationError):
            self.validate("commit_series_modify", {"preview": unchanged})

    def test_capability_is_exact_cached_and_requires_all_existing_contracts(self):
        invalid = [None, {**SERIES_MODIFICATION_CAPABILITIES, "version": True},
                   {**SERIES_MODIFICATION_CAPABILITIES, "storage_version": 2},
                   {**SERIES_MODIFICATION_CAPABILITIES, "storage_version": 3.0},
                   {**SERIES_MODIFICATION_CAPABILITIES, "extra": True},
                   {**SERIES_MODIFICATION_CAPABILITIES, "fields": list(reversed(SERIES_MODIFICATION_CAPABILITIES["fields"]))},
                   {key: value for key, value in SERIES_MODIFICATION_CAPABILITIES.items() if key != "commit_tools"},
                   {**SERIES_MODIFICATION_CAPABILITIES, "commit_tools": ["commit_modify", "commit_rollback"]},
                   {**SERIES_MODIFICATION_CAPABILITIES, "structural_changes": 0}]
        for value in invalid:
            self.assertFalse(valid_series_modification_capabilities(value))
        for value in (SERIES_MODIFICATION_CAPABILITIES, *invalid, NativeError("unknown_operation", "Old helper")):
            broker = object.__new__(NativeBroker)
            calls = []

            def call(name, arguments):
                calls.append((name, arguments))
                if isinstance(value, Exception):
                    raise value
                return value

            broker.call = call
            expected = value if value is SERIES_MODIFICATION_CAPABILITIES else None
            self.assertEqual(broker.series_modification_capabilities(), expected)
            self.assertEqual(broker.series_modification_capabilities(), expected)
            self.assertEqual(calls, [("series_modification_capabilities", {})])
        for missing in (None, "recovery_capabilities", "alerts_capabilities", "recurrence_capabilities"):
            for value in invalid if missing is None else [SERIES_MODIFICATION_CAPABILITIES]:
                broker = SeriesBroker()
                broker.series_modification_capabilities = lambda: value
                if missing:
                    setattr(broker, missing, lambda: None)
                broker.call = lambda *_: self.fail("Unverified series feature dispatched")
                protocol = Protocol(broker)
                self.assertFalse(protocol.series_modification)
                for name, arguments in (("preflight_change", {"action": "modify", "scope": "series", "event_id": "selected", "fields": {"title": "Rename"}}),
                                        ("commit_series_modify", {"preview": series_preview()}),
                                        ("commit_series_rollback", {"preview": series_preview(rollback=True)})):
                    reply = protocol.handle(request(name, arguments))["result"]
                    self.assertTrue(reply["isError"])
                    self.assertEqual(json.loads(reply["content"][0]["text"])["code"], "feature_unavailable")
        self.assertEqual(Protocol(RecurrenceBroker()).tools, RECURRENCE_TOOLS)
        legacy_storage = SeriesBroker()
        legacy_storage.recovery_capabilities = lambda: dict(RECOVERY_CAPABILITIES)
        legacy_storage.series_modification_capabilities = lambda: self.fail("Storage v2 must not probe series modification")
        self.assertFalse(Protocol(legacy_storage).series_modification)
        self.assertEqual(Protocol(legacy_storage).tools, RECURRENCE_TOOLS)


class SeriesModificationHTTPTests(unittest.TestCase):
    def test_complete_v4_discovery_and_full_preview_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic series transport ") as directory:
            state = initialize(Path(directory) / "state")
            broker = SeriesBroker()
            server = GatewayServer(0, read_token(state), Protocol(broker), state_directory=state)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                wire = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
                result = client.send(wire)
                self.assertEqual(result["result"]["tools"], SERIES_MODIFICATION_TOOLS)
                self.assertEqual(len(result["result"]["tools"]), 15)
                response = json.dumps(result).encode()
                self.assertLess(len(response), MAX_RESPONSE)
                self.assertEqual(loads(response, max_depth=32), result)
                sink = io.BytesIO()
                self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                self.assertEqual(json.loads(sink.getvalue()), result)
                for rollback in (False, True):
                    preview = series_preview(rollback=rollback, changed_fields=["alerts", "title"])
                    call = request("commit_series_rollback" if rollback else "commit_series_modify", {"preview": preview})
                    call_wire = json.dumps(call).encode()
                    self.assertEqual(loads(call_wire), call)
                    sink = io.BytesIO()
                    self.assertEqual(run_stdio(client, io.BytesIO(call_wire + b"\n"), sink), 0)
                    self.assertFalse(json.loads(sink.getvalue())["result"]["isError"])
                    self.assertEqual(broker.received, (call["params"]["name"], {"preview": preview}))
                preview = series_preview()
                Protocol(broker).handle(request("commit_series_modify", {"preview": preview}))
                self.assertIs(broker.received[1]["preview"], preview)
                with self.assertRaises(ValueError):
                    loads("[" * 21 + "1" + "]" * 21)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


@unittest.skipUnless(HELPER.is_file(), "Build native helper before synthetic series modification validation")
class NativeSeriesModificationIntegrationTests(unittest.TestCase):
    def test_native_default_fields_inverse_routing_replay_and_legacy_isolation(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic series fields ") as directory:
            state = initialize(Path(directory) / "native")
            broker = NativeBroker(HELPER, state, "synthetic", credential_binding=hashlib.sha256(b"synthetic-series-fixture").hexdigest())
            self.addCleanup(broker.close)
            if broker.series_modification_capabilities() is None:
                self.skipTest("Selected helper does not support current-series default-field modification")
            protocol = Protocol(broker)
            self.assertEqual(len(protocol.tools), 17 if protocol.future_modification else 15)

            def tool(name, arguments=None, *, error=False):
                reply = protocol.handle(request(name, arguments))
                self.assertNotIn("error", reply, reply)
                self.assertEqual(reply["result"]["isError"], error, reply)
                return reply["result"] if error else reply["result"]["structuredContent"]

            calendar = tool("list_calendars")["calendars"][0]["id"]
            create = tool("preflight_change", {"action": "create", "scope": "series", "calendar_id": calendar,
                "fields": {"title": "Original synthetic pattern", "notes": "Original default notes",
                           "start": "2026-11-02T10:00:00Z", "end": "2026-11-02T11:00:00Z",
                           "time_zone": "Europe/London", "recurrence": {"frequency": "weekly", "end": {"count": 4}},
                           "alerts": [{"relative_minutes": -30}]}})["preview"]
            original = tool("commit_create", {"preview": create})["event"]
            preview = tool("preflight_change", {"action": "modify", "scope": "series", "event_id": original["id"],
                "fields": {"title": "Renamed synthetic pattern", "notes": "Changed defaults", "alerts": []}})["preview"]
            envelope = preview["envelope"]
            self.assertEqual(envelope["version"], 4)
            self.assertEqual(envelope["series"]["changed_fields"], ["alerts", "notes", "title"])
            self.assertEqual(envelope["recovery"], {"mode": "series_default_fields", "limitations": SERIES_LIMITATIONS})
            self.assertEqual(envelope["before"]["fields"], original["fields"])
            self.assertEqual(envelope["series"]["selected"]["id"], original["id"])
            rejected = protocol.handle(request("commit_modify", {"preview": preview}))
            self.assertEqual(rejected["error"]["code"], -32602)
            self.assertEqual(tool("get_change_status", {"nonce": envelope["nonce"]})["state"], "not_received")
            altered = deepcopy(preview)
            altered["envelope"]["after"]["title"] = "Unsigned synthetic alteration"
            tool("commit_series_modify", {"preview": altered}, error=True)
            changed = tool("commit_series_modify", {"preview": preview})
            self.assertEqual(changed["state"], "applied")
            self.assertEqual(changed["event"]["fields"]["title"], "Renamed synthetic pattern")
            self.assertEqual(tool("commit_series_modify", {"preview": preview}), changed)
            self.assertEqual(tool("get_change_status", {"nonce": envelope["nonce"]}), changed)
            plan = tool("preflight_rollback", {"change_ids": [changed["nonce"]]})
            self.assertEqual(plan["step_count"], 1)
            step = plan["steps"][0]
            self.assertEqual(step["commit_tool"], "commit_series_rollback")
            inverse = step["preview"]
            self.assertEqual(inverse["envelope"]["version"], 4)
            self.assertEqual(inverse["envelope"]["series"]["changed_fields"], envelope["series"]["changed_fields"])
            self.assertEqual(inverse["envelope"]["series"]["selected"], inverse["envelope"]["before"])
            self.assertNotIn("alerts", inverse["envelope"]["after"])
            self.assertEqual(inverse["envelope"]["rollback"]["alarm_restoration"], original["details"]["alarms"])
            self.assertEqual(protocol.handle(request("commit_rollback", {"preview": inverse}))["error"]["code"], -32602)
            restored = tool("commit_series_rollback", {"preview": inverse})
            self.assertEqual(restored["state"], "applied")
            self.assertEqual(restored["event"]["fields"], original["fields"])
            self.assertEqual(restored["event"]["details"]["alarms"], original["details"]["alarms"])
            self.assertEqual(tool("commit_series_rollback", {"preview": inverse}), restored)


if __name__ == "__main__":
    unittest.main()
