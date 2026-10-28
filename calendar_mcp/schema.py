# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Auditable JSON Schema subset, shared by tool publication and validation."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .json_values import validate_json


def obj(properties, required=()):
    return {"type": "object", "properties": properties, "required": list(required),
            "additionalProperties": False}


def string(limit=1000, **extra):
    return {"type": "string", "maxLength": limit, **extra}


IDENTITY = string(200, minLength=1)
STAMP = string(64, format="date-time")
ZONE = {"type": ["string", "null"], "maxLength": 100, "format": "time-zone"}
FIELDS = obj({"title": string(1000, minLength=1), "start": STAMP, "end": STAMP,
              "time_zone": ZONE, "all_day": {"type": "boolean"},
              "location": string(2000), "notes": string(10000)})
FULL_FIELDS = {**FIELDS, "required": list(FIELDS["properties"])}
REVIEW_FIELDS = {**FULL_FIELDS, "properties": {**FULL_FIELDS["properties"],
                 "time_zone": {"type": ["string", "null"], "maxLength": 100}}}
SNAPSHOT_FIELDS = {**REVIEW_FIELDS, "properties": {**REVIEW_FIELDS["properties"],
                   "title": string(262144), "location": string(262144), "notes": string(262144)}}
CALENDAR = obj({"id": IDENTITY, "title": string(262144), "source": string(262144),
                "writable": {"type": "boolean"}, "subscribed": {"type": "boolean"}},
               ("id", "title", "source", "writable", "subscribed"))
EVENT = obj({"id": IDENTITY, "calendar": CALENDAR,
             "occurrence": {"type": ["string", "null"], "maxLength": 64},
             "fields": SNAPSHOT_FIELDS, "recurring": {"type": "boolean"},
             "detached": {"type": "boolean"}, "availability": string(40),
             "status": string(40), "has_attendees": {"type": "boolean"},
             "has_organizer": {"type": "boolean"}, "fingerprint": string(256),
             "details": {"type": "object", "properties": {}, "required": [], "additionalProperties": True}},
            ("id", "calendar", "occurrence", "fields", "recurring", "detached",
             "availability", "status", "has_attendees", "has_organizer", "fingerprint", "details"))
ENVELOPE = obj({"version": {"type": "integer", "enum": [1]}, "nonce": IDENTITY,
                "issued_at": STAMP, "expires_at": STAMP, "installation_id": IDENTITY,
                "credential_generation": IDENTITY, "key_id": IDENTITY,
                "action": string(enum=["create", "modify", "delete"]),
                "scope": string(enum=["this"]), "calendar": CALENDAR,
                "before": {**EVENT, "type": ["object", "null"]},
                "after": {**REVIEW_FIELDS, "type": ["object", "null"]}},
               ("version", "nonce", "issued_at", "expires_at", "installation_id",
                "credential_generation", "key_id", "action", "scope", "calendar", "before", "after"))
PREVIEW = obj({"envelope": ENVELOPE, "authentication_tag": string(256, minLength=1)},
              ("envelope", "authentication_tag"))
RANGE = obj({"start": STAMP, "end": STAMP,
             "calendar_ids": {"type": "array", "items": IDENTITY, "minItems": 1, "maxItems": 100},
             "time_zone": string(100, format="time-zone")}, ("start", "end"))
CHANGE_FILTERS = {"since": STAMP, "until": STAMP,
                  "action": string(enum=["modify", "delete"]), "event_id": IDENTITY}
CHANGE_IDS = {"type": "array", "items": IDENTITY, "minItems": 1, "maxItems": 25,
              "uniqueItems": True}
ROLLBACK_RESTORATION = obj({"details": {"type": "object", "properties": {}, "required": [],
                                       "additionalProperties": True},
                            "availability": string(40)}, ("details", "availability"))
ROLLBACK = obj({"selection_id": IDENTITY, "source_change_ids": CHANGE_IDS,
                "source_digest": string(64, minLength=64),
                "restoration": {**ROLLBACK_RESTORATION, "type": ["object", "null"]},
                "limitations": {"type": "array", "items": string(2000), "maxItems": 20}},
               ("selection_id", "source_change_ids", "source_digest", "restoration", "limitations"))
ROLLBACK_ENVELOPE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
                     "action": string(enum=["create", "modify"]),
                     "after": FULL_FIELDS, "rollback": ROLLBACK},
                     "required": [*ENVELOPE["required"], "rollback"]}
ROLLBACK_PREVIEW = obj({"envelope": ROLLBACK_ENVELOPE,
                        "authentication_tag": string(256, minLength=1)},
                       ("envelope", "authentication_tag"))

ALERT = {"oneOf": [obj({"relative_minutes": {"type": "integer", "minimum": -525600,
                                            "maximum": 525600}}, ("relative_minutes",)),
                   obj({"at": STAMP}, ("at",))]}
ALERTS = {"type": "array", "items": ALERT, "maxItems": 10,
          "description": "Complete replacement list of display alerts. Negative relative_minutes is before start; positive is after start; zero is at start. Relative minutes are elapsed time, including all-day events and DST. at is an absolute timestamp. [] clears all alerts; omission preserves existing alerts on modify and defaults to [] on create."}
ALERT_FIELDS = {**FIELDS, "properties": {**FIELDS["properties"], "alerts": ALERTS}}
ALERT_REVIEW_FIELDS = {**REVIEW_FIELDS, "properties": {**REVIEW_FIELDS["properties"], "alerts": ALERTS}}
ALERT_ENVELOPE_BASE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
                  "version": {"type": "integer", "enum": [2]},
                  "after": {**ALERT_REVIEW_FIELDS, "type": ["object", "null"]}}}
ALERT_ENVELOPE = {"oneOf": [
    {**ALERT_ENVELOPE_BASE, "properties": {**ALERT_ENVELOPE_BASE["properties"],
     "action": string(enum=["create"]),
     "after": {**ALERT_REVIEW_FIELDS, "required": [*ALERT_REVIEW_FIELDS["required"], "alerts"]}}},
    {**ALERT_ENVELOPE_BASE, "properties": {**ALERT_ENVELOPE_BASE["properties"],
     "action": string(enum=["modify", "delete"])}}]}
ALERT_PREVIEW = obj({"envelope": ALERT_ENVELOPE, "authentication_tag": string(256, minLength=1)},
                    ("envelope", "authentication_tag"))
RAW_ALARMS = {"type": "array", "maxItems": 10000,
              "items": {"type": "object", "properties": {}, "required": [], "additionalProperties": True}}
ALERT_ROLLBACK = {**ROLLBACK, "properties": {**ROLLBACK["properties"], "alarm_restoration": RAW_ALARMS},
                  "required": [*ROLLBACK["required"], "alarm_restoration"]}
ALERT_ROLLBACK_ENVELOPE = {**ROLLBACK_ENVELOPE,
    "properties": {**ROLLBACK_ENVELOPE["properties"], "version": {"type": "integer", "enum": [2]},
                   "after": REVIEW_FIELDS, "rollback": ALERT_ROLLBACK}}
ALERT_ROLLBACK_PREVIEW = obj({"envelope": ALERT_ROLLBACK_ENVELOPE,
                             "authentication_tag": string(256, minLength=1)},
                            ("envelope", "authentication_tag"))

RECURRENCE_END = {"oneOf": [obj({"count": {"type": "integer", "minimum": 1, "maximum": 1000}}, ("count",)),
                             obj({"until": STAMP}, ("until",)), {"type": "null"}]}
RECURRENCE = obj({"frequency": string(enum=["daily", "weekly", "monthly", "yearly"]),
                  "interval": {"type": "integer", "minimum": 1, "maximum": 999},
                  "end": RECURRENCE_END,
                  "days_of_week": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": 7},
                                   "minItems": 1, "maxItems": 7, "uniqueItems": True,
                                   "description": "Weekly only. 1 is Sunday and 7 is Saturday."}}, ("frequency",))
