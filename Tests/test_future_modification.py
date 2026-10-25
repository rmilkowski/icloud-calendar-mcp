"""Future default-field contracts use synthetic views and isolated transports."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import (FUTURE_MODIFICATION_CAPABILITIES, NativeBroker, NativeError,
                                 RECOVERY_CAPABILITIES, valid_future_modification_capabilities)
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.schema import (FUTURE_LIMITATIONS, FUTURE_MODIFICATION_TOOLS,
                                 SERIES_MODIFICATION_TOOLS, ValidationError, validate_arguments)
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from Tests.test_alerts import request
from Tests.test_native_integration import HELPER
from Tests.test_series_modification import SeriesBroker, series_preview


def future_preview(*, rollback=False, changed_fields=None):
    preview = series_preview(rollback=rollback, changed_fields=changed_fields)
    envelope = preview["envelope"]
    envelope["version"], envelope["scope"] = 5, "future"
    series = envelope.pop("series")
    anchor = deepcopy(envelope["before"])
    selected = deepcopy(anchor)
    selected["id"] = "future-boundary"
    selected["occurrence"] = selected["fields"]["start"] = "2026-11-02T09:00:00Z"
    selected["fields"]["end"] = "2026-11-02T10:00:00Z"
    envelope["before"] = selected
    envelope["after"].update(start=selected["fields"]["start"], end=selected["fields"]["end"])
    envelope["future"] = {"provider_scope": "selected_occurrence_and_future",
                          "boundary": selected["occurrence"], "first_anchor": selected if rollback else anchor,
                          "changed_fields": series["changed_fields"]}
    envelope["recovery"] = {"mode": "future_default_fields", "limitations": list(FUTURE_LIMITATIONS)}
    if rollback:
        envelope["rollback"]["limitations"] = list(FUTURE_LIMITATIONS)
    return preview


class FutureBroker(SeriesBroker):
    def recovery_capabilities(self):
        return {**RECOVERY_CAPABILITIES, "storage_version": 4}

    def future_modification_capabilities(self):
        return deepcopy(FUTURE_MODIFICATION_CAPABILITIES)


class FutureModificationSchemaTests(unittest.TestCase):
    def validate(self, name, arguments):
        validate_arguments(name, arguments, recurrence=True, series_modification=True, future_modification=True)

    def test_preflight_future_requires_modify_exact_reference_and_only_default_fields(self):
        base = {"action": "modify", "scope": "future", "event_id": "selected"}
        for fields in ({"title": "Rename"}, {"notes": "", "location": "Plain place"}, {"alerts": []}):
            self.validate("preflight_change", {**base, "fields": fields})
        invalid = [{**base, "fields": {}}, {**base, "fields": {"title": " "}},
                   {**base, "calendar_id": "calendar", "fields": {"title": "Rename"}},
                   {"action": "create", "scope": "future", "calendar_id": "calendar",
                    "fields": {"title": "Rename", "start": "2026-11-02T09:00:00Z", "end": "2026-11-02T10:00:00Z"}},
                   {**base, "action": "delete"}]
        for field, value in (("start", "2026-11-02T09:00:00Z"), ("end", "2026-11-02T10:00:00Z"),
                             ("time_zone", "Europe/London"), ("all_day", False), ("recurrence", {"frequency": "daily"})):
            invalid.append({**base, "fields": {"title": "Rename", field: value}})
        for arguments in invalid:
            with self.subTest(arguments=arguments), self.assertRaises(ValidationError):
                self.validate("preflight_change", arguments)
        with self.assertRaises(ValidationError):
            validate_arguments("preflight_change", {**base, "fields": {"title": "Rename"}}, recurrence=True, series_modification=True)

    def test_exact_v5_routes_preserve_old_contracts_and_full_snapshots(self):
        for rollback in (False, True):
            name = "commit_future_rollback" if rollback else "commit_future_modify"
            for mask in (["title"], ["alerts", "notes", "title"]):
                preview = future_preview(rollback=rollback, changed_fields=mask)
                self.validate(name, {"preview": preview})
                for old in ("commit_create", "commit_modify", "commit_delete", "commit_rollback", "commit_series_modify", "commit_series_rollback"):
                    with self.subTest(old=old), self.assertRaises(ValidationError):
                        self.validate(old, {"preview": preview})
                with self.assertRaises(ValidationError):
                    self.validate("commit_future_modify" if rollback else "commit_future_rollback", {"preview": preview})
        self.validate("commit_series_modify", {"preview": series_preview()})
        self.validate("commit_series_rollback", {"preview": series_preview(rollback=True)})
        for old in (series_preview(), series_preview(rollback=True)):
            for name in ("commit_future_modify", "commit_future_rollback"):
                with self.assertRaises(ValidationError):
                    self.validate(name, {"preview": old})
        for rollback in (False, True):
            preview = future_preview(rollback=rollback)
            envelope = preview["envelope"]
            envelope["before"]["fields"]["notes"] = envelope["after"]["notes"] = "n" * 20000
            self.validate("commit_future_rollback" if rollback else "commit_future_modify", {"preview": preview})
        inverse = future_preview(rollback=True)
        inverse["envelope"]["after"]["title"] = "t" * 20000
        self.validate("commit_future_rollback", {"preview": inverse})

    def test_boundary_mask_anchor_disclosure_and_inverse_tampering_fail(self):
        mutations = [lambda e: e.update(scope="series"), lambda e: e.update(action="delete"),
                     lambda e: e["future"].update(provider_scope="current_pattern_from_first_occurrence"),
                     lambda e: e["future"].update(boundary="2026-11-03T09:00:00Z"),
                     lambda e: e["future"].update(changed_fields=[]),
                     lambda e: e["future"].update(changed_fields=["title", "alerts"]),
                     lambda e: e["future"].update(changed_fields=["title", "title"]),
                     lambda e: e["future"]["first_anchor"].update(detached=True),
                     lambda e: e["future"]["first_anchor"].update(occurrence="2026-11-03T09:00:00Z"),
                     lambda e: e["future"]["first_anchor"]["details"].update(recurrence_rules=[{"frequency": 0}]),
                     lambda e: e["future"]["first_anchor"]["calendar"].update(id="other"),
                     lambda e: e["future"]["first_anchor"].update(id=e["before"]["id"]),
                     lambda e: e["before"].update(detached=True), lambda e: e["before"].update(recurring=False),
                     lambda e: e["before"].update(occurrence=None),
                     lambda e: e["after"].update(start="2026-11-03T09:00:00Z"),
                     lambda e: e["after"].update(notes="Unmasked"), lambda e: e["after"].update(alerts=[]),
                     lambda e: e["after"].update(title="t" * 1001),
                     lambda e: e["recovery"]["limitations"].reverse(),
                     lambda e: e["recovery"].update(mode="series_default_fields"),
                     lambda e: e.update(expires_at="2026-11-03T09:00:00Z"),
                     lambda e: e.update(issued_at=e["future"]["boundary"])]
        for mutation in mutations:
            preview = future_preview()
            mutation(preview["envelope"])
            with self.subTest(mutation=mutation), self.assertRaises(ValidationError):
                self.validate("commit_future_modify", {"preview": preview})
        inverse_mutations = [lambda e: e["rollback"].update(source_change_ids=["one", "two"]),
                             lambda e: e["rollback"].update(alarm_restoration=[]),
                             lambda e: e["rollback"]["limitations"].reverse(),
                             lambda e: e["future"]["first_anchor"].update(id="other"),
                             lambda e: e["after"].update(alerts=[])]
        for mutation in inverse_mutations:
            preview = deepcopy(future_preview(rollback=True))
            # Do not let fixture aliases turn one-sided tampering into equal views.
            preview["envelope"]["future"]["first_anchor"] = deepcopy(preview["envelope"]["before"])
            mutation(preview["envelope"])
            with self.assertRaises(ValidationError):
                self.validate("commit_future_rollback", {"preview": preview})
        preview = future_preview(rollback=True, changed_fields=["alerts", "title"])
        preview["envelope"]["rollback"]["alarm_restoration"] = None
        with self.assertRaises(ValidationError):
            self.validate("commit_future_rollback", {"preview": preview})

    def test_capability_is_exact_cached_and_all_dependencies_are_required(self):
        invalid = [None, {**FUTURE_MODIFICATION_CAPABILITIES, "version": True},
                   {**FUTURE_MODIFICATION_CAPABILITIES, "storage_version": 3},
                   {**FUTURE_MODIFICATION_CAPABILITIES, "preview_version": 5.0},
                   {**FUTURE_MODIFICATION_CAPABILITIES, "extra": True},
                   {**FUTURE_MODIFICATION_CAPABILITIES, "boundary": "after_selected"},
                   {**FUTURE_MODIFICATION_CAPABILITIES, "recurrence_ends": ["until", "unbounded"]},
                   {**FUTURE_MODIFICATION_CAPABILITIES, "commit_tools": ["commit_modify", "commit_rollback"]}]
        invalid.extend({key: value for key, value in FUTURE_MODIFICATION_CAPABILITIES.items() if key != missing}
                       for missing in FUTURE_MODIFICATION_CAPABILITIES)
        for value in (FUTURE_MODIFICATION_CAPABILITIES, *invalid, NativeError("unknown_operation", "Old helper")):
            broker = object.__new__(NativeBroker)
            calls = []
            def call(name, arguments):
                calls.append((name, arguments))
                if isinstance(value, Exception):
                    raise value
                return value
            broker.call = call
            expected = value if value is FUTURE_MODIFICATION_CAPABILITIES else None
            self.assertEqual(broker.future_modification_capabilities(), expected)
            self.assertEqual(broker.future_modification_capabilities(), expected)
            self.assertEqual(calls, [("future_modification_capabilities", {})])
        for missing in (None, "recovery_capabilities", "alerts_capabilities", "recurrence_capabilities", "series_modification_capabilities"):
            for value in invalid if missing is None else [FUTURE_MODIFICATION_CAPABILITIES]:
                broker = FutureBroker()
                broker.future_modification_capabilities = lambda: value
                if missing:
                    setattr(broker, missing, lambda: None)
                broker.call = lambda *_: self.fail("Unverified future feature dispatched")
                protocol = Protocol(broker)
                self.assertFalse(protocol.future_modification)
                for name, arguments in (("preflight_change", {"action": "modify", "scope": "future", "event_id": "selected", "fields": {"title": "Rename"}}),
                                        ("commit_future_modify", {"preview": future_preview()}),
                                        ("commit_future_rollback", {"preview": future_preview(rollback=True)})):
                    result = protocol.handle(request(name, arguments))["result"]
                    self.assertTrue(result["isError"])
                    self.assertEqual(json.loads(result["content"][0]["text"])["code"], "feature_unavailable")
        legacy = FutureBroker()
        legacy.recovery_capabilities = lambda: {**RECOVERY_CAPABILITIES, "storage_version": 3}
        legacy.future_modification_capabilities = lambda: self.fail("Floor3 must not probe future support")
        self.assertEqual(Protocol(legacy).tools, SERIES_MODIFICATION_TOOLS)
        self.assertTrue(Protocol(FutureBroker()).future_modification)


class FutureModificationHTTPTests(unittest.TestCase):
    def test_full_seventeen_tool_discovery_and_verbatim_v5_http_stdio_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic future transport ") as directory:
            state = initialize(Path(directory) / "state")
            broker = FutureBroker()
            protocol = Protocol(broker)
            server = GatewayServer(0, read_token(state), protocol, state_directory=state)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                wire = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
                result = client.send(wire)
                self.assertEqual(result["result"]["tools"], FUTURE_MODIFICATION_TOOLS)
                self.assertEqual(len(result["result"]["tools"]), 17)
                response = json.dumps(result).encode()
                self.assertLess(len(response), MAX_RESPONSE)
                self.assertEqual(loads(response, max_depth=32), result)
                sink = io.BytesIO()
                self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                self.assertEqual(json.loads(sink.getvalue()), result)
                instructions = protocol.handle({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {
                    "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {}}})["result"]["instructions"]
                self.assertIn("commit_future_modify", instructions)
                self.assertIn("commit_future_rollback", instructions)
                self.assertNotIn("future scope and series deletion remain unsupported", instructions)
                self.assertNotIn("scope future and whole-series deletion are unsupported", instructions)
                for rollback in (False, True):
                    name = "commit_future_rollback" if rollback else "commit_future_modify"
                    preview = future_preview(rollback=rollback, changed_fields=["alerts", "title"])
                    call = request(name, {"preview": preview})
                    sink = io.BytesIO()
                    self.assertEqual(run_stdio(client, io.BytesIO(json.dumps(call).encode() + b"\n"), sink), 0)
                    self.assertFalse(json.loads(sink.getvalue())["result"]["isError"])
                    self.assertEqual(broker.received, (name, {"preview": preview}))
                    protocol.handle(call)
                    self.assertIs(broker.received[1]["preview"], preview)
                with self.assertRaises(ValueError):
                    loads("[" * 21 + "1" + "]" * 21)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


@unittest.skipUnless(HELPER.is_file(), "Build native helper before synthetic future modification validation")
class NativeFutureModificationIntegrationTests(unittest.TestCase):
    def test_native_v5_fields_inverse_route_tamper_and_replay(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic future fields ") as directory:
            state = initialize(Path(directory) / "native")
            broker = NativeBroker(HELPER, state, "synthetic", credential_binding=hashlib.sha256(b"synthetic-future-fixture").hexdigest())
            self.addCleanup(broker.close)
            if broker.future_modification_capabilities() is None:
                self.skipTest("Selected helper does not support future default-field modification")
            protocol = Protocol(broker)
            self.assertEqual(len(protocol.tools), 19 if protocol.future_termination else 17)
            def tool(name, arguments=None, *, error=False):
                reply = protocol.handle(request(name, arguments))
                self.assertNotIn("error", reply, reply)
                self.assertEqual(reply["result"]["isError"], error, reply)
                return reply["result"] if error else reply["result"]["structuredContent"]
            calendar = tool("list_calendars")["calendars"][0]["id"]
            start = (datetime.now(timezone.utc) + timedelta(days=7)).replace(hour=10, minute=0, second=0, microsecond=0)
            stamp = lambda value: value.isoformat(timespec="seconds").replace("+00:00", "Z")
            creation = tool("preflight_change", {"action": "create", "scope": "series", "calendar_id": calendar,
                "fields": {"title": "Original synthetic future pattern", "notes": "Original defaults",
                           "start": stamp(start), "end": stamp(start + timedelta(hours=1)),
                           "time_zone": "Europe/London", "recurrence": {"frequency": "weekly"},
                           "alerts": [{"relative_minutes": -30}]}})["preview"]
            original = tool("commit_create", {"preview": creation})["event"]
            draft = tool("preflight_change", {"action": "modify", "scope": "future", "event_id": original["id"],
                "fields": {"title": "Changed synthetic future pattern", "alerts": []}})
            self.assertEqual(draft["commit_tool"], "commit_future_modify")
            preview = draft["preview"]
            envelope = preview["envelope"]
            self.assertEqual(envelope["version"], 5)
            self.assertEqual(envelope["before"], original)
            self.assertEqual(envelope["future"]["boundary"], original["fields"]["start"])
            self.assertEqual(envelope["future"]["changed_fields"], ["alerts", "title"])
            self.assertEqual(envelope["recovery"], {"mode": "future_default_fields", "limitations": FUTURE_LIMITATIONS})
            for old in ("commit_modify", "commit_series_modify"):
                self.assertEqual(protocol.handle(request(old, {"preview": preview}))["error"]["code"], -32602)
            self.assertEqual(tool("get_change_status", {"nonce": envelope["nonce"]})["state"], "not_received")
            altered = deepcopy(preview)
            altered["envelope"]["after"]["title"] = "Unsigned alteration"
            tool("commit_future_modify", {"preview": altered}, error=True)
            changed = tool("commit_future_modify", {"preview": preview})
            self.assertEqual(changed["state"], "applied")
            self.assertEqual(changed["event"]["fields"]["title"], "Changed synthetic future pattern")
            self.assertEqual(tool("commit_future_modify", {"preview": preview}), changed)
            plan = tool("preflight_rollback", {"change_ids": [changed["nonce"]]})
            self.assertEqual(plan["step_count"], 1)
            step = plan["steps"][0]
            self.assertEqual(step["commit_tool"], "commit_future_rollback")
            inverse = step["preview"]
            self.assertEqual(inverse["envelope"]["future"]["first_anchor"], inverse["envelope"]["before"])
            self.assertEqual(inverse["envelope"]["rollback"]["alarm_restoration"], original["details"]["alarms"])
            restored = tool("commit_future_rollback", {"preview": inverse})
            self.assertEqual(restored["state"], "applied")
            self.assertEqual(restored["event"]["fields"], original["fields"])
            self.assertEqual(restored["event"]["details"]["alarms"], original["details"]["alarms"])
            self.assertEqual(tool("commit_future_rollback", {"preview": inverse}), restored)


if __name__ == "__main__":
    unittest.main()
