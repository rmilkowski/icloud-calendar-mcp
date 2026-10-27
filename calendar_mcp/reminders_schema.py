# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Independent optional Reminders JSON contracts; Calendar schemas stay unchanged."""

from datetime import date, datetime, timezone
import json
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .schema import IDENTITY, STAMP, ValidationError, obj, string, tool, validate

MAX_REMINDER_SNAPSHOT = 128 * 1024
MAX_REMINDER_PREVIEW = 192 * 1024
MAX_REMINDER_ASSESSMENT = 320 * 1024
MAX_REMINDER_UNKNOWN_RESULT = 16 * 1024
MAX_REMINDER_ASCII_PREVIEW = 400 * 1024
MAX_REMINDER_ASCII_ASSESSMENT = 900 * 1024
MAX_REMINDER_ASCII_UNKNOWN_RESULT = 32 * 1024
REMINDER_ACTIONS = ("create", "modify", "complete", "reopen", "delete")
REMINDER_FIELD_NAMES = ("title", "notes", "priority", "start", "due")
REMINDER_MASK_NAMES = ("alerts", "completed", "due", "notes", "priority", "start", "title")
REMINDER_ALERTS = {"type": "array", "maxItems": 10, "items": obj({"at": STAMP}, ("at",))}
REMINDER_DATE = obj({"date": string(10), "time": {"type": ["string", "null"], "maxLength": 8},
                     "time_zone": {"type": ["string", "null"], "maxLength": 100}},
                    ("date", "time", "time_zone"))
NULLABLE_REMINDER_DATE = {**REMINDER_DATE, "type": ["object", "null"]}
REMINDER_FIELDS = obj({"title": string(1000, minLength=1), "notes": string(10000),
                      "priority": {"type": "integer", "minimum": 0, "maximum": 9},
                      "start": NULLABLE_REMINDER_DATE, "due": NULLABLE_REMINDER_DATE,
                      "alerts": REMINDER_ALERTS})
REMINDER_SNAPSHOT_FIELDS = {**REMINDER_FIELDS, "properties": {**REMINDER_FIELDS["properties"],
    "title": string(65536), "notes": string(65536)}, "required": list(REMINDER_FIELD_NAMES)}
REMINDER_SNAPSHOT_FIELDS["properties"] = {key: value for key, value in REMINDER_SNAPSHOT_FIELDS["properties"].items() if key != "alerts"}
REMINDER_LIST = obj({"id": IDENTITY, "title": string(65536), "source": string(65536),
                     "writable": {"type": "boolean"}}, ("id", "title", "source", "writable"))
REMINDER_SNAPSHOT = obj({"id": IDENTITY, "list_id": IDENTITY, "fields": REMINDER_SNAPSHOT_FIELDS,
    "completed": {"type": "boolean"}, "completion_date": {**STAMP, "type": ["string", "null"]},
    "details": {"type": "object", "properties": {}, "required": [], "additionalProperties": True},
    "fingerprint": string(256), "unsupported_reasons": {"type": "array", "maxItems": 100,
                                                        "items": string(2000)}},
    ("id", "list_id", "fields", "completed", "completion_date", "details", "fingerprint", "unsupported_reasons"))
REMINDER_LIMITATIONS = [
    "Recovery is a new reviewed write and requires retained details, unchanged supported state, and no conflicting later operation.",
    "Only supported EventKit reminder fields are covered; tags, subtasks, attachments, assignments, sharing, ordering, and other private app metadata are not restored or verified.",
    "Deletion recovery creates a new nonrecurring reminder with a new identity; it does not restore the original object or list relationships."]
REMINDER_RECONCILIATION_LIMITATIONS = [
    "This records a user assessment of the earlier outcome; it is not native provider verification or proof of a fresh human confirmation.",
    "No reminder is created, changed, deleted, retried, or restored by this journal assessment.",
    "The original nonce, unknown result, quota charges, and replay protection remain retained; this assessment does not enable automatic recovery."]