RECURRENCE["description"] = "Recurring creation only, with scope series. interval defaults to 1; omitted or null end is unbounded. Weekly intervals use Monday week boundaries; monthly/yearly rules skip invalid anchor dates."
CANONICAL_RECURRENCE = {**RECURRENCE, "required": ["frequency", "interval", "end"]}
OCCURRENCE_RECOVERY_LIMITATION = "Restores the displayed fields while preserving the current occurrence and series structure. Historical detachment and series membership are not restored."
COPY_RECOVERY_LIMITATION = "Restoration creates a new provider event. Provider IDs, creation/modification timestamps and read-only status are not restored."
RECURRING_DELETE_LIMITATION = "Recovery recreates only this occurrence as a standalone event with new provider identity. It does not remove the series exclusion, reattach the occurrence, restore series membership, or make future series edits apply to the copy."
RECOVERY_DISCLOSURE = obj({"mode": string(enum=["not_applicable", "occurrence_fields", "standalone_copy"]),
                           "limitations": {"type": "array", "maxItems": 2, "uniqueItems": True,
                                           "items": string(2000, enum=[OCCURRENCE_RECOVERY_LIMITATION,
                                                                      COPY_RECOVERY_LIMITATION,
                                                                      RECURRING_DELETE_LIMITATION])}},
                          ("mode", "limitations"))
RECURRENCE_FIELDS = {**ALERT_FIELDS, "properties": {**ALERT_FIELDS["properties"], "recurrence": RECURRENCE}}
RECURRENCE_REVIEW_FIELDS = {**ALERT_REVIEW_FIELDS,
    "properties": {**ALERT_REVIEW_FIELDS["properties"], "recurrence": CANONICAL_RECURRENCE}}
RECURRENCE_ENVELOPE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
    "version": {"type": "integer", "enum": [3]}, "scope": string(enum=["this", "series"]),
    "after": {**RECURRENCE_REVIEW_FIELDS, "type": ["object", "null"]},
    "recovery": RECOVERY_DISCLOSURE}, "required": [*ENVELOPE["required"], "recovery"]}
RECURRENCE_PREVIEW = obj({"envelope": RECURRENCE_ENVELOPE,
                          "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))

SERIES_FIELD_NAMES = ("title", "notes", "location", "alerts")
SERIES_REFERENCE = obj({"provider_scope": string(enum=["current_pattern_from_first_occurrence"]),
                        "selected": EVENT,
                        "changed_fields": {"type": "array", "minItems": 1, "maxItems": 4,
                                           "uniqueItems": True, "items": string(enum=list(SERIES_FIELD_NAMES))}},
                       ("provider_scope", "selected", "changed_fields"))
SERIES_LIMITATIONS = [
    "Applies changed default fields to the provider's current recurring pattern from its first occurrence, including past and future occurrences in that pattern. Separate series segments are not merged.",
    "Detached occurrence overrides and exclusions are controlled by the provider. This operation does not verify every occurrence or guarantee that every detached override receives the same values.",
    "Recovery reapplies only the retained prior default fields to the same current pattern. It does not reconstruct detached overrides, exclusions, prior series structure, provider identities or earlier split segments.",
    "One series operation can affect an unbounded number of occurrences and consumes one modify intent under the installation-wide safety limits."]
SERIES_LIMITATION_SCHEMA = {"type": "array", "minItems": 4, "maxItems": 4, "uniqueItems": True,
                            "items": string(2000, enum=SERIES_LIMITATIONS)}
SERIES_RECOVERY = obj({"mode": string(enum=["series_default_fields"]),
                       "limitations": SERIES_LIMITATION_SCHEMA}, ("mode", "limitations"))
SERIES_AFTER = {**SNAPSHOT_FIELDS, "properties": {**SNAPSHOT_FIELDS["properties"], "alerts": ALERTS}}
SERIES_ENVELOPE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
    "version": {"type": "integer", "enum": [4]}, "action": string(enum=["modify"]),
    "scope": string(enum=["series"]), "before": EVENT, "after": SERIES_AFTER,
    "series": SERIES_REFERENCE, "recovery": SERIES_RECOVERY},
    "required": [*ENVELOPE["required"], "series", "recovery"]}
SERIES_PREVIEW = obj({"envelope": SERIES_ENVELOPE, "authentication_tag": string(256, minLength=1)},
                     ("envelope", "authentication_tag"))
SERIES_ROLLBACK = {**ROLLBACK, "properties": {**ROLLBACK["properties"],
    "source_change_ids": {**CHANGE_IDS, "maxItems": 1}, "restoration": {"type": "null"},
    "alarm_restoration": {**RAW_ALARMS, "type": ["array", "null"]}, "limitations": SERIES_LIMITATION_SCHEMA},
    "required": [*ROLLBACK["required"], "alarm_restoration"]}
SERIES_ROLLBACK_ENVELOPE = {**SERIES_ENVELOPE, "properties": {**SERIES_ENVELOPE["properties"],
    "after": SNAPSHOT_FIELDS, "rollback": SERIES_ROLLBACK},
    "required": [*SERIES_ENVELOPE["required"], "rollback"]}
SERIES_ROLLBACK_PREVIEW = obj({"envelope": SERIES_ROLLBACK_ENVELOPE,
                              "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))

FUTURE_LIMITATIONS = [
    "Applies changed default fields to the selected future occurrence and later occurrences in its current provider pattern. Earlier occurrence fields and times are outside the requested change; earlier split segments are not merged.",
    "EventKit may split the pattern and change provider identities and recurrence end metadata. Detached overrides and exclusions remain provider-controlled. The operation does not enumerate or verify every occurrence or guarantee propagation to detached overrides.",
    "Recovery reapplies only retained prior default fields to the same verified future segment while its original boundary is still in the future. It does not merge split segments or reconstruct recurrence topology, detached overrides, exclusions or provider identities; recovery may become unavailable before retained details expire.",
    "One future operation can affect an unbounded number of occurrences and consumes one modify intent under the installation-wide safety limits."]
FUTURE_LIMITATION_SCHEMA = {"type": "array", "minItems": 4, "maxItems": 4, "uniqueItems": True,
                            "items": string(2000, enum=FUTURE_LIMITATIONS)}
FUTURE_REFERENCE = obj({"provider_scope": string(enum=["selected_occurrence_and_future"]),
                        "boundary": STAMP, "first_anchor": EVENT,
                        "changed_fields": deepcopy(SERIES_REFERENCE["properties"]["changed_fields"])},
                       ("provider_scope", "boundary", "first_anchor", "changed_fields"))
FUTURE_RECOVERY = obj({"mode": string(enum=["future_default_fields"]),
                       "limitations": FUTURE_LIMITATION_SCHEMA}, ("mode", "limitations"))
FUTURE_ENVELOPE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
    "version": {"type": "integer", "enum": [5]}, "action": string(enum=["modify"]),
    "scope": string(enum=["future"]), "before": EVENT, "after": SERIES_AFTER,
    "future": FUTURE_REFERENCE, "recovery": FUTURE_RECOVERY},
    "required": [*ENVELOPE["required"], "future", "recovery"]}
FUTURE_PREVIEW = obj({"envelope": FUTURE_ENVELOPE, "authentication_tag": string(256, minLength=1)},
                     ("envelope", "authentication_tag"))
FUTURE_ROLLBACK = {**SERIES_ROLLBACK, "properties": {**SERIES_ROLLBACK["properties"],
    "limitations": FUTURE_LIMITATION_SCHEMA}}
FUTURE_ROLLBACK_ENVELOPE = {**FUTURE_ENVELOPE, "properties": {**FUTURE_ENVELOPE["properties"],
    "after": SNAPSHOT_FIELDS, "rollback": FUTURE_ROLLBACK},
    "required": [*FUTURE_ENVELOPE["required"], "rollback"]}
