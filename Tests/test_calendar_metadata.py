# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Calendar wording contracts: no provider, process, socket or state access."""
from copy import deepcopy
import hashlib
import itertools
import json
from pathlib import Path
import unittest

from calendar_mcp.native import (ALERTS_CAPABILITIES, RECOVERY_CAPABILITIES,
    RECURRENCE_CAPABILITIES, SERIES_MODIFICATION_CAPABILITIES,
    FUTURE_MODIFICATION_CAPABILITIES, FUTURE_TERMINATION_CAPABILITIES,
    ALL_DAY_DATES_CAPABILITIES, RECONCILIATION_CAPABILITIES, REMINDERS_CAPABILITIES)
from calendar_mcp.protocol import BASE_INSTRUCTIONS, Protocol, REMINDER_INSTRUCTIONS, VERSIONS
from calendar_mcp.reminders_schema import REMINDER_TOOLS
from calendar_mcp.schema import tools_for_capabilities

BASELINE = json.loads((Path(__file__).parent / "fixtures/calendar_metadata_contracts.json").read_text())
FLAGS = BASELINE["flags"]


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(",", ":")).encode()).hexdigest()


def initialize(protocol):
    return protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": VERSIONS[-1], "capabilities": {}, "clientInfo": {}}})["result"]


class MetadataBroker:
    """Only metadata capabilities exist; item dispatch would fail the test."""
    def __init__(self, floor, **flags):
        self.floor, self.flags = floor, flags
    def recovery_capabilities(self):
        return None if self.floor is None else {**RECOVERY_CAPABILITIES, "storage_version": self.floor}
    def capability(self, flag, value):
        return deepcopy(value) if self.flags.get(flag, False) else None
    def alerts_capabilities(self): return self.capability("alerts", ALERTS_CAPABILITIES)
    def recurrence_capabilities(self): return self.capability("recurrence", RECURRENCE_CAPABILITIES)
    def series_modification_capabilities(self): return self.capability("series_modification", SERIES_MODIFICATION_CAPABILITIES)
    def future_modification_capabilities(self): return self.capability("future_modification", FUTURE_MODIFICATION_CAPABILITIES)
    def future_termination_capabilities(self): return self.capability("future_termination", FUTURE_TERMINATION_CAPABILITIES)
    def all_day_dates_capabilities(self): return self.capability("all_day_dates", ALL_DAY_DATES_CAPABILITIES)
    def reconciliation_capabilities(self): return self.capability("reconciliation", RECONCILIATION_CAPABILITIES)
    def call(self, *_): raise AssertionError("Metadata must not dispatch a provider operation")