LIMITATIONS = {"type": "array", "minItems": 3, "maxItems": 3, "items": string(2000)}
REMINDER_HEADER = {"version": {"type": "integer", "enum": [1]}, "domain": string(enum=["reminders"]),
    "nonce": IDENTITY, "issued_at": STAMP, "expires_at": STAMP, "installation_id": IDENTITY,
    "credential_generation": IDENTITY, "key_id": IDENTITY}
REMINDER_AFTER = obj({"fields": {**REMINDER_SNAPSHOT_FIELDS,
    "properties": {**REMINDER_SNAPSHOT_FIELDS["properties"], "alerts": REMINDER_ALERTS}},
    "completed": {"type": "boolean"}}, ("fields", "completed"))
REMINDER_ROLLBACK = obj({"source_change_id": IDENTITY, "source_digest": string(64, minLength=64),
    "completion_date": {**STAMP, "type": ["string", "null"]},
    "restoration_details": {"type": ["object", "null"], "properties": {}, "required": [], "additionalProperties": True},
    "alarm_restoration": {"type": ["array", "null"], "maxItems": 10000,
                           "items": {"type": "object", "properties": {}, "required": [], "additionalProperties": True}}},
    ("source_change_id", "source_digest", "completion_date", "alarm_restoration", "restoration_details"))
REMINDER_ENVELOPE = obj({**REMINDER_HEADER, "action": string(enum=list(REMINDER_ACTIONS)),
    "scope": string(enum=["this"]), "list": REMINDER_LIST,
    "before": {**REMINDER_SNAPSHOT, "type": ["object", "null"]},
    "after": {**REMINDER_AFTER, "type": ["object", "null"]},
    "changed_fields": {"type": "array", "maxItems": 7, "uniqueItems": True,
                       "items": string(enum=list(REMINDER_MASK_NAMES))},
    "completion_date_policy": string(enum=["none", "preserve", "set_on_commit", "clear", "restore"]),
    "recovery": obj({"mode": string(enum=["none", "delete_created", "inverse_fields", "limited_copy"]),
                      "limitations": LIMITATIONS}, ("mode", "limitations")),
    "rollback": {**REMINDER_ROLLBACK, "type": ["object", "null"]}},
    (*REMINDER_HEADER, "action", "scope", "list", "before", "after", "changed_fields", "completion_date_policy", "recovery", "rollback"))
REMINDER_PREVIEW = obj({"envelope": REMINDER_ENVELOPE, "authentication_tag": string(256, minLength=1)},
                       ("envelope", "authentication_tag"))
REMINDER_RECONCILIATION_ENVELOPE = obj({**REMINDER_HEADER,
    "domain": string(enum=["reminders_reconciliation"]),
    "source": obj({"change_id": IDENTITY, "payload_digest": string(64, minLength=64),
        "result_digest": string(64, minLength=64), "payload": REMINDER_ENVELOPE,
        "result": {"type": "object", "properties": {}, "required": [], "additionalProperties": True}},
        ("change_id", "payload_digest", "result_digest", "payload", "result")),
    "assessment": obj({"outcome": string(enum=["applied", "not_applied"]), "evidence": string(2000, minLength=1)},
                       ("outcome", "evidence")), "limitations": LIMITATIONS},
    (*REMINDER_HEADER, "source", "assessment", "limitations"))
REMINDER_RECONCILIATION_PREVIEW = obj({"envelope": REMINDER_RECONCILIATION_ENVELOPE,
    "authentication_tag": string(256, minLength=1)}, ("envelope", "authentication_tag"))
REMINDER_HISTORY = obj({"limit": {"type": "integer", "minimum": 1, "maximum": 100},
    "cursor": string(4096, minLength=1), "include_expired": {"type": "boolean"}, "list_id": IDENTITY,
    "action": string(enum=list(REMINDER_ACTIONS)),
    "state": string(enum=["intent_recorded", "unknown", "applied", "not_applied", "reconciled"])})
