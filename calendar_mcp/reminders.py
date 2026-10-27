# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only optional Reminders status/history through protected gateway transport."""

import json
from pathlib import Path

from .adapter import GatewayClient
from .native import NativeError
from .reminders_schema import REMINDER_ACTIONS, validate_reminder_arguments
from .security import DEFAULT_STATE

READ_TOOLS = frozenset(("list_reminder_changes", "get_stored_reminder_change", "get_reminder_change_status",
                        "list_unresolved_reminder_changes", "preflight_reminder_rollback"))


def add_parser(subparsers):
    parser = subparsers.add_parser("reminders", help="Inspect optional Reminders authorization and retained history")
    commands = parser.add_subparsers(dest="reminders_command", required=True)
    status = commands.add_parser("status", help="Read separate authorization metadata; never requests access")
    status.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    status.add_argument("--port", type=int, default=8765)
    history = commands.add_parser("changes", help="Read or prepare one-source retained recovery; no commit command")
    actions = history.add_subparsers(dest="reminder_changes_command", required=True)
    for name in ("list", "show", "status", "unresolved", "prepare"):
        command = actions.add_parser(name)
        command.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
        command.add_argument("--port", type=int, default=8765)
        if name in ("show", "prepare"):
            command.add_argument("change_id")
        elif name == "status":
            command.add_argument("nonce")
        else:
            command.add_argument("--limit", type=int, default=50)
            command.add_argument("--cursor")
            if name == "list":
                command.add_argument("--include-expired", action="store_true")
                command.add_argument("--list-id")
                command.add_argument("--action", choices=REMINDER_ACTIONS)
                command.add_argument("--state", choices=("intent_recorded", "unknown", "applied", "not_applied", "reconciled"))


def read_tool(client, name, arguments):
    if name not in READ_TOOLS:
        raise ValueError("Reminders CLI supports read-only history and preparation only")
    validate_reminder_arguments(name, arguments)
    wire = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments}}, ensure_ascii=False, allow_nan=False).encode("utf-8")
    reply = client.send(wire)
    if not isinstance(reply, dict) or type(reply.get("id")) is not int or reply["id"] != 1 or "error" in reply:
        raise ValueError("Invalid Reminders history response")
    result = reply.get("result")
    if not isinstance(result, dict) or result.get("isError") is not False:
        raise NativeError("reminders_history_unavailable", "Reminders history could not be read; check explicit opt-in and native support")
    content = result.get("structuredContent")
    if not isinstance(content, dict):
        raise ValueError("Invalid Reminders history content")
    return content


def dispatch(args):
    client = GatewayClient(args.state_dir, args.port, resource="reminders")
    if args.reminders_command == "status":
        reply = client.status()
        if not isinstance(reply, dict) or reply.get("gateway") != "reachable":
            raise ValueError("Invalid gateway status")
        result = {"enabled": "reminders" in reply, "reminders": reply.get("reminders")}
    else:
        action = args.reminder_changes_command
        if action in ("show", "prepare"):
            name = "get_stored_reminder_change" if action == "show" else "preflight_reminder_rollback"
            arguments = {"change_id": args.change_id}
        elif action == "status":
            name, arguments = "get_reminder_change_status", {"nonce": args.nonce}
        else:
            name = "list_reminder_changes" if action == "list" else "list_unresolved_reminder_changes"
            arguments = {"limit": args.limit}
            if args.cursor is not None:
                arguments["cursor"] = args.cursor
            if action == "list":
                arguments["include_expired"] = args.include_expired
                arguments.update({key: getattr(args, key) for key in ("list_id", "action", "state") if getattr(args, key) is not None})
        result = read_tool(client, name, arguments)
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))
    return 0
