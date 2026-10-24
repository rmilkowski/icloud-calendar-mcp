"""Multiple-alert transport and actual-native tests use isolated synthetic state."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from calendar_mcp.native import ALERTS_CAPABILITIES, NativeBroker, NativeError, RECOVERY_CAPABILITIES
from calendar_mcp.protocol import Protocol
from calendar_mcp.schema import ValidationError, validate_arguments
from calendar_mcp.security import initialize
from Tests.test_changes import recovery_preview
from Tests.test_native_integration import HELPER


def request(name, arguments=None):
    return {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}}}


class AlertSchemaTests(unittest.TestCase):
    def test_replacement_list_limits_types_and_canonical_duplicates(self):
        base = {"action": "modify", "scope": "this", "event_id": "fixture"}
        for alerts in ([], [{"relative_minutes": -30}, {"relative_minutes": 0}, {"relative_minutes": 10},
                            {"at": "2026-10-25T12:00:00+01:00"}],
                       [{"relative_minutes": -525600}, {"relative_minutes": 525600}]):
            validate_arguments("preflight_change", {**base, "fields": {"alerts": alerts}})
        invalid = [None, {}, [None], [{"relative_minutes": True}], [{"relative_minutes": 1.5}],
                   [{"relative_minutes": -525601}], [{"relative_minutes": 525601}],
                   [{"relative_minutes": 0, "at": "2026-10-25T12:00:00Z"}],
                   [{"relative_minutes": 0, "type": "email"}], [{}],
                   [{"at": "2026-10-25T12:00:00"}], [{"at": None}],
                   [{"at": "0001-01-01T00:00:00+01:00"}],
                   [{"at": "9999-12-31T23:59:59-01:00"}],
                   [{"relative_minutes": 0}] * 11, [{"relative_minutes": -5}] * 2,
                   [{"at": "2026-10-25T12:00:00+01:00"}, {"at": "2026-10-25T11:00:00Z"}]]
        for alerts in invalid:
            with self.subTest(alerts=alerts), self.assertRaises(ValidationError):
                validate_arguments("preflight_change", {**base, "fields": {"alerts": alerts}})

    def test_preview_versions_keep_legacy_shapes_and_exact_native_restoration(self):
        old = recovery_preview()
        validate_arguments("commit_rollback", {"preview": old})
        normal = deepcopy(old)
        del normal["envelope"]["rollback"]
        normal["envelope"]["after"] = dict(normal["envelope"]["after"])
        validate_arguments("commit_modify", {"preview": normal})
        normal["envelope"]["after"]["alerts"] = [{"relative_minutes": -15}]
        with self.assertRaises(ValidationError):
            validate_arguments("commit_modify", {"preview": normal})
        normal["envelope"]["version"] = 2
        validate_arguments("commit_modify", {"preview": normal})
        with self.assertRaises(ValidationError):
            validate_arguments("commit_modify", {"preview": normal}, alerts=False)
        create = deepcopy(normal)
        create["envelope"]["action"] = "create"
        create["envelope"]["before"] = None
        validate_arguments("commit_create", {"preview": create})
        del create["envelope"]["after"]["alerts"]
        with self.assertRaises(ValidationError):
            validate_arguments("commit_create", {"preview": create})
        old["envelope"]["version"] = 2
        with self.assertRaises(ValidationError):
            validate_arguments("commit_rollback", {"preview": old})
        # Recovery preserves complete native alarms, beyond the public ten-alert limit.
        old["envelope"]["rollback"]["alarm_restoration"] = [{"type": 1, "sound_name": "fixture"}] * 11
        validate_arguments("commit_rollback", {"preview": old})
        old["envelope"]["version"] = 1
        with self.assertRaises(ValidationError):
            validate_arguments("commit_rollback", {"preview": old})

    def test_capability_gate_publishes_truthful_schema_and_never_dispatches(self):
        for native in (None, {**ALERTS_CAPABILITIES, "version": True},
                       {**ALERTS_CAPABILITIES, "extra": True}, {**ALERTS_CAPABILITIES, "max_alerts": 9}):
            class Broker:
                def alerts_capabilities(self):
                    return native

                def recovery_capabilities(self):
                    return dict(RECOVERY_CAPABILITIES)

                def call(self, name, arguments):
                    raise AssertionError("Unsupported alert payload must never dispatch")
            protocol = Protocol(Broker())
            published = protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
            self.assertEqual(len(published), 13)
            preflight = next(item for item in published if item["name"] == "preflight_change")
            self.assertNotIn("alerts", preflight["inputSchema"]["properties"]["fields"]["properties"])
            v2 = recovery_preview()
            v2["envelope"]["version"] = 2
            for name, arguments in (("preflight_change", {"action": "modify", "scope": "this", "event_id": "fixture", "fields": {"alerts": []}}),
                                    ("commit_modify", {"preview": v2})):
                result = protocol.handle(request(name, arguments))["result"]
                self.assertTrue(result["isError"])
                self.assertEqual(json.loads(result["content"][0]["text"])["code"], "feature_unavailable")

    def test_verified_capability_forwards_complete_preview_unchanged_and_caches_probe(self):
        broker = object.__new__(NativeBroker)
        calls = []
        broker.call = lambda name, arguments: calls.append((name, arguments)) or dict(ALERTS_CAPABILITIES)
        self.assertEqual(broker.alerts_capabilities(), ALERTS_CAPABILITIES)
        self.assertEqual(broker.alerts_capabilities(), ALERTS_CAPABILITIES)
        self.assertEqual(calls, [("alerts_capabilities", {})])
        unavailable = object.__new__(NativeBroker)
        def unsupported(name, arguments):
            raise NativeError("unknown_operation", "Old helper")
        unavailable.call = unsupported
        self.assertIsNone(unavailable.alerts_capabilities())
        self.assertIsNone(unavailable.alerts_capabilities())
        class Broker:
            def alerts_capabilities(self):
                return dict(ALERTS_CAPABILITIES)

            def call(self, name, arguments):
                self.received = (name, arguments)
                return {"state": "applied"}
        broker = Broker()
        preview = recovery_preview()
        del preview["envelope"]["rollback"]
        preview["envelope"]["after"] = dict(preview["envelope"]["after"])
        preview["envelope"]["version"] = 2
        preview["envelope"]["after"]["alerts"] = [{"relative_minutes": -15}, {"relative_minutes": 0}]
        arguments = {"preview": preview}
        protocol = Protocol(broker)
        result = protocol.handle(request("commit_modify", arguments))["result"]
        self.assertFalse(result["isError"])
        self.assertIs(broker.received[1]["preview"], preview)
        received = broker.received
        rejected = protocol.handle(request("preflight_change", {"action": "modify", "scope": "this",
            "event_id": "fixture", "fields": {"alerts": [{"at": "0001-01-01T00:00:00+01:00"}]}}))
        self.assertEqual(rejected["error"]["code"], -32602)
        self.assertIs(broker.received, received)


@unittest.skipUnless(HELPER.is_file(), "Build native helper before synthetic alert validation")
class NativeAlertIntegrationTests(unittest.TestCase):
    def test_native_creation_management_preservation_replay_and_raw_recovery(self):
        with tempfile.TemporaryDirectory(prefix="calendar synthetic alerts ") as directory:
            state = initialize(Path(directory) / "native")
            broker = NativeBroker(HELPER, state, "synthetic", credential_binding=hashlib.sha256(b"synthetic-alert-fixture").hexdigest())
            self.addCleanup(broker.close)
            if broker.alerts_capabilities() is None:
                self.skipTest("Selected native helper does not support multiple alerts")
            protocol = Protocol(broker)
            def tool(name, arguments=None, *, error=False):
                reply = protocol.handle(request(name, arguments))
                self.assertNotIn("error", reply, reply)
                self.assertEqual(reply["result"]["isError"], error, reply)
                return reply["result"] if error else reply["result"]["structuredContent"]
            calendar = tool("list_calendars")["calendars"][0]["id"]
            initial = [{"relative_minutes": -30}, {"at": "2026-10-25T10:45:00+01:00"}]
            preview = tool("preflight_change", {"action": "create", "scope": "this", "calendar_id": calendar,
                "fields": {"title": "Synthetic multi-alert fixture", "start": "2026-10-25T10:00:00Z",
                           "end": "2026-10-25T11:00:00Z", "alerts": initial}})["preview"]
            self.assertEqual(preview["envelope"]["version"], 2)
            self.assertIn({"at": "2026-10-25T09:45:00.000Z"}, preview["envelope"]["after"]["alerts"])
            altered = deepcopy(preview)
            altered["envelope"]["after"]["alerts"] = []
            tool("commit_create", {"preview": altered}, error=True)
            created = tool("commit_create", {"preview": preview})
            self.assertEqual(tool("commit_create", {"preview": preview}), created)
            event = created["event"]
            event_id = event["id"]
            self.assertNotIn("alerts", event["fields"])
            self.assertEqual(len(event["details"]["alarms"]), 2)
            def modify(fields):
                draft = tool("preflight_change", {"action": "modify", "scope": "this", "event_id": event_id, "fields": fields})["preview"]
                return tool("commit_modify", {"preview": draft})
            preserved = modify({"notes": "Preserve complete native alarms"})["event"]
            self.assertEqual(preserved["details"]["alarms"], event["details"]["alarms"])
            for replacement in (initial + [{"relative_minutes": 5}],
                                [{"relative_minutes": -60}, initial[1], {"relative_minutes": 5}],
                                [{"relative_minutes": -60}]):
                event = modify({"alerts": replacement})["event"]
                self.assertEqual(len(event["details"]["alarms"]), len(replacement))
            retained = event["details"]["alarms"]
            cleared = modify({"alerts": []})
            self.assertEqual(cleared["event"]["details"]["alarms"], [])
            stored = tool("get_stored_change", {"change_id": cleared["nonce"]})
            self.assertEqual(stored["before"]["details"]["alarms"], retained)
            plan = tool("preflight_rollback", {"change_ids": [cleared["nonce"]]})
            rollback = plan["steps"][0]["preview"]
            self.assertEqual(rollback["envelope"]["rollback"]["alarm_restoration"], retained)
            restored = tool("commit_rollback", {"preview": rollback})
            self.assertEqual(restored["event"]["details"]["alarms"], retained)
            deletion = tool("preflight_change", {"action": "delete", "scope": "this", "event_id": event_id})["preview"]
            deleted = tool("commit_delete", {"preview": deletion})
            plan = tool("preflight_rollback", {"change_ids": [deleted["nonce"]]})
            recreated = tool("commit_rollback", {"preview": plan["steps"][0]["preview"]})
            self.assertEqual(recreated["event"]["details"]["alarms"], retained)


if __name__ == "__main__":
    unittest.main()