REMINDER_TOOLS = [
    tool("list_reminder_lists", "List up to 200 configured Reminders lists and write eligibility. List/container creation and deletion are unsupported.", obj({})),
    tool("query_reminders", "Read bounded reminders from one list. Default status is incomplete. Date filters use inclusive due_from and exclusive due_to civil labels; unsupported original components remain explicit. A true truncated response requires narrower filters; there is no all-results or pagination promise.",
         obj({"list_id": IDENTITY, "status": string(enum=["incomplete", "completed", "all"]),
              "title_contains": string(1000), "due_from": string(10), "due_to": string(10),
              "include_undated": {"type": "boolean"}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}, ("list_id",))),
    tool("get_reminder", "Read one opaque reminder identity, original date components, completion state and unsupported metadata reasons.", obj({"reminder_id": IDENTITY}, ("reminder_id",))),
    tool("preflight_reminder_change", "Prepare the complete signed nonrecurring reminder change. Create needs list_id and title; modify needs reminder_id and nonempty fields. Complete/reopen/delete need reminder_id without fields. Dates retain explicit civil/timezone semantics. Optional alerts replace the full display-alarm list with at most ten absolute {at} timestamps; omission preserves alarms and [] clears. A due date alone does not request a notification. Recurrence, list moves, direct completion-date edits and list/container changes are unsupported.",
         obj({"action": string(enum=list(REMINDER_ACTIONS)), "scope": string(enum=["this"]),
              "list_id": IDENTITY, "reminder_id": IDENTITY, "fields": REMINDER_FIELDS}, ("action", "scope"))),
    *[tool("commit_reminder_" + action, {
        "create": "Create one nonrecurring reminder from the complete native-authenticated preview. Arguments show the target list, full fields, absolute display alarms, incomplete state and limited creation recovery. Native permission, identity and durable intent checks apply.",
        "modify": "Apply the exact masked field changes to one identified nonrecurring reminder. The complete native-authenticated preview shows full before/after fields, retained completion state, explicit alarm replacement and recovery limitations. Native permission, stale-state, quota and durable intent checks apply.",
        "complete": "Mark one identified nonrecurring reminder completed. The complete native-authenticated preview shows its full before/after state and set_on_commit policy for the native completion timestamp. Other fields remain preserved; native permission, stale-state, quota and journal checks apply.",
        "reopen": "Reopen one identified nonrecurring reminder and clear its completion date. The complete native-authenticated preview shows the exact before/after state, preserved fields and limited inverse recovery. Native permission, stale-state, quota and journal checks apply.",
        "delete": "Delete one identified nonrecurring reminder from the complete native-authenticated preview. Arguments show the full before state and signed limitations for recovery as a new identity. Native permission, stale-state, quota and durable intent checks apply. Reminder lists are not deleted."}[action],
           obj({"preview": REMINDER_PREVIEW}, ("preview",)), write=True, destructive=action != "create") for action in REMINDER_ACTIONS],
    tool("get_reminder_change_status", "Read one original Reminders execution nonce without accessing provider data or retrying a mutation.", obj({"nonce": IDENTITY}, ("nonce",))),
    tool("list_reminder_changes", "Browse bounded newest-first retained Reminders history. Follow authenticated next_cursor; a page is not an all-history selection. Details expire after five days by default; minimal nonce, outcome, audit and quota history remain.", REMINDER_HISTORY),
    tool("get_stored_reminder_change", "Read one Reminders execution's retained source/result and recovery eligibility or explicit expiry. Calendar history is separate.", obj({"change_id": IDENTITY}, ("change_id",))),
    tool("preflight_reminder_rollback", "Prepare one exact signed inverse from one verified applied retained source. Creation inverse deletes the still-unchanged created reminder; modify/complete/reopen inverse restores supported fields/state; deletion recovery creates a new nonrecurring identity with limited metadata. Unknown, user-assessed, expired, already recovered or conflicting histories are ineligible. There is no batch/all recovery.", obj({"change_id": IDENTITY}, ("change_id",))),
    tool("commit_reminder_rollback", "Execute one complete native-authenticated Reminders inverse preview under current identity, permission, stale and safety checks. The preview shows the source binding, full supported before/after state and exact raw restoration details. Recovery is a new journalled write and does not restore hidden metadata or original deleted identity.", obj({"preview": REMINDER_PREVIEW}, ("preview",)), write=True, destructive=True),
    tool("list_unresolved_reminder_changes", "Read bounded unknown/interrupted Reminders execution metadata only, without provider access. Follow next_cursor; Calendar journal entries are separate.", obj({"limit": {"type": "integer", "minimum": 1, "maximum": 100}, "cursor": string(4096, minLength=1)})),
    tool("preflight_reminder_reconciliation", "Prepare a complete signed journal-only assessment of a retained unknown reminder execution using the user's explicit applied/not_applied assessment and evidence. No provider verification, mutation or automatic recovery occurs.", obj({"change_id": IDENTITY, "outcome": string(enum=["applied", "not_applied"]), "evidence": string(2000, minLength=1)}, ("change_id", "outcome", "evidence"))),
    tool("commit_reminder_reconciliation", "Record the user assessment shown by this complete native-authenticated journal preview. No reminder changes or provider verification occur; the original nonce, unknown result and quota remain retained. An identical authenticated preview replays its durable receipt. The signed assessment does not prove a fresh human click or enable automatic recovery.", obj({"preview": REMINDER_RECONCILIATION_PREVIEW}, ("preview",)), write=True, destructive=True)]