FUTURE_ROLLBACK_PREVIEW = obj({"envelope": FUTURE_ROLLBACK_ENVELOPE,
                              "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))

FUTURE_CUTOFF = {"oneOf": [
    obj({"date": string(10, minLength=10, format="date"),
         "time_zone": string(100, format="time-zone")}, ("date", "time_zone")),
    obj({"at": STAMP}, ("at",))]}
FUTURE_TERMINATION_LIMITATIONS = [
    "Stops the current provider pattern from the selected future occurrence, including that occurrence and later occurrences in the pattern. Earlier occurrence fields and times are outside the deletion; other split segments and independent copies are not included.",
    "The supplied cutoff is inclusive. The signed boundary is the first eligible occurrence found at or after that cutoff in the signed bounded selection window. It must still be in the future when removal begins. Excluded dates have no default occurrence to select.",
    "EventKit controls recurrence termination, detached overrides and exclusions. Detached or moved occurrences may survive, including ones before the selected default boundary or beyond the bounded query. Those require separate identified occurrence deletion; this operation does not prove that every event after the cutoff is removed.",
    "Recovery creates a separate recurring series from the original deleted boundary with new provider identities and the retained default fields and supported rule. The original earlier segment stays truncated; the new series is not reattached or merged with it.",
    "Recovery does not restore exclusions or detached overrides. Previously skipped occurrences can reappear, and surviving moved or detached events can be duplicated by new default occurrences. Other split segments and independent copies are neither restored nor removed.",
    "Recovery may recreate occurrences from the original deleted boundary that are already in the past when recovery is approved. It requires a separate exact preview and write confirmation, retained details, unchanged verified prefix state and no conflicting later intent.",
    "One future termination can remove an unbounded number of occurrences and consumes one delete intent under the installation-wide safety limits. Recovery is a new recurring-series creation under the normal creation policy."]
FUTURE_TERMINATION_LIMITATION_SCHEMA = {"type": "array", "minItems": 7, "maxItems": 7, "uniqueItems": True,
    "items": string(2000, enum=FUTURE_TERMINATION_LIMITATIONS)}
FUTURE_TERMINATION_REFERENCE = obj({
    "provider_scope": string(enum=["selected_occurrence_and_future"]), "cutoff": FUTURE_CUTOFF,
    "resolved_cutoff": STAMP, "boundary": STAMP, "reference": EVENT, "first_anchor": EVENT,
    "selection_window": obj({"start": STAMP, "end": STAMP}, ("start", "end")),
    "removes_entire_current_pattern": {"type": "boolean"}, "copy_recurrence": CANONICAL_RECURRENCE},
    ("provider_scope", "cutoff", "resolved_cutoff", "boundary", "reference", "first_anchor",
     "selection_window", "removes_entire_current_pattern", "copy_recurrence"))
FUTURE_TERMINATION_RECOVERY = obj({"mode": string(enum=["independent_tail_copy"]),
    "limitations": FUTURE_TERMINATION_LIMITATION_SCHEMA}, ("mode", "limitations"))
FUTURE_TERMINATION_ENVELOPE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
    "version": {"type": "integer", "enum": [6]}, "action": string(enum=["delete"]),
    "scope": string(enum=["future"]), "before": EVENT, "after": {"type": "null"},
    "future": FUTURE_TERMINATION_REFERENCE, "recovery": FUTURE_TERMINATION_RECOVERY},
    "required": [*ENVELOPE["required"], "future", "recovery"]}