class CalendarMetadataTests(unittest.TestCase):
    def test_all_128_catalog_contracts_preserve_recursive_schema_annotations_names_and_order(self):
        for bits in itertools.product((False, True), repeat=len(FLAGS)):
            key = "".join(str(int(value)) for value in bits)
            with self.subTest(capabilities=key):
                tools = tools_for_capabilities(**dict(zip(FLAGS, bits)))
                # Strip only the TOP-LEVEL description; every nested schema description,
                # signed limitation, annotation and list ordering remains in the digest.
                contract = [{name: value for name, value in tool.items() if name != "description"}
                            for tool in tools]
                self.assertEqual(digest(contract), BASELINE["contracts"][key])

    def test_actual_protocol_floor_and_feature_matrix_never_advertises_unavailable_routes(self):
        for floor in (None, 2, 3, 4, 5, 6, 7, 8, True, 6.0):
            for bits in itertools.product((False, True), repeat=len(FLAGS)):
                flags = dict(zip(FLAGS, bits))
                with self.subTest(floor=floor, capabilities=bits):
                    protocol = Protocol(MetadataBroker(floor, **flags))
                    guidance = initialize(protocol)["instructions"]
                    recovery = type(floor) is int and 2 <= floor <= 7
                    recurrence = flags["alerts"] and flags["recurrence"]
                    series = recovery and floor >= 3 and recurrence and flags["series_modification"]
                    future = series and floor >= 4 and flags["future_modification"]
                    termination = future and floor >= 5 and flags["future_termination"]
                    civil = recovery and floor >= 6 and flags["alerts"] and flags["all_day_dates"]
                    assessment = recovery and floor >= 6 and flags["reconciliation"]
                    for available, name in ((series, "commit_series_modify"), (future, "commit_future_modify"),
                                            (termination, "commit_future_delete"), (assessment, "list_unresolved_changes"),
                                            (assessment, "preflight_reconciliation"), (assessment, "commit_reconciliation")):
                        self.assertEqual(name in protocol.tool_names, bool(available))
                        self.assertEqual(name in guidance, bool(available))
                    self.assertEqual("fields.all_day_dates" in guidance, bool(civil))
                    self.assertIn("Modify requires event_id and nonempty fields; delete requires event_id without fields", guidance)
                    if civil:
                        self.assertIn("fields.title with timestamp start/end or fields.all_day_dates", guidance)
                        self.assertNotIn("Create requires calendar_id and fields.title/start/end.", guidance)
                    else:
                        self.assertIn("Create requires calendar_id and fields.title/start/end.", guidance)
                    self.assertEqual("provider_mutation:not_entered" in guidance, bool(recovery and floor >= 7))
                    self.assertEqual("list_changes" in protocol.tool_names, recovery)
                    self.assertEqual("list_changes" in guidance, recovery)
                    self.assertNotIn("commit_reminder_", guidance)
                    if future:
                        self.assertNotIn("scope future and whole-series deletion are unsupported", guidance)
                    if civil and not termination:
                        self.assertIn("timed termination remains supported when available", guidance)
                    if not recovery:
                        self.assertIn("Retained history and rollback tools are unavailable", guidance)

    def test_first_512_characters_and_shared_guidance_preserve_execution_boundaries(self):
        for floor in (None, 2, 7):
            guidance = initialize(Protocol(MetadataBroker(floor, **dict.fromkeys(FLAGS, True))))["instructions"]
            prefix = guidance[:512]
            self.assertLessEqual(len(BASE_INSTRUCTIONS), 512)
            for text in ("untrusted", "opaque IDs", "Preflight the exact change", "entire unchanged authenticated preview",
                         "matching commit tool", "normal host policy", "not proof of a fresh click", "original nonce",
                         "never blindly retry", "Calendar-container deletion is permanently prohibited"):
                self.assertIn(text, prefix)
            for text in ("reserves no capacity", "commit rechecks policy", "cumulative protection is unconfirmed",
                         "does not authorize automatic retries", "no pending approval", "never inferred approval"):
                self.assertIn(text, guidance)
        current = initialize(Protocol(MetadataBroker(7, **dict.fromkeys(FLAGS, True))))["instructions"]
        for text in ("newest-first", "without truncation", "non-atomic", "five days", "original source change_id",
                     "reconciliation nonce is not a Calendar execution nonce", "identical authenticated assessment preview",
                     "user-assessed reconciled/not_applied are not native non-entry proof", "never infer the assessment"):
            self.assertIn(text, current)

    def test_tool_descriptions_retain_material_scope_and_recovery_limits(self):
        tools = {tool["name"]: tool["description"] for tool in tools_for_capabilities(**dict.fromkeys(FLAGS, True))}
        for name in ("commit_series_modify", "commit_series_rollback"):
            for text in ("first occurrence", "past and future", "unbounded", "split segments"):
                self.assertIn(text, tools[name])
        for name in ("commit_future_modify", "commit_future_rollback"):
            for text in ("strictly future", "unbounded"):
                self.assertIn(text, tools[name])
        for text in ("inclusive cutoff", "366 days", "detached/moved", "unbounded", "recreate past dates"):
            self.assertIn(text, tools["commit_future_delete"])
        for text in ("separate recurring series", "excluded dates", "survivors", "now-past dates", "never merges", "topology"):
            self.assertIn(text, tools["commit_future_restore"])
        for name in ("preflight_rollback", "commit_rollback"):
            self.assertIn("Recovery of a deleted recurring occurrence creates a standalone copy", tools[name])
        for name in ("commit_delete", "preflight_rollback", "commit_rollback", "commit_future_delete", "commit_future_restore"):
            self.assertIn("Fresh all-day deletion, cutoff termination and copy restoration are unsupported in every timezone", tools[name])
        for name in ("preflight_reconciliation", "commit_reconciliation"):
            self.assertIn("journal", tools[name])
            self.assertIn("retry", tools[name])
            self.assertIn("verif", tools[name])
        self.assertIn("original preview nonce", tools["get_change_status"])

    def test_civil_dates_and_assessment_are_independent_of_recurrence_and_future(self):
        flags = dict.fromkeys(FLAGS, False)
        flags.update(alerts=True, all_day_dates=True, reconciliation=True)
        protocol = Protocol(MetadataBroker(7, **flags))
        instructions = initialize(protocol)["instructions"]
        self.assertTrue(protocol.all_day_dates)
        self.assertTrue(protocol.reconciliation)
        self.assertFalse(protocol.recurrence)
        self.assertFalse(protocol.future_termination)
        self.assertIn("fields.all_day_dates", instructions)
        self.assertIn("preflight_reconciliation", instructions)
        self.assertNotIn("commit_future_restore", instructions)
        preflight = next(tool for tool in protocol.tools if tool["name"] == "preflight_change")
        self.assertIn("timed termination remains supported when available", preflight["description"])
        malformed = MetadataBroker(7, **dict.fromkeys(FLAGS, True))
        malformed.reconciliation_capabilities = lambda: {**RECONCILIATION_CAPABILITIES, "version": True}
        guarded = initialize(Protocol(malformed))["instructions"]
        self.assertIn("provider_mutation:not_entered", guarded)
        self.assertIn("Remote journal assessment tools are unavailable", guarded)
        for name in ("list_unresolved_changes", "preflight_reconciliation", "commit_reconciliation"):
            self.assertNotIn(name, guarded)

    def test_complete_reminders_catalog_and_initialization_instructions_are_exactly_unchanged(self):
        class RemindersOnly:
            reminders_enabled = True
            def reminders_capabilities(self): return deepcopy(REMINDERS_CAPABILITIES)
            def __getattr__(self, _): raise AssertionError("Reminders must not probe Calendar")
        protocol = Protocol(RemindersOnly(), resource="reminders")
        self.assertEqual(protocol.tools, REMINDER_TOOLS)
        self.assertEqual(len(protocol.tools), 17)
        self.assertEqual(digest(protocol.tools), BASELINE["reminder_tools"])
        self.assertEqual(initialize(protocol)["instructions"], REMINDER_INSTRUCTIONS)
        self.assertEqual(digest(initialize(protocol)["instructions"]), BASELINE["reminder_instructions"])


if __name__ == "__main__":
    unittest.main()