REMINDER_TOOL_MAP = {item["name"]: item for item in REMINDER_TOOLS}
REMINDER_TOOL_NAMES = frozenset(REMINDER_TOOL_MAP)


def validate_civil_date(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value) is None:
        raise ValidationError("Reminder date requires an exact Gregorian YYYY-MM-DD label")
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ValidationError("Reminder date requires a valid Gregorian date") from None


def validate_reminder_date(value):
    if value is None:
        return
    validate(value, REMINDER_DATE)
    day = validate_civil_date(value["date"])
    clock, zone = value["time"], value["time_zone"]
    if zone is not None:
        try:
            parsed_zone = ZoneInfo(zone)
        except (ValueError, ZoneInfoNotFoundError):
            raise ValidationError("Reminder date requires a recognized IANA timezone") from None
    if clock is None:
        return
    if re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]", clock) is None:
        raise ValidationError("Reminder time requires HH:MM:SS")
    if zone is None:
        return
    hour, minute, second = (int(part) for part in clock.split(":"))
    local = datetime(day.year, day.month, day.day, hour, minute, second)
    offsets = set()
    try:
        for fold in (0, 1):
            candidate = local.replace(tzinfo=parsed_zone, fold=fold)
            if candidate.astimezone(timezone.utc).astimezone(parsed_zone).replace(tzinfo=None) == local:
                offsets.add(candidate.utcoffset())
    except (OverflowError, ValueError):
        raise ValidationError("Reminder local date/time cannot be represented") from None
    if len(offsets) != 1:
        raise ValidationError("Reminder local date/time is ambiguous or nonexistent in its timezone")


def validate_reminder_fields(fields):
    for key in ("start", "due"):
        if key in fields:
            validate_reminder_date(fields[key])
    if "alerts" in fields:
        instants = []
        for alert in fields["alerts"]:
            try:
                instant = datetime.fromisoformat(alert["at"].replace("Z", "+00:00")).astimezone(timezone.utc)
            except (ValueError, OverflowError):
                raise ValidationError("Reminder alert requires a representable offset timestamp") from None
            if instant in instants:
                raise ValidationError("Reminder alerts must have distinct absolute timestamps")
            instants.append(instant)