FUTURE_TERMINATION_PREVIEW = obj({"envelope": FUTURE_TERMINATION_ENVELOPE,
    "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))
FUTURE_RESTORE_FIELDS = {**SNAPSHOT_FIELDS,
    "properties": {**SNAPSHOT_FIELDS["properties"], "recurrence": CANONICAL_RECURRENCE},
    "required": [*SNAPSHOT_FIELDS["required"], "recurrence"]}
FUTURE_RESTORE_RESTORATION = obj({**ROLLBACK_RESTORATION["properties"],
    "past_anchor": {**EVENT, "type": ["object", "null"]}}, ("details", "availability", "past_anchor"))
FUTURE_RESTORE_ROLLBACK = {**ROLLBACK, "properties": {**ROLLBACK["properties"],
    "source_change_ids": {**CHANGE_IDS, "maxItems": 1}, "restoration": FUTURE_RESTORE_RESTORATION,
    "limitations": FUTURE_TERMINATION_LIMITATION_SCHEMA}}
FUTURE_RESTORE_ENVELOPE = {**FUTURE_TERMINATION_ENVELOPE,
    "properties": {**FUTURE_TERMINATION_ENVELOPE["properties"],
        "action": string(enum=["create"]), "before": {"type": "null"}, "after": FUTURE_RESTORE_FIELDS,
        "rollback": FUTURE_RESTORE_ROLLBACK},
    "required": [*FUTURE_TERMINATION_ENVELOPE["required"], "rollback"]}
FUTURE_RESTORE_PREVIEW = obj({"envelope": FUTURE_RESTORE_ENVELOPE,
    "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))


def tool(name, description, schema, *, write=False, destructive=False):
    return {"name": name, "description": description, "inputSchema": schema,
            "annotations": {"readOnlyHint": not write, "destructiveHint": destructive,
                            "idempotentHint": not name.startswith("preflight_"), "openWorldHint": False}}


# Descriptions explain actions and material limits; shared execution guidance is
# assembled from verified capabilities in the Calendar initialization instructions.
PREFLIGHT_THIS_DESCRIPTION = (
    "Preview an event creation, modification or deletion with scope this. Create uses calendar_id; "
    "modify/delete use one event_id. Invitations and organizer changes are unsupported. No Calendar change is made.")
ALERTS_DESCRIPTION = " Alerts replace the complete list of at most ten display alerts; omission on modify preserves alarms and [] clears them."
RECURRENCE_DESCRIPTION = (
    " Recurring creation uses scope series and a supported rule. Occurrence edits preserve current structure; "
    "a recurring occurrence deletion recovers only as a new standalone copy, leaving the series exclusion and membership unchanged.")
SERIES_DESCRIPTION = (
    " Modify title, notes, plain location or alerts defaults with scope series from the current pattern's first occurrence, "
    "including past and future instances. It may affect unbounded occurrences; detached overrides/exclusions are provider-controlled, "
    "and earlier split segments are not merged.")
FUTURE_DESCRIPTION = (
    " Scope future modifies those defaults from the exact selected non-detached occurrence, inclusively, only while its start is "
    "strictly future. One unbounded/date-ended rule is supported; count-ended patterns are not. Provider splitting/identity changes "
    "and time-limited inverse recovery can occur; earlier fields/times are outside the change.")
TERMINATION_DESCRIPTION = (
    " Delete/future uses an inclusive date with IANA timezone or offset instant cutoff. Native selection chooses the first eligible "
    "default occurrence in a bounded 366-day window; the boundary must remain future. Known detached/moved boundary candidates need "
    "separate handling; other segments/copies and detached survivors are outside the deletion. It may remove unbounded occurrences. "
    "Recovery creates a separate series that may regenerate exclusions, duplicate survivors and recreate past dates, without merging topology.")
PATTERN_LIMITS_DESCRIPTION = " User-directed structural series edits and arbitrary full-series deletion are unsupported."

TOOLS = [
    tool("list_calendars", "List configured macOS calendars and their write eligibility.", obj({})),
    tool("query_events", "Read events in a maximum 93-day window; narrow the range when results are truncated.", RANGE),
    tool("get_event", "Read one event or occurrence by an opaque ID returned by a query.", obj({"event_id": IDENTITY}, ("event_id",))),
    tool("get_availability", "Read free/busy windows; a snapshot, never a reservation. Defaults to Europe/London.", RANGE),
    tool("preflight_change", PREFLIGHT_THIS_DESCRIPTION,
         obj({"action": string(enum=["create", "modify", "delete"]), "scope": string(enum=["this"]),
              "calendar_id": IDENTITY, "event_id": IDENTITY, "fields": FIELDS}, ("action", "scope"))),
    *[tool("commit_" + action, {"create": "Create the event described by the preview; invitation and organizer changes are unsupported.",
            "modify": "Change the shown fields of one identified event or occurrence while preserving its current occurrence/series structure.",
            "delete": "Delete one identified event; calendar containers cannot be deleted."}[action],
           obj({"preview": PREVIEW}, ("preview",)), write=True, destructive=action != "create")
      for action in ("create", "modify", "delete")],
    tool("get_change_status", "Read this integration's durable execution outcome by the original preview nonce. No Calendar access, provider verification, retry or recovery occurs.", obj({"nonce": IDENTITY}, ("nonce",))),
    tool("list_changes", "Browse this integration's retained modify/delete journal, with optional expired metadata and cursor pagination. It is not a history of other Calendar clients. No Calendar access or automatic recovery occurs.",
         obj({**CHANGE_FILTERS, "include_expired": {"type": "boolean"},
              "limit": {"type": "integer", "minimum": 1, "maximum": 100},
              "cursor": string(4096, minLength=1)})),
    tool("get_stored_change", "Read one integration change's retained before/proposed/observed snapshots and provisional recovery eligibility. Expired details cannot be restored. No Calendar access, provider verification, retry or reconciliation occurs.",
         obj({"change_id": IDENTITY}, ("change_id",))),
    tool("preflight_rollback", "Prepare recovery for up to 25 verified applied retained sources, or all matching sources within that limit; oversized selections fail without truncation. Related edits are grouped into separate, non-atomic steps. Copies have new identities; recovery cannot reconstruct provider provenance.",
         obj({"change_ids": CHANGE_IDS, "all": {"type": "boolean"}, **CHANGE_FILTERS})),
    tool("commit_rollback", "Apply one retained recovery step as a new event creation or modification. Multiple steps are not atomic; copies have new provider identities and cannot restore original provider provenance.",
         obj({"preview": ROLLBACK_PREVIEW}, ("preview",)), write=True, destructive=True),
]
TOOL_MAP = {t["name"]: t for t in TOOLS}
RECOVERY_TOOLS = frozenset(("list_changes", "get_stored_change", "preflight_rollback", "commit_rollback"))
LEGACY_TOOLS = deepcopy(TOOLS)
LEGACY_TOOL_MAP = {t["name"]: t for t in LEGACY_TOOLS}
for _tool in TOOLS:
    if _tool["name"] == "preflight_change":
        _tool["inputSchema"]["properties"]["fields"] = ALERT_FIELDS
        _tool["description"] += ALERTS_DESCRIPTION
    elif _tool["name"].startswith("commit_"):
        _tool["inputSchema"]["properties"]["preview"] = {"oneOf": [
            ROLLBACK_PREVIEW, ALERT_ROLLBACK_PREVIEW] if _tool["name"] == "commit_rollback" else [PREVIEW, ALERT_PREVIEW]}


RECURRENCE_TOOLS = deepcopy(TOOLS)
for _tool in RECURRENCE_TOOLS:
    if _tool["name"] == "preflight_change":
        _tool["inputSchema"]["properties"]["fields"] = RECURRENCE_FIELDS
        _tool["inputSchema"]["properties"]["scope"] = string(enum=["this", "series"])
        _tool["description"] = PREFLIGHT_THIS_DESCRIPTION + ALERTS_DESCRIPTION + RECURRENCE_DESCRIPTION + PATTERN_LIMITS_DESCRIPTION
    elif _tool["name"] in ("preflight_rollback", "commit_rollback"):
        _tool["description"] += " Recovery of a deleted recurring occurrence creates a standalone copy; it does not undo exclusions, reattach the copy or make future series edits apply to it."
    elif _tool["name"] in ("commit_create", "commit_modify", "commit_delete"):
        _tool["inputSchema"]["properties"]["preview"]["oneOf"].append(RECURRENCE_PREVIEW)
        _tool["description"] = {
            "commit_create": "Create one event or a recurring series with its supported rule; invitation and organizer changes are unsupported.",
            "commit_modify": "Change the shown fields of one identified event or occurrence, preserving its current occurrence and series structure.",
            "commit_delete": "Delete one identified event or occurrence. Recurring occurrence recovery creates a new standalone copy, leaves the series exclusion intact and does not reattach it or inherit future series edits."
        }[_tool["name"]]


SERIES_MODIFICATION_TOOLS = deepcopy(RECURRENCE_TOOLS)
for _tool in SERIES_MODIFICATION_TOOLS:
    if _tool["name"] == "preflight_change":
        _tool["description"] = PREFLIGHT_THIS_DESCRIPTION + ALERTS_DESCRIPTION + RECURRENCE_DESCRIPTION + SERIES_DESCRIPTION + PATTERN_LIMITS_DESCRIPTION
    elif _tool["name"] == "preflight_rollback":
        _tool["description"] += " A current-pattern change requires one original source selected alone; inverse fields include past and future instances without rebuilding topology."
SERIES_MODIFICATION_TOOLS.extend([
    tool("commit_series_modify", "Change only title, notes, plain location or alerts defaults from the provider's current pattern first occurrence, including past and future instances. One modify intent may affect unbounded occurrences. Detached overrides/exclusions remain provider-controlled; earlier split segments are not merged. Structural series edits are unsupported.",
         obj({"preview": SERIES_PREVIEW}, ("preview",)), write=True, destructive=True),
    tool("commit_series_rollback", "Restore one original applied retained series change's masked prior defaults to the same current pattern from its first occurrence, including past and future instances. It may affect unbounded occurrences; recovery does not merge split segments or reconstruct recurrence topology, detached overrides, exclusions or provider identities.",
         obj({"preview": SERIES_ROLLBACK_PREVIEW}, ("preview",)), write=True, destructive=True)])


FUTURE_MODIFICATION_TOOLS = deepcopy(SERIES_MODIFICATION_TOOLS)
for _tool in FUTURE_MODIFICATION_TOOLS:
    if _tool["name"] == "preflight_change":
        _tool["inputSchema"]["properties"]["scope"] = string(enum=["this", "series", "future"])
        _tool["description"] = PREFLIGHT_THIS_DESCRIPTION + ALERTS_DESCRIPTION + RECURRENCE_DESCRIPTION + SERIES_DESCRIPTION + FUTURE_DESCRIPTION + PATTERN_LIMITS_DESCRIPTION
    elif _tool["name"] == "preflight_rollback":
        _tool["description"] += " A future-default change requires one original source alone and its exact boundary still strictly future; inverse fields never merge segments."
FUTURE_MODIFICATION_TOOLS.extend([
    tool("commit_future_modify", 'Change only title, notes, plain location or alerts defaults from the exact selected non-detached occurrence, inclusively, while its start remains strictly future. It may affect unbounded later instances in that current pattern. Earlier fields/times are outside the change; provider splitting and identity changes may occur, and detached overrides/exclusions remain provider-controlled. Structural series edits are unsupported.',
         obj({"preview": FUTURE_PREVIEW}, ("preview",)), write=True, destructive=True),
    tool("commit_future_rollback", "Restore one original future change's masked prior defaults to the same verified segment, including its original boundary only while that boundary remains strictly future. It may affect unbounded occurrences. Recovery can become unavailable before details expire and never merges segments or reconstructs topology, overrides, exclusions or provider identities.",
         obj({"preview": FUTURE_ROLLBACK_PREVIEW}, ("preview",)), write=True, destructive=True)])


FUTURE_TERMINATION_TOOLS = deepcopy(FUTURE_MODIFICATION_TOOLS)
for _tool in FUTURE_TERMINATION_TOOLS:
    if _tool["name"] == "preflight_change":
        _tool["inputSchema"]["properties"]["cutoff"] = FUTURE_CUTOFF
        _tool["description"] = PREFLIGHT_THIS_DESCRIPTION + ALERTS_DESCRIPTION + RECURRENCE_DESCRIPTION + SERIES_DESCRIPTION + FUTURE_DESCRIPTION + TERMINATION_DESCRIPTION + PATTERN_LIMITS_DESCRIPTION
    elif _tool["name"] == "preflight_rollback":
        _tool["description"] += " One original termination alone can recover as a separate new recurring series: exclusions can regenerate, survivors duplicate and past dates reappear; no prefix merge or topology restoration."
FUTURE_TERMINATION_TOOLS.extend([
    tool("commit_future_delete", 'Stop the current pattern from the first eligible default occurrence at or after the inclusive cutoff, while the resolved boundary remains strictly future. Selection is bounded to 366 days; one delete intent may remove unbounded occurrences. Earlier fields/times, other segments and independent copies are outside the deletion; detached/moved events may survive. Separate new-series recovery can regenerate exclusions, duplicate survivors and recreate past dates without restoring topology.',
         obj({"preview": FUTURE_TERMINATION_PREVIEW}, ("preview",)), write=True, destructive=True),
    tool("commit_future_restore", "Create a separate recurring series from one retained termination's original boundary, defaults, supported rule and metadata. New provider identities and unbounded occurrences may result; excluded dates can reappear, survivors can duplicate and now-past dates can be recreated. It never merges the truncated prefix or restores exclusion/override topology. Retained applied source, unchanged verified prefix/absence and no conflicting later intent are required.",
         obj({"preview": FUTURE_RESTORE_PREVIEW}, ("preview",)), write=True)])



ALL_DAY_INTERVAL = obj({"start_date": string(10, minLength=10, format="date"),
                        "end_date_exclusive": string(10, minLength=10, format="date")},
                       ("start_date", "end_date_exclusive"))
ALL_DAY_LIMITATION = "Recovery restores the retained civil-date interval and supported fields. EventKit may return an exclusive-midnight or inclusive-last-second end representation; the original raw endpoint representation is not guaranteed."
ALL_DAY_READBACK_ENDS = ["exclusive_midnight", "inclusive_last_second"]
ALL_DAY_CONTRACT = obj({"version": {"type": "integer", "enum": [1]},
    "semantics": string(enum=["floating_civil_dates"]), "projection_time_zone": string(100, minLength=1),
    "before": {**ALL_DAY_INTERVAL, "type": ["object", "null"]}, "after": ALL_DAY_INTERVAL,
    "write_end": string(enum=["inclusive_last_second"]),
    "readback_ends": {"type": "array", "minItems": 2, "maxItems": 2, "uniqueItems": True,
                      "items": string(enum=ALL_DAY_READBACK_ENDS)}},
    ("version", "semantics", "projection_time_zone", "before", "after", "write_end", "readback_ends"))
ALL_DAY_AFTER = {**SERIES_AFTER, "properties": {**SERIES_AFTER["properties"],
                 "time_zone": {"type": "null"}, "all_day": {"type": "boolean", "enum": [True]}}}
ALL_DAY_ENVELOPE = {**ENVELOPE, "properties": {**ENVELOPE["properties"],
    "version": {"type": "integer", "enum": [7]}, "scope": string(enum=["this"]),
    "action": string(enum=["modify"]), "before": EVENT, "after": ALL_DAY_AFTER,
    "all_day": ALL_DAY_CONTRACT,
    "recovery": obj({"mode": string(enum=["all_day_fields"]),
        "limitations": {"type": "array", "minItems": 1, "maxItems": 1, "items": string(enum=[ALL_DAY_LIMITATION])}},
        ("mode", "limitations"))}, "required": [*ENVELOPE["required"], "all_day", "recovery"]}
ALL_DAY_CREATE_ENVELOPE = {**ALL_DAY_ENVELOPE, "properties": {**ALL_DAY_ENVELOPE["properties"],
    "action": string(enum=["create"]), "before": {"type": "null"},
    "after": {**ALL_DAY_AFTER, "required": [*ALL_DAY_AFTER["required"], "alerts"]},
    "recovery": obj({"mode": string(enum=["not_applicable"]),
        "limitations": {"type": "array", "maxItems": 0, "items": string()}}, ("mode", "limitations"))}}
ALL_DAY_ROLLBACK = {**ALERT_ROLLBACK, "properties": {**ALERT_ROLLBACK["properties"],
    "source_change_ids": {**CHANGE_IDS, "maxItems": 1}, "restoration": {"type": "null"},
    "limitations": {"type": "array", "minItems": 1, "maxItems": 1, "items": string(enum=[ALL_DAY_LIMITATION])}}}
ALL_DAY_ROLLBACK_ENVELOPE = {**ALL_DAY_ENVELOPE, "properties": {**ALL_DAY_ENVELOPE["properties"],
    "after": {**SNAPSHOT_FIELDS, "properties": {**SNAPSHOT_FIELDS["properties"],
        "time_zone": {"type": "null"}, "all_day": {"type": "boolean", "enum": [True]}}},
    "rollback": ALL_DAY_ROLLBACK}, "required": [*ALL_DAY_ENVELOPE["required"], "rollback"]}
ALL_DAY_PREVIEWS = {name: obj({"envelope": envelope, "authentication_tag": string(256, minLength=1)},
                            ("envelope", "authentication_tag")) for name, envelope in (
    ("commit_create", ALL_DAY_CREATE_ENVELOPE), ("commit_modify", ALL_DAY_ENVELOPE),
    ("commit_rollback", ALL_DAY_ROLLBACK_ENVELOPE))}


RECONCILIATION_LIMITATIONS = [
    "This records a user assessment of the earlier outcome; it is not native provider verification or proof of a fresh human confirmation.",
    "This changes only the integration journal. It does not change Calendar data, retry the earlier operation, or compensate for it.",
    "The original nonce, unknown result and quota charges remain retained under existing retention rules. Resolution may unblock related changes but does not make this execution eligible for automatic rollback."]
RECONCILIATION_ASSESSMENT = obj({"outcome": string(enum=["applied", "not_applied"]),
                                "evidence": string(2000, minLength=1)}, ("outcome", "evidence"))
# These are complete retained historical envelopes/results, including legacy forms.
# Native authentication and exact source comparison own their opaque interior.
RETAINED_JOURNAL_OBJECT = {"type": "object", "properties": {}, "required": [], "additionalProperties": True}
RECONCILIATION_SOURCE = obj({"change_id": IDENTITY, "payload_digest": string(64, minLength=64),
    "result_digest": string(64, minLength=64), "payload": RETAINED_JOURNAL_OBJECT,
    "result": RETAINED_JOURNAL_OBJECT}, ("change_id", "payload_digest", "result_digest", "payload", "result"))
RECONCILIATION_ENVELOPE = obj({"version": {"type": "integer", "enum": [1]},
    "kind": string(enum=["journal_reconciliation"]), "action": string(enum=["reconcile"]),
    "nonce": IDENTITY, "issued_at": STAMP, "expires_at": STAMP, "installation_id": IDENTITY,
    "credential_generation": IDENTITY, "key_id": IDENTITY, "source": RECONCILIATION_SOURCE,
    "assessment": RECONCILIATION_ASSESSMENT,
    "limitations": {"type": "array", "minItems": 3, "maxItems": 3, "uniqueItems": True,
                    "items": string(2000, enum=RECONCILIATION_LIMITATIONS)}},
    ("version", "kind", "action", "nonce", "issued_at", "expires_at", "installation_id",
     "credential_generation", "key_id", "source", "assessment", "limitations"))
RECONCILIATION_PREVIEW = obj({"envelope": RECONCILIATION_ENVELOPE,
                             "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))
RECONCILIATION_TOOLS = [
    tool("list_unresolved_changes", 'List unknown integration journal outcomes, including creation and recovery. Resolved records may disappear during pagination. No Calendar access, provider verification or automatic recovery occurs.',
         obj({"limit": {"type": "integer", "minimum": 1, "maximum": 100}, "cursor": string(4096, minLength=1)})),
    tool("preflight_reconciliation", "Preview a journal-only assessment of one retained unknown execution using the user's explicit applied/not_applied assessment and evidence. It does not access Calendar, verify the provider outcome, retry a mutation or create a pending approval.",
         obj({"change_id": IDENTITY, **RECONCILIATION_ASSESSMENT["properties"]}, ("change_id", "outcome", "evidence"))),
    tool("commit_reconciliation", "Record the user's reviewed assessment of an earlier unknown outcome in the integration journal only. No Calendar change, provider verification, retry or compensation occurs. Original nonce, unknown history and quotas remain retained; resolution may unblock related changes but never enables automatic recovery.",
         obj({"preview": RECONCILIATION_PREVIEW}, ("preview",)), write=True, destructive=True)]
for _tool in RECONCILIATION_TOOLS:
    _tool["annotations"]["idempotentHint"] = True
RECONCILIATION_TOOL_NAMES = frozenset(item["name"] for item in RECONCILIATION_TOOLS)


def tools_for_capabilities(*, alerts, recurrence=False, series_modification=False, future_modification=False,
                           future_termination=False, all_day_dates=False, reconciliation=False):
    base = (FUTURE_TERMINATION_TOOLS if future_termination and future_modification and series_modification and recurrence and alerts else
            FUTURE_MODIFICATION_TOOLS if future_modification and series_modification and recurrence and alerts else
            SERIES_MODIFICATION_TOOLS if series_modification and recurrence and alerts else
            RECURRENCE_TOOLS if recurrence and alerts else TOOLS if alerts else LEGACY_TOOLS)
    if reconciliation:
        base = [*base, *RECONCILIATION_TOOLS]
    if not all_day_dates or not alerts:
        return base
    result = deepcopy(base)
    for item in result:
        if item["name"] == "preflight_change":
            item["inputSchema"]["properties"]["fields"]["properties"]["all_day_dates"] = ALL_DAY_INTERVAL
            item["description"] += " Civil-date creation/correction is limited to nonrecurring floating all-day events with scope this and 1–366 calendar days. Metadata-only all-day edits preserve raw endpoints/timezone. Fresh all-day deletion, cutoff termination and copy restoration are unsupported in every timezone; timed termination remains supported when available."
        if item["name"] in ALL_DAY_PREVIEWS:
            old = item["inputSchema"]["properties"]["preview"]
            item["inputSchema"]["properties"]["preview"] = {"oneOf": [*old["oneOf"], ALL_DAY_PREVIEWS[item["name"]]]}
            item["description"] += {
                "commit_create": " Floating civil-date creation is nonrecurring only.",
                "commit_modify": " Civil-date correction is nonrecurring and floating only; metadata-only all-day edits preserve raw endpoints/timezone.",
                "commit_rollback": " Civil-date inverse restores one nonrecurring floating source and may change the raw endpoint style."
            }[item["name"]]
        if item["name"] in ("commit_delete", "preflight_rollback", "commit_rollback", "commit_future_delete", "commit_future_restore"):
            item["description"] += " Fresh all-day deletion, cutoff termination and copy restoration are unsupported in every timezone; civil-date inverse modification is not copy restoration."
    return result


class ValidationError(ValueError):
    pass


def validate(value, schema, path="arguments", depth=0):
    if depth == 0:
        try:
            validate_json(value)
        except (ValueError, RecursionError) as exc:
            raise ValidationError(str(exc)) from None
    if depth > 20:
        raise ValidationError("JSON nesting exceeds limit")
    if "oneOf" in schema:
        matched = 0
        for choice in schema["oneOf"]:
            try:
                validate(value, choice, path, depth)
                matched += 1
            except ValidationError:
                pass
        if matched != 1:
            raise ValidationError(path + " must match exactly one supported form")
        return
    kind = schema["type"]
    kinds = kind if isinstance(kind, list) else [kind]
    actual = ("null" if value is None else "boolean" if isinstance(value, bool) else
              "integer" if isinstance(value, int) else "number" if isinstance(value, float) else
              "string" if isinstance(value, str) else "array" if isinstance(value, list) else
              "object" if isinstance(value, dict) else "invalid")
    if actual not in kinds:
        raise ValidationError(path + " has invalid type")
    if "enum" in schema and value not in schema["enum"]:
        raise ValidationError(path + " has unsupported value")
    if value is None:
        return
    if actual == "object":
        props = schema["properties"]
        if (not schema.get("additionalProperties", False) and set(value) - set(props)) or set(schema["required"]) - set(value):
            raise ValidationError(path + " has missing or unknown fields")
        for key, item in value.items():
            if key in props:
                validate(item, props[key], path + "." + key, depth + 1)
    elif actual == "array":
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", 100):
            raise ValidationError(path + " has invalid item count")
        for item in value:
            validate(item, schema["items"], path + "[]", depth + 1)
        if schema.get("uniqueItems") and any(item in value[:index] for index, item in enumerate(value)):
            raise ValidationError(path + " requires unique items")
    elif actual in ("integer", "number"):
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            raise ValidationError(path + " is outside the permitted range")
    elif actual == "string":
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", 10000):
            raise ValidationError(path + " has invalid text length")
        if schema.get("format") == "date-time":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if not re.search(r"T.*(?:Z|[+-]\d\d:\d\d)$", value) or parsed.tzinfo is None:
                    raise ValueError()
            except ValueError:
                raise ValidationError(path + " requires ISO8601 with explicit offset") from None
        elif schema.get("format") == "time-zone":
            try:
                ZoneInfo(value)
            except (ZoneInfoNotFoundError, ValueError):
                raise ValidationError(path + " requires a recognized IANA time zone") from None
        elif schema.get("format") == "date":
            try:
                if datetime.strptime(value, "%Y-%m-%d").date().isoformat() != value:
                    raise ValueError()
            except ValueError:
                raise ValidationError(path + " requires an exact real YYYY-MM-DD calendar date") from None


def validate_arguments(name, arguments, *, alerts=True, recurrence=False, series_modification=False,
                       future_modification=False, future_termination=False, all_day_dates=False, reconciliation=False):
    tools = {item["name"]: item for item in tools_for_capabilities(alerts=alerts, recurrence=recurrence,
                                                               series_modification=series_modification,
                                                               future_modification=future_modification,
                                                               future_termination=future_termination, all_day_dates=all_day_dates,
                                                               reconciliation=reconciliation)}
    if name not in tools:
        raise ValidationError("Unknown tool")
    validate(arguments, tools[name]["inputSchema"])
    if name == "preflight_reconciliation" and not arguments["evidence"].strip():
        raise ValidationError("Assessment evidence must not be blank")
    if name == "commit_reconciliation":
        envelope = arguments["preview"]["envelope"]
        if envelope["limitations"] != RECONCILIATION_LIMITATIONS or not envelope["assessment"]["evidence"].strip():
            raise ValidationError("Journal assessment requires exact signed limitations and nonblank evidence")
    if name == "preflight_change":
        action = arguments["action"]
        fields = arguments.get("fields")
        series = arguments["scope"] == "series"
        rule = fields.get("recurrence") if fields else None
        series_edit = series_modification and recurrence and alerts and series and action == "modify"
        future_edit = future_modification and series_modification and recurrence and alerts and arguments["scope"] == "future" and action == "modify"
        future_delete = future_termination and future_modification and series_modification and recurrence and alerts and arguments["scope"] == "future" and action == "delete"
        if ((not series_edit and not future_edit and not future_delete and series != (action == "create" and rule is not None))
                or (arguments["scope"] == "future" and not (future_edit or future_delete))
                or (rule is not None and action != "create")):
            raise ValidationError("Only series creation accepts and requires recurrence; modify/delete require scope this")
        if ("cutoff" in arguments) != future_delete:
            raise ValidationError("Only future termination accepts and requires an explicit cutoff")
        if (series_edit or future_edit) and (not fields or set(fields) - set(SERIES_FIELD_NAMES)):
            raise ValidationError("Series modification requires only title, notes, plain location or alerts")
        if (series_edit or future_edit) and "title" in fields and not fields["title"].strip():
            raise ValidationError("Series title must not be blank")
        if rule is not None:
            validate_recurrence(rule)
        civil = fields.get("all_day_dates") if fields else None
        if civil is not None:
            if action not in ("create", "modify") or arguments["scope"] != "this" or set(fields) & {"start", "end", "time_zone", "all_day", "recurrence"}:
                raise ValidationError("Civil all-day dates require nonrecurring scope this and cannot mix temporal fields")
            validate_all_day_interval(civil)
        if all_day_dates and action == "create" and fields and fields.get("all_day") is True:
            if arguments["scope"] != "this" or rule is not None or not isinstance(fields.get("time_zone"), str):
                raise ValidationError("Use all_day_dates for floating all-day creation; recurring structural creation is unsupported")
        if action == "create":
            required = {"title", "all_day_dates"} if civil is not None else {"title", "start", "end"}
            if "calendar_id" not in arguments or "event_id" in arguments or fields is None or not required <= fields.keys():
                raise ValidationError("Create requires calendar_id and title/start/end only")
        elif "event_id" not in arguments or "calendar_id" in arguments or (action == "delete" and fields is not None) or (action == "modify" and not fields):
            raise ValidationError("Modify/delete require event_id and action-appropriate fields")
        if fields and "alerts" in fields:
            normalized = []
            for alert in fields["alerts"]:
                try:
                    key = (("relative", alert["relative_minutes"]) if "relative_minutes" in alert else
                           ("absolute", datetime.fromisoformat(alert["at"].replace("Z", "+00:00")).astimezone(timezone.utc)))
                except (ValueError, OverflowError):
                    raise ValidationError("Alert timestamp cannot be represented in UTC") from None
                if key in normalized:
                    raise ValidationError("Alerts must not contain duplicate triggers")
                normalized.append(key)
    if (name.startswith("commit_") and name not in ("commit_rollback", "commit_series_rollback", "commit_future_rollback", "commit_reconciliation")
            and arguments["preview"]["envelope"]["action"] != (
                "modify" if name in ("commit_series_modify", "commit_future_modify") else
                "delete" if name == "commit_future_delete" else "create" if name == "commit_future_restore" else name.removeprefix("commit_"))):
        raise ValidationError("Preview action does not match commit tool")
    if name in ALL_DAY_PREVIEWS and arguments["preview"]["envelope"]["version"] == 7:
        validate_all_day_preview(arguments["preview"]["envelope"], rollback=name == "commit_rollback")
    if name in ("commit_series_modify", "commit_series_rollback"):
        validate_series_preview(arguments["preview"]["envelope"], rollback=name == "commit_series_rollback")
    if name in ("commit_future_modify", "commit_future_rollback"):
        validate_future_preview(arguments["preview"]["envelope"], rollback=name == "commit_future_rollback")
    if name in ("commit_future_delete", "commit_future_restore"):
        validate_future_termination_preview(arguments["preview"]["envelope"], restore=name == "commit_future_restore")
    if name in ("commit_create", "commit_modify", "commit_delete") and arguments["preview"]["envelope"]["version"] == 3:
        envelope = arguments["preview"]["envelope"]
        action, before, after = envelope["action"], envelope["before"], envelope["after"]
        create, delete = action == "create", action == "delete"
        series = envelope["scope"] == "series"
        rule = after.get("recurrence") if after else None
        if (before is None) != create or (after is None) != delete:
            raise ValidationError("Preview before/after must match its action")
        if series != (create and rule is not None) or (rule is not None and not create):
            raise ValidationError("Only series creation accepts and requires recurrence")
        if create and "alerts" not in after:
            raise ValidationError("Creation preview requires complete alerts")
        if rule is not None:
            validate_recurrence(rule)
        structural = before is not None and (before["recurring"] or before["detached"])
        expected = ({"mode": "not_applicable", "limitations": []} if create else
                    {"mode": "occurrence_fields", "limitations": [OCCURRENCE_RECOVERY_LIMITATION] if structural else []} if not delete else
                    {"mode": "standalone_copy", "limitations": [COPY_RECOVERY_LIMITATION, *([RECURRING_DELETE_LIMITATION] if structural else [])]})
        if envelope["recovery"] != expected:
            raise ValidationError("Preview requires the exact action-specific recovery disclosure")
    if name == "commit_rollback":
        envelope = arguments["preview"]["envelope"]
        create = envelope["action"] == "create"
        if (envelope["before"] is None) != create or (envelope["rollback"]["restoration"] is not None) != create:
            raise ValidationError("Rollback before/restoration must match the native recovery action")
    if name == "preflight_rollback":
        selected = "change_ids" in arguments
        if (selected and set(arguments) != {"change_ids"}) or (not selected and arguments.get("all") is not True):
            raise ValidationError("Rollback requires change_ids alone or all:true with optional filters")
    if name in ("list_changes", "preflight_rollback") and "since" in arguments and "until" in arguments:
        start = datetime.fromisoformat(arguments["since"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(arguments["until"].replace("Z", "+00:00"))
        if end <= start:
            raise ValidationError("History until must be after since")


def validate_recurrence(rule):
    if "days_of_week" in rule and rule["frequency"] != "weekly":
        raise ValidationError("days_of_week is supported only for weekly recurrence")


def validate_series_preview(envelope, *, rollback):
    before, after, series = envelope["before"], envelope["after"], envelope["series"]
    changed = series["changed_fields"]
    if changed != sorted(changed):
        raise ValidationError("Series changed_fields must be sorted and unique")
    if envelope["recovery"]["limitations"] != SERIES_LIMITATIONS:
        raise ValidationError("Series preview requires the exact recovery limitations")
    selected = series["selected"]
    if (not before["recurring"] or before["detached"] or not selected["recurring"] or selected["detached"]
            or before["calendar"] != envelope["calendar"] or selected["calendar"] != envelope["calendar"]
            or before["occurrence"] is None or selected["occurrence"] is None):
        raise ValidationError("Series preview requires the current pattern anchor and selected calendar")
    validate(before["occurrence"], STAMP)
    validate(selected["occurrence"], STAMP)
    if (datetime.fromisoformat(before["occurrence"].replace("Z", "+00:00"))
            > datetime.fromisoformat(selected["occurrence"].replace("Z", "+00:00"))):
        raise ValidationError("Series first occurrence must not be later than the selected occurrence")
    if before["id"] == selected["id"] and before != selected:
        raise ValidationError("One series reference identity requires the same signed snapshot")
    for field, value in before["fields"].items():
        if field not in changed and after[field] != value:
            raise ValidationError("Series preview changes an unmasked field")
    if rollback:
        recovery = envelope["rollback"]
        if (selected != before or recovery["limitations"] != SERIES_LIMITATIONS
                or (recovery["alarm_restoration"] is not None) != ("alerts" in changed)):
            raise ValidationError("Series recovery requires exact limitations and masked alarm restoration")
    else:
        if ("alerts" in after) != ("alerts" in changed):
            raise ValidationError("Series alerts must match the exact changed_fields mask")
        for field in changed:
            if field != "alerts":
                validate(after[field], FIELDS["properties"][field])
        if "title" in changed and not after["title"].strip():
            raise ValidationError("Series title must not be blank")
        if "alerts" not in changed and all(after[field] == before["fields"][field] for field in changed):
            raise ValidationError("Series modification must change at least one default field")


def validate_future_preview(envelope, *, rollback):
    before, after, future = envelope["before"], envelope["after"], envelope["future"]
    anchor, changed = future["first_anchor"], future["changed_fields"]
    if changed != sorted(changed) or envelope["recovery"]["limitations"] != FUTURE_LIMITATIONS:
        raise ValidationError("Future preview requires the exact sorted field mask and recovery limitations")
    if (not before["recurring"] or before["detached"] or not anchor["recurring"] or anchor["detached"]
            or before["calendar"] != envelope["calendar"] or anchor["calendar"] != envelope["calendar"]
            or before["occurrence"] != before["fields"]["start"]
            or future["boundary"] != before["occurrence"] or anchor["occurrence"] != anchor["fields"]["start"]):
        raise ValidationError("Future preview requires the exact selected recurring boundary and original calendar")
    validate(anchor["occurrence"], STAMP)
    instant = lambda stamp: datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    boundary = instant(future["boundary"])
    if (instant(anchor["occurrence"]) > boundary or instant(envelope["issued_at"]) >= boundary
            or instant(envelope["expires_at"]) > boundary
            or instant(envelope["expires_at"]) <= instant(envelope["issued_at"])):
        raise ValidationError("Future preview expiry and first anchor must respect its exact future boundary")
    if before["id"] == anchor["id"] and before != anchor:
        raise ValidationError("One future reference identity requires the same signed snapshot")
    if before["details"].get("recurrence_rules") != anchor["details"].get("recurrence_rules"):
        raise ValidationError("Future selected occurrence and first anchor require the same recurrence rule")
    for field, value in before["fields"].items():
        if field not in changed and after[field] != value:
            raise ValidationError("Future preview changes an unmasked field")
    if rollback:
        recovery = envelope["rollback"]
        if (anchor != before or recovery["limitations"] != FUTURE_LIMITATIONS
                or (recovery["alarm_restoration"] is not None) != ("alerts" in changed)):
            raise ValidationError("Future recovery requires the current boundary, exact limitations and masked alarm restoration")
    else:
        if ("alerts" in after) != ("alerts" in changed):
            raise ValidationError("Future alerts must match the exact changed_fields mask")
        for field in changed:
            if field != "alerts":
                validate(after[field], FIELDS["properties"][field])
        if "title" in changed and not after["title"].strip():
            raise ValidationError("Future title must not be blank")
        if "alerts" not in changed and all(after[field] == before["fields"][field] for field in changed):
            raise ValidationError("Future modification must change at least one default field")


def validate_future_termination_preview(envelope, *, restore):
    try:
        _validate_future_termination_preview(envelope, restore=restore)
    except ValidationError:
        raise
    except (ValueError, OverflowError):
        raise ValidationError("Future cutoff/window cannot be represented with its exact timezone semantics") from None


def _validate_future_termination_preview(envelope, *, restore):
    future = envelope["future"]
    anchor, reference = future["first_anchor"], future["reference"]
    instant = lambda stamp: datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    boundary, resolved = instant(future["boundary"]), instant(future["resolved_cutoff"])
    start, end = (instant(future["selection_window"][key]) for key in ("start", "end"))
    if (future["selection_window"]["start"] != future["resolved_cutoff"]
            or not start <= boundary < end):
        raise ValidationError("Future termination requires its exact cutoff and bounded inclusive selection window")
    cutoff = future["cutoff"]
    zone = ZoneInfo(cutoff["time_zone"]) if "date" in cutoff else timezone.utc
    if end != (start.astimezone(zone) + timedelta(days=366)).astimezone(timezone.utc):
        raise ValidationError("Future termination requires a complete 366-calendar-day selection window")
    if "date" in cutoff:
        local = resolved.astimezone(zone)
        if local.date().isoformat() != cutoff["date"] or any((local.hour, local.minute, local.second, local.microsecond)):
            raise ValidationError("Future date cutoff must resolve to the supplied local midnight")
    elif instant(cutoff["at"]) != resolved:
        raise ValidationError("Future instant cutoff must match its resolved instant")
    for event in (anchor, reference):
        if (not event["recurring"] or event["detached"] or event["calendar"] != envelope["calendar"]
                or event["occurrence"] != event["fields"]["start"]):
            raise ValidationError("Future termination requires exact recurring reference/anchor snapshots in its calendar")
        validate(event["occurrence"], STAMP)
    if (instant(anchor["occurrence"]) > boundary
            or future["removes_entire_current_pattern"] != (instant(anchor["occurrence"]) == boundary)):
        raise ValidationError("Future termination requires the exact whole-pattern flag and first anchor")
    if anchor["id"] == reference["id"] and anchor != reference:
        raise ValidationError("One termination reference identity requires the same signed snapshot")
    if anchor["details"].get("recurrence_rules") != reference["details"].get("recurrence_rules"):
        raise ValidationError("Termination reference and first anchor require the same recurrence rule")
    if envelope["recovery"]["limitations"] != FUTURE_TERMINATION_LIMITATIONS:
        raise ValidationError("Future termination requires all seven exact independent-copy recovery limitations")
    rule = future["copy_recurrence"]
    validate_recurrence(rule)
    if rule["end"] is not None and ("until" not in rule["end"] or instant(rule["end"]["until"]) < boundary):
        raise ValidationError("Future termination copy recurrence must be unbounded or date-ended after its boundary")
    issued, expires = instant(envelope["issued_at"]), instant(envelope["expires_at"])
    if expires <= issued:
        raise ValidationError("Future termination/recovery expiry must follow issuance")
    if restore:
        recovery = envelope["rollback"]
        if (envelope["after"]["start"] != future["boundary"]
                or envelope["after"]["recurrence"] != rule
                or recovery["limitations"] != FUTURE_TERMINATION_LIMITATIONS):
            raise ValidationError("Future restore requires the exact deleted boundary, copy rule and recovery limitations")
        past = recovery["restoration"]["past_anchor"]
        if (past is None) != future["removes_entire_current_pattern"]:
            raise ValidationError("Future restore must sign its exact preserved prefix or whole-pattern absence")
        if past is not None and (past["id"] != anchor["id"] or past["calendar"] != envelope["calendar"]
                                 or past["occurrence"] != anchor["occurrence"]):
            raise ValidationError("Future restore prefix must retain the original first-anchor identity")
    else:
        before = envelope["before"]
        if (not before["recurring"] or before["detached"] or before["calendar"] != envelope["calendar"]
                or before["occurrence"] != future["boundary"] or before["fields"]["start"] != future["boundary"]
                or issued >= boundary or expires > boundary
                or before["details"].get("recurrence_rules") != anchor["details"].get("recurrence_rules")):
            raise ValidationError("Future deletion requires the exact selected boundary strictly after issue and bounded expiry")
        for event in (anchor, reference):
            if before["id"] == event["id"] and before != event:
                raise ValidationError("One deletion reference identity requires the same signed snapshot")


def validate_all_day_interval(value):
    validate(value, ALL_DAY_INTERVAL)
    span = (datetime.strptime(value["end_date_exclusive"], "%Y-%m-%d").date()
            - datetime.strptime(value["start_date"], "%Y-%m-%d").date()).days
    if not 1 <= span <= 366:
        raise ValidationError("All-day civil interval must span 1 through 366 calendar days")


def validate_all_day_preview(envelope, *, rollback):
    contract, before, after = envelope["all_day"], envelope["before"], envelope["after"]
    create = envelope["action"] == "create"
    if (contract["before"] is None) != create or contract["readback_ends"] != ALL_DAY_READBACK_ENDS:
        raise ValidationError("All-day preview requires exact action-specific civil dates and ordered readback styles")
    validate_all_day_interval(contract["after"])
    if before is not None:
        validate_all_day_interval(contract["before"])
        if (before["recurring"] or before["detached"] or not before["fields"]["all_day"]
                or before["fields"]["time_zone"] is not None or before["calendar"] != envelope["calendar"]):
            raise ValidationError("Civil date edits require one nonrecurring floating all-day target")
    if rollback:
        if envelope["rollback"]["limitations"] != [ALL_DAY_LIMITATION]:
            raise ValidationError("All-day inverse requires the exact raw-end-style limitation")
    else:
        for name in ("title", "notes", "location"):
            if create or after[name] != before["fields"][name]:
                validate(after[name], FIELDS["properties"][name])
        if not after["title"].strip():
            raise ValidationError("All-day title must not be blank")
    # The native Foundation codec alone binds civil labels to the captured
    # default zone, exact instants and supported raw representations. Do not
    # normalize the signed payload or substitute a Python timezone projection.
