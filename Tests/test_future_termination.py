"""Future termination and independent-tail-copy contracts use synthetic data only."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from zoneinfo import ZoneInfo

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import (FUTURE_TERMINATION_CAPABILITIES, NativeBroker, NativeError,
                                 RECOVERY_CAPABILITIES, valid_future_termination_capabilities)
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.schema import (FUTURE_MODIFICATION_TOOLS, FUTURE_TERMINATION_LIMITATIONS,
                                 FUTURE_TERMINATION_TOOLS, ValidationError, validate_arguments)
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from Tests.test_alerts import request
from Tests.test_future_modification import FutureBroker, future_preview
from Tests.test_native_integration import HELPER


def stamp(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def termination_preview(*, restore=False, entire=False, date_cutoff=False):
    preview = future_preview()
    envelope = preview["envelope"]
    before = deepcopy(envelope["before"])
    anchor = deepcopy(before if entire else envelope["future"]["first_anchor"])
    rule = {"frequency": "weekly", "interval": 1, "end": None}
    start = datetime(2026, 11, 1, tzinfo=timezone.utc)
    cutoff = {"date": "2026-11-01", "time_zone": "Europe/London"} if date_cutoff else {"at": stamp(start)}
    envelope.update(version=6, action="create" if restore else "delete", after=None)
    envelope["future"] = {"provider_scope": "selected_occurrence_and_future", "cutoff": cutoff,
        "resolved_cutoff": stamp(start), "boundary": before["occurrence"], "reference": deepcopy(before),
        "first_anchor": anchor, "selection_window": {"start": stamp(start), "end": stamp(start + timedelta(days=366))},
        "removes_entire_current_pattern": entire, "copy_recurrence": rule}
    envelope["recovery"] = {"mode": "independent_tail_copy", "limitations": list(FUTURE_TERMINATION_LIMITATIONS)}
    if restore:
        envelope["before"] = None
        envelope["after"] = {**deepcopy(before["fields"]), "recurrence": deepcopy(rule)}
        envelope["issued_at"], envelope["expires_at"] = "2026-11-03T00:00:00Z", "2026-11-03T00:10:00Z"
        envelope["rollback"] = {"selection_id": "selection", "source_change_ids": ["source"],
            "source_digest": "a" * 64, "restoration": {"details": deepcopy(before["details"]),
                "availability": before["availability"], "past_anchor": None if entire else deepcopy(anchor)},
            "limitations": list(FUTURE_TERMINATION_LIMITATIONS)}
    return preview


class TerminationBroker(FutureBroker):
    def recovery_capabilities(self):
        return {**RECOVERY_CAPABILITIES, "storage_version": 5}

    def future_termination_capabilities(self):
        return deepcopy(FUTURE_TERMINATION_CAPABILITIES)


class FutureTerminationSchemaTests(unittest.TestCase):
    def validate(self, name, arguments):
        validate_arguments(name, arguments, recurrence=True, series_modification=True,
                           future_modification=True, future_termination=True)

    def test_only_delete_future_accepts_and_requires_exact_cutoff(self):
        base = {"action": "delete", "scope": "future", "event_id": "reference"}
        valid = [{"date": "2026-11-02", "time_zone": "Europe/London"},
                 {"at": "2026-11-02T10:00:00+01:00"}]
        for cutoff in valid:
            self.validate("preflight_change", {**base, "cutoff": cutoff})
        invalid = [None, {}, {"date": "2026-11-02"}, {"date": "2026-02-30", "time_zone": "Europe/London"},
                   {"date": "2026-2-03", "time_zone": "Europe/London"},
                   {"date": "2026-11-02", "time_zone": "Unknown/Zone"}, {"at": "2026-11-02T10:00:00"},
                   {"at": valid[1]["at"], **valid[0]}, {"at": valid[1]["at"], "boundary": valid[1]["at"]}]
        for cutoff in invalid:
            with self.subTest(cutoff=cutoff), self.assertRaises(ValidationError):
                self.validate("preflight_change", {**base, "cutoff": cutoff})
        for arguments in (base, {**base, "cutoff": valid[0], "fields": {}},
                          {**base, "cutoff": valid[0], "calendar_id": "calendar"},
                          {**base, "cutoff": valid[0], "scope": "this"},
                          {**base, "cutoff": valid[0], "action": "modify", "fields": {"title": "Rename"}},
                          {**base, "cutoff": valid[0], "action": "create"}):
            with self.subTest(arguments=arguments), self.assertRaises(ValidationError):
                self.validate("preflight_change", arguments)
        self.validate("preflight_change", {"action": "modify", "scope": "future", "event_id": "boundary", "fields": {"title": "Rename"}})

    def test_exact_delete_restore_routes_and_past_recreation_preserve_full_snapshots(self):
        for restore in (False, True):
            name = "commit_future_restore" if restore else "commit_future_delete"
            for entire in (False, True):
                for date_cutoff in (False, True):
                    preview = termination_preview(restore=restore, entire=entire, date_cutoff=date_cutoff)
                    self.validate(name, {"preview": preview})
                    for old in ("commit_create", "commit_modify", "commit_delete", "commit_rollback",
                                "commit_series_modify", "commit_series_rollback", "commit_future_modify", "commit_future_rollback"):
                        with self.subTest(old=old), self.assertRaises(ValidationError):
                            self.validate(old, {"preview": preview})
                    with self.assertRaises(ValidationError):
                        self.validate("commit_future_delete" if restore else "commit_future_restore", {"preview": preview})
        preview = termination_preview(restore=True)
        preview["envelope"]["after"]["title"] = "t" * 20000
        preview["envelope"]["after"]["notes"] = "n" * 20000
        preview["envelope"]["rollback"]["restoration"]["details"]["alarms"] = [{"uninterpreted_fixture": [1, 2, 3]}]
        self.validate("commit_future_restore", {"preview": preview})
        for old in (future_preview(), future_preview(rollback=True)):
            for name in ("commit_future_delete", "commit_future_restore"):
                with self.assertRaises(ValidationError):
                    self.validate(name, {"preview": old})

    def test_signed_cutoff_window_boundary_and_seven_warning_tampering_fail(self):
        mutations = [lambda e: e.update(scope="this"), lambda e: e.update(action="create"),
            lambda e: e["future"].update(boundary="2026-11-03T09:00:00Z"),
            lambda e: e["future"].update(resolved_cutoff="2026-11-01T01:00:00Z"),
            lambda e: e["future"].update(removes_entire_current_pattern=True),
            lambda e: e["future"].update(provider_scope="current_pattern_from_first_occurrence"),
            lambda e: e["future"]["cutoff"].update(at="2026-11-01T02:00:00Z"),
            lambda e: e["future"]["selection_window"].update(end="2028-11-01T00:00:00Z"),
            lambda e: e["future"]["copy_recurrence"].update(end={"count": 4}),
            lambda e: e["future"]["reference"].update(detached=True),
            lambda e: e["future"]["first_anchor"]["calendar"].update(id="other"),
            lambda e: e["before"].update(recurring=False),
            lambda e: e["before"]["fields"].update(start="2026-11-03T09:00:00Z"),
            lambda e: e["recovery"].update(mode="unavailable"),
            lambda e: e["recovery"]["limitations"].reverse(),
            lambda e: e["recovery"]["limitations"].pop(),
            lambda e: e.update(expires_at="2026-11-03T00:00:00Z"),
            lambda e: e.update(issued_at=e["future"]["boundary"]),
            lambda e: e.update(rollback={}), lambda e: e.update(after=e["before"]["fields"])]
        for mutation in mutations:
            preview = termination_preview()
            mutation(preview["envelope"])
            with self.subTest(mutation=mutation), self.assertRaises(ValidationError):
                self.validate("commit_future_delete", {"preview": preview})
        inverse_mutations = [lambda e: e["after"].pop("recurrence"),
            lambda e: e["after"].update(alerts=[]), lambda e: e["after"].update(start="2026-11-03T09:00:00Z"),
            lambda e: e["after"]["recurrence"].update(interval=2),
            lambda e: e["rollback"].update(source_change_ids=["one", "two"]),
            lambda e: e["rollback"].update(alarm_restoration=[]),
            lambda e: e["rollback"]["restoration"].update(past_anchor=None),
            lambda e: e["rollback"]["restoration"]["past_anchor"].update(id="other"),
            lambda e: e["rollback"]["limitations"].reverse()]
        for mutation in inverse_mutations:
            preview = termination_preview(restore=True)
            mutation(preview["envelope"])
            with self.subTest(mutation=mutation), self.assertRaises(ValidationError):
                self.validate("commit_future_restore", {"preview": preview})

    def test_local_date_window_keeps_calendar_days_across_dst_and_extremes_fail_safely(self):
        preview = termination_preview(date_cutoff=True)
        future = preview["envelope"]["future"]
        zone = ZoneInfo("Europe/London")
        start = datetime(2026, 10, 24, tzinfo=zone)
        future["cutoff"]["date"] = "2026-10-24"
        future["resolved_cutoff"] = future["selection_window"]["start"] = stamp(start)
        future["selection_window"]["end"] = stamp(start + timedelta(days=366))
        self.validate("commit_future_delete", {"preview": preview})
        future["selection_window"]["end"] = stamp(start.astimezone(timezone.utc) + timedelta(days=366))
        # This pair of dates has the same offset; use a spring boundary to prove a varying offset.
        future["cutoff"]["date"] = "2026-03-29"
        start = datetime(2026, 3, 29, tzinfo=zone)
        future["resolved_cutoff"] = future["selection_window"]["start"] = stamp(start)
        future["selection_window"]["end"] = stamp(start + timedelta(days=366))
        preview["envelope"]["issued_at"], preview["envelope"]["expires_at"] = "2026-03-28T00:00:00Z", "2026-03-28T00:10:00Z"
        self.validate("commit_future_delete", {"preview": preview})
        future["selection_window"]["end"] = stamp(start.astimezone(timezone.utc) + timedelta(days=366))
        with self.assertRaises(ValidationError):
            self.validate("commit_future_delete", {"preview": preview})
        extreme = termination_preview()
        extreme["envelope"]["future"].update(resolved_cutoff="9999-11-01T00:00:00Z", boundary="9999-11-02T00:00:00Z", cutoff={"at": "9999-11-01T00:00:00Z"})
        extreme["envelope"]["future"]["selection_window"] = {"start": "9999-11-01T00:00:00Z", "end": "9999-12-01T00:00:00Z"}
        with self.assertRaises(ValidationError):
            self.validate("commit_future_delete", {"preview": extreme})

    def test_exact_capability_cache_all_dependencies_and_truthful_annotations(self):
        invalid = [None, {**FUTURE_TERMINATION_CAPABILITIES, "version": True},
            {**FUTURE_TERMINATION_CAPABILITIES, "storage_version": 4},
            {**FUTURE_TERMINATION_CAPABILITIES, "max_selection_days": 366.0},
            {**FUTURE_TERMINATION_CAPABILITIES, "recovery": False},
            {**FUTURE_TERMINATION_CAPABILITIES, "cutoff_forms": ["offset_datetime", "date_with_time_zone"]},
            {**FUTURE_TERMINATION_CAPABILITIES, "commit_tools": ["commit_delete", "commit_rollback"]},
            {**FUTURE_TERMINATION_CAPABILITIES, "extra": True}]
        invalid.extend({key: value for key, value in FUTURE_TERMINATION_CAPABILITIES.items() if key != missing}
                       for missing in FUTURE_TERMINATION_CAPABILITIES)
        for value in (FUTURE_TERMINATION_CAPABILITIES, *invalid, NativeError("unknown_operation", "Old helper")):
            broker = object.__new__(NativeBroker)
            calls = []
            def call(name, arguments):
                calls.append((name, arguments))
                if isinstance(value, Exception):
                    raise value
                return value
            broker.call = call
            expected = value if value is FUTURE_TERMINATION_CAPABILITIES else None
            self.assertEqual(broker.future_termination_capabilities(), expected)
            self.assertEqual(broker.future_termination_capabilities(), expected)
            self.assertEqual(calls, [("future_termination_capabilities", {})])
        for missing in (None, "recovery_capabilities", "alerts_capabilities", "recurrence_capabilities",
                        "series_modification_capabilities", "future_modification_capabilities"):
            for value in invalid if missing is None else [FUTURE_TERMINATION_CAPABILITIES]:
                broker = TerminationBroker()
                broker.future_termination_capabilities = lambda: value
                if missing:
                    setattr(broker, missing, lambda: None)
                broker.call = lambda *_: self.fail("Unverified termination dispatched")
                protocol = Protocol(broker)
                self.assertFalse(protocol.future_termination)
                for name, arguments in (("preflight_change", {"action": "delete", "scope": "future", "event_id": "ref", "cutoff": {"at": "2026-11-01T00:00:00Z"}}),
                                        ("commit_future_delete", {"preview": termination_preview()}),
                                        ("commit_future_restore", {"preview": termination_preview(restore=True)})):
                    result = protocol.handle(request(name, arguments))["result"]
                    self.assertTrue(result["isError"])
                    self.assertEqual(json.loads(result["content"][0]["text"])["code"], "feature_unavailable")
        old = TerminationBroker()
        old.recovery_capabilities = lambda: {**RECOVERY_CAPABILITIES, "storage_version": 4}
        old.future_termination_capabilities = lambda: self.fail("Floor4 must not probe termination support")
        self.assertEqual(Protocol(old).tools, FUTURE_MODIFICATION_TOOLS)
        annotations = {tool["name"]: tool["annotations"] for tool in FUTURE_TERMINATION_TOOLS}
        self.assertEqual(annotations["commit_future_delete"], {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": True, "openWorldHint": False})
        self.assertEqual(annotations["commit_future_restore"], annotations["commit_create"])


class FutureTerminationHTTPTests(unittest.TestCase):
    def test_complete_nineteen_tool_discovery_and_verbatim_delete_restore_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic termination transport ") as directory:
            state = initialize(Path(directory) / "state")
            broker = TerminationBroker()
            protocol = Protocol(broker)
            server = GatewayServer(0, read_token(state), protocol, state_directory=state)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                client = GatewayClient(state, server.server_port)
                wire = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
                result = client.send(wire)
                self.assertEqual(result["result"]["tools"], FUTURE_TERMINATION_TOOLS)
                self.assertEqual(len(result["result"]["tools"]), 19)
                self.assertLess(len(json.dumps(result).encode()), MAX_RESPONSE)
                self.assertEqual(loads(json.dumps(result), max_depth=32), result)
                sink = io.BytesIO()
                self.assertEqual(run_stdio(client, io.BytesIO(wire + b"\n"), sink), 0)
                self.assertEqual(json.loads(sink.getvalue()), result)
                for restore in (False, True):
                    name = "commit_future_restore" if restore else "commit_future_delete"
                    preview = termination_preview(restore=restore)
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


@unittest.skipUnless(HELPER.is_file(), "Build native helper before synthetic future termination validation")
class NativeFutureTerminationIntegrationTests(unittest.TestCase):
    def test_native_cutoff_delete_independent_new_series_restore_and_replay(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic termination lifecycle ") as directory:
            state = initialize(Path(directory) / "native")
            broker = NativeBroker(HELPER, state, "synthetic", credential_binding=hashlib.sha256(b"synthetic-termination-fixture").hexdigest())
            self.addCleanup(broker.close)
            if broker.future_termination_capabilities() is None:
                self.skipTest("Selected helper does not support future termination")
            protocol = Protocol(broker)
            self.assertEqual(len(protocol.tools), 19)
            def tool(name, arguments=None, *, error=False):
                reply = protocol.handle(request(name, arguments))
                self.assertNotIn("error", reply, reply)
                self.assertEqual(reply["result"]["isError"], error, reply)
                return reply["result"] if error else reply["result"]["structuredContent"]
            calendar = tool("list_calendars")["calendars"][0]["id"]
            start = (datetime.now(timezone.utc) + timedelta(days=7)).replace(hour=10, minute=0, second=0, microsecond=0)
            draft = tool("preflight_change", {"action": "create", "scope": "series", "calendar_id": calendar,
                "fields": {"title": "Synthetic termination pattern", "notes": "Synthetic retained defaults",
                    "start": stamp(start), "end": stamp(start + timedelta(hours=1)), "time_zone": "Europe/London",
                    "recurrence": {"frequency": "weekly"}, "alerts": [{"relative_minutes": -30}]}})["preview"]
            original = tool("commit_create", {"preview": draft})["event"]
            plan = tool("preflight_change", {"action": "delete", "scope": "future", "event_id": original["id"], "cutoff": {"at": stamp(start)}})
            self.assertEqual(plan["commit_tool"], "commit_future_delete")
            preview = plan["preview"]
            envelope = preview["envelope"]
            self.assertEqual(envelope["version"], 6)
            self.assertEqual(envelope["before"], original)
            self.assertTrue(envelope["future"]["removes_entire_current_pattern"])
            self.assertEqual(envelope["recovery"], {"mode": "independent_tail_copy", "limitations": FUTURE_TERMINATION_LIMITATIONS})
            for old in ("commit_delete", "commit_future_modify", "commit_future_rollback"):
                self.assertEqual(protocol.handle(request(old, {"preview": preview}))["error"]["code"], -32602)
            self.assertEqual(tool("get_change_status", {"nonce": envelope["nonce"]})["state"], "not_received")
            altered = deepcopy(preview)
            altered["authentication_tag"] += "unsigned"
            tool("commit_future_delete", {"preview": altered}, error=True)
            deleted = tool("commit_future_delete", {"preview": preview})
            self.assertEqual(deleted["state"], "applied")
            self.assertEqual(tool("commit_future_delete", {"preview": preview}), deleted)
            recovered = tool("preflight_rollback", {"change_ids": [deleted["nonce"]]})
            self.assertEqual(recovered["step_count"], 1)
            step = recovered["steps"][0]
            self.assertEqual(step["commit_tool"], "commit_future_restore")
            inverse = step["preview"]
            self.assertEqual(inverse["envelope"]["action"], "create")
            self.assertEqual(inverse["envelope"]["future"], envelope["future"])
            self.assertEqual(inverse["envelope"]["after"]["recurrence"], envelope["future"]["copy_recurrence"])
            self.assertIsNone(inverse["envelope"]["rollback"]["restoration"]["past_anchor"])
            for old in ("commit_create", "commit_rollback", "commit_future_rollback"):
                self.assertEqual(protocol.handle(request(old, {"preview": inverse}))["error"]["code"], -32602)
            restored = tool("commit_future_restore", {"preview": inverse})
            self.assertEqual(restored["state"], "applied")
            self.assertNotEqual(restored["event"]["id"], original["id"])
            self.assertEqual(restored["event"]["fields"], original["fields"])
            self.assertEqual(restored["event"]["details"]["alarms"], original["details"]["alarms"])
            self.assertTrue(restored["event"]["recurring"])
            self.assertEqual(tool("commit_future_restore", {"preview": inverse}), restored)
            tool("preflight_rollback", {"change_ids": [deleted["nonce"]]}, error=True)


if __name__ == "__main__":
    unittest.main()