def bound_reminder_json(value, limit, label, *, ensure_ascii=False):
    try:
        size = len(json.dumps(value, ensure_ascii=ensure_ascii, allow_nan=False, separators=(",", ":")).encode("utf-8"))
    except (TypeError, ValueError, UnicodeError, RecursionError, OverflowError):
        raise ValidationError("Invalid " + label + " JSON") from None
    if size > limit:
        raise ValidationError(label + " exceeds the supported size limit")


def validate_reminder_arguments(name, arguments):
    if name not in REMINDER_TOOL_MAP:
        raise ValidationError("Unknown Reminders tool")
    validate(arguments, REMINDER_TOOL_MAP[name]["inputSchema"])
    if name == "query_reminders":
        for key in ("due_from", "due_to"):
            if key in arguments:
                validate_civil_date(arguments[key])
        if "due_from" in arguments and "due_to" in arguments and arguments["due_from"] >= arguments["due_to"]:
            raise ValidationError("Reminder due_to must be after due_from")
    if name == "preflight_reminder_change":
        action, fields = arguments["action"], arguments.get("fields")
        if action == "create":
            if "list_id" not in arguments or "reminder_id" in arguments or not fields or "title" not in fields:
                raise ValidationError("Reminder creation requires list_id and title fields")
        elif ("reminder_id" not in arguments or "list_id" in arguments
              or (action == "modify" and not fields) or (action != "modify" and fields is not None)):
            raise ValidationError("Reminder action requires one reminder_id and action-appropriate fields")
        if fields is not None:
            validate_reminder_fields(fields)
            if "title" in fields and not fields["title"].strip():
                raise ValidationError("Reminder title must not be blank")
    if name == "preflight_reminder_reconciliation" and not arguments["evidence"].strip():
        raise ValidationError("Reminder assessment evidence must not be blank")
    if name.startswith("commit_reminder_"):
        preview = arguments["preview"]
        limit = MAX_REMINDER_ASSESSMENT if name == "commit_reminder_reconciliation" else MAX_REMINDER_PREVIEW
        bound_reminder_json(preview, limit, "Reminders preview")
        ascii_limit = MAX_REMINDER_ASCII_ASSESSMENT if name == "commit_reminder_reconciliation" else MAX_REMINDER_ASCII_PREVIEW
        bound_reminder_json(preview, ascii_limit, "ASCII Reminders preview", ensure_ascii=True)
        envelope = preview["envelope"]
        validate_reminder_header(envelope)
        if name == "commit_reminder_reconciliation":
            if envelope["limitations"] != REMINDER_RECONCILIATION_LIMITATIONS or not envelope["assessment"]["evidence"].strip():
                raise ValidationError("Reminder assessment requires exact limitations and nonblank evidence")
            bound_reminder_json(envelope["source"]["payload"], MAX_REMINDER_PREVIEW, "Reminder source")
            bound_reminder_json(envelope["source"]["result"], MAX_REMINDER_UNKNOWN_RESULT, "Reminder unknown result")
            bound_reminder_json(envelope["source"]["result"], MAX_REMINDER_ASCII_UNKNOWN_RESULT, "ASCII Reminder unknown result", ensure_ascii=True)
            if envelope["source"]["result"].get("state") != "unknown":
                raise ValidationError("Reminder assessment requires the exact unknown source result")
            validate_reminder_envelope(envelope["source"]["payload"], historical=True)
        else:
            rollback = name == "commit_reminder_rollback"
            if (envelope["rollback"] is not None) != rollback:
                raise ValidationError("Reminder recovery must use its dedicated commit tool")
            if not rollback and envelope["action"] != name.removeprefix("commit_reminder_"):
                raise ValidationError("Reminder preview action does not match the commit tool")
            validate_reminder_envelope(envelope)


def validate_reminder_header(envelope):
    issued = datetime.fromisoformat(envelope["issued_at"].replace("Z", "+00:00"))
    expiry = datetime.fromisoformat(envelope["expires_at"].replace("Z", "+00:00"))
    if not 0 < (expiry - issued).total_seconds() <= 600:
        raise ValidationError("Reminder preview lifetime must be at most ten minutes")


def validate_reminder_envelope(envelope, *, historical=False):
    action, before, after = envelope["action"], envelope["before"], envelope["after"]
    mask, rollback = envelope["changed_fields"], envelope["rollback"]
    recovery = envelope["recovery"]
    if mask != sorted(mask) or recovery["limitations"] != REMINDER_LIMITATIONS:
        raise ValidationError("Reminder preview requires a sorted mask and exact recovery limitations")
    if (before is None) != (action == "create") or (after is None) != (action == "delete"):
        raise ValidationError("Reminder preview before/after must match its action")
    if before is not None:
        bound_reminder_json(before, MAX_REMINDER_SNAPSHOT, "Reminder snapshot")
        if before["list_id"] != envelope["list"]["id"] or before["unsupported_reasons"]:
            raise ValidationError("Reminder preview requires one supported reminder/list identity")
        if before["completed"] != (before["completion_date"] is not None):
            raise ValidationError("Reminder completion state/date is inconsistent")
        validate_reminder_fields(before["fields"])
    if after is not None:
        validate_reminder_fields(after["fields"])
    if rollback is not None:
        if recovery["mode"] != "none" or action not in ("create", "modify", "delete"):
            raise ValidationError("Reminder inverse has an unsupported action or recovery mode")
        if action == "delete":
            if mask or envelope["completion_date_policy"] != "none" or any(rollback[key] is not None for key in ("completion_date", "alarm_restoration", "restoration_details")):
                raise ValidationError("Created-reminder inverse must delete only the exact created object")
        else:
            if (envelope["completion_date_policy"] != "restore" or not isinstance(rollback["restoration_details"], dict)
                    or after["completed"] != (rollback["completion_date"] is not None)
                    or "alerts" in after["fields"]):
                raise ValidationError("Reminder inverse requires exact retained completion/metadata restoration")
            if (rollback["alarm_restoration"] is not None) != ("alerts" in mask):
                raise ValidationError("Reminder inverse alarm restoration must match its mask")
            if action == "create" and mask != list(REMINDER_MASK_NAMES):
                raise ValidationError("Reminder copy requires the complete field mask")
            if action == "modify" and not mask:
                raise ValidationError("Reminder inverse field mask must not be empty")
    else:
        policies = {"create": "clear", "modify": "preserve", "complete": "set_on_commit", "reopen": "clear", "delete": "none"}
        modes = {"create": "delete_created", "delete": "limited_copy"}
        if envelope["completion_date_policy"] != policies[action] or recovery["mode"] != modes.get(action, "inverse_fields"):
            raise ValidationError("Reminder preview completion/recovery policy must match its action")
        if action == "create":
            if mask != list(REMINDER_MASK_NAMES) or after["completed"] or "alerts" not in after["fields"]:
                raise ValidationError("Reminder creation requires complete fields, alarms and incomplete state")
        elif action == "delete":
            if mask:
                raise ValidationError("Reminder deletion cannot contain a field mask")
        elif action in ("complete", "reopen"):
            target = action == "complete"
            if mask != ["completed"] or after["completed"] is not target or before["completed"] is target:
                raise ValidationError("Reminder completion action must change exactly its completed state")
        elif not mask or "completed" in mask or after["completed"] != before["completed"]:
            raise ValidationError("Reminder modification requires fields and preserves completed state")
        if after is not None:
            if ("alerts" in after["fields"]) != ("alerts" in mask):
                raise ValidationError("Reminder alarm intent must match the field mask")
            for field in mask:
                if field not in ("completed", "alerts"):
                    validate(after["fields"][field], REMINDER_FIELDS["properties"][field])
            if "title" in mask and not after["fields"]["title"].strip():
                raise ValidationError("Reminder title must not be blank")
    if before is not None and after is not None:
        for field in REMINDER_FIELD_NAMES:
            if field not in mask and after["fields"][field] != before["fields"][field]:
                raise ValidationError("Reminder preview changes an unmasked field")
