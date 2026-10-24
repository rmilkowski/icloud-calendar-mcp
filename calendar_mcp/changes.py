"""Local change-history reads and an open-only native review-window launcher."""

import hashlib
import json
import os
from pathlib import Path
import socket
import stat

from .adapter import GatewayClient
from .native import NativeError
from .local_ipc import temporary_base as _temporary_base
from .protocol import loads
from .schema import RECOVERY_TOOLS, validate_arguments
from .security import DEFAULT_STATE


def add_parser(subparsers):
    parser = subparsers.add_parser("changes", help="Inspect retained changes or open native recovery review")
    actions = parser.add_subparsers(dest="changes_command", required=True)
    for name in ("list", "show", "open"):
        command = actions.add_parser(name)
        command.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
        command.add_argument("--port", type=int, default=8765)
        if name == "open":
            command.add_argument("--backend", choices=("eventkit", "synthetic"), default="eventkit")
        if name == "list":
            command.add_argument("--limit", type=int, default=50)
            command.add_argument("--cursor")
            command.add_argument("--since")
            command.add_argument("--until")
            command.add_argument("--action", choices=("modify", "delete"))
            command.add_argument("--event-id")
            command.add_argument("--include-expired", action="store_true")
        elif name == "show":
            command.add_argument("change_id")


def read_tool(client, name, arguments):
    """Use the authenticated gateway; never read native database or signing keys."""
    validate_arguments(name, arguments)
    wire = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments}},
                      ensure_ascii=False, allow_nan=False).encode("utf-8")
    reply = client.send(wire)
    if not isinstance(reply, dict) or type(reply.get("id")) is not int or reply["id"] != 1 or "error" in reply:
        raise ValueError("Invalid gateway history response")
    result = reply.get("result")
    if not isinstance(result, dict) or result.get("isError") is not False:
        raise NativeError("history_unavailable", "Native change history could not be read")
    content = result.get("structuredContent")
    if not isinstance(content, dict):
        raise ValueError("Invalid gateway history content")
    return content


def open_window(state, backend):
    """The local socket accepts only window activation, never approval or payloads."""
    state = Path(os.path.abspath(Path(state).expanduser()))
    native = state / ("native-" + backend)
    path = socket_path(native)
    for directory in (state, native):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & 0o077):
            raise ValueError("Native UI requires protected user-owned state")
    directory_info = path.parent.lstat()
    if (not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.getuid()
            or stat.S_IMODE(directory_info.st_mode) != 0o700):
        raise ValueError("Native UI socket directory must be private and user-owned")
    info = path.lstat()
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        raise ValueError("Native UI socket must be private and user-owned")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        connection.sendall(b'{"op":"open_changes"}\n')
        response = bytearray()
        while b"\n" not in response:
            chunk = connection.recv(1025 - len(response))
            if not chunk:
                raise ValueError("Native UI did not acknowledge window activation")
            response.extend(chunk)
            if len(response) > 1024:
                raise ValueError("Native UI response exceeded limit")
        acknowledgement = loads(response)
        if (response.count(b"\n") != 1 or not response.endswith(b"\n")
                or not isinstance(acknowledgement, dict) or set(acknowledgement) != {"opened"}
                or acknowledgement["opened"] is not True):
            raise ValueError("Invalid native UI response")
    return {"opened": True}


def socket_path(native):
    """Match native canonical UTF-8 hashing inside protected OS user storage."""
    fingerprint = hashlib.sha256(str(Path(native).resolve(strict=True)).encode("utf-8")).hexdigest()[:20]
    path = _temporary_base() / ("cmui-" + fingerprint) / "s"
    if len(os.fsencode(path)) >= 104:
        raise ValueError("Protected temporary path is too long for native UI socket")
    return path


def dispatch(args):
    if args.changes_command == "open":
        reply = GatewayClient(args.state_dir, args.port).send(json.dumps({"jsonrpc": "2.0", "id": 1,
                              "method": "tools/list", "params": {}}).encode("ascii"))
        if not isinstance(reply, dict) or type(reply.get("id")) is not int or reply["id"] != 1 or "error" in reply:
            raise ValueError("Recovery capability check failed")
        result = reply.get("result")
        tools = result.get("tools") if isinstance(result, dict) else None
        names = ({item["name"] for item in tools if isinstance(item, dict) and isinstance(item.get("name"), str)}
                 if isinstance(tools, list) else set())
        if not RECOVERY_TOOLS <= names:
            raise ValueError("Native recovery UI is unavailable on this helper")
        result = open_window(args.state_dir, args.backend)
    else:
        if args.changes_command == "show":
            arguments = {"change_id": args.change_id}
        else:
            arguments = {"limit": args.limit, "include_expired": args.include_expired}
            arguments.update({key: getattr(args, key) for key in
                              ("cursor", "since", "until", "action", "event_id")
                              if getattr(args, key) is not None})
        name = "get_stored_change" if args.changes_command == "show" else "list_changes"
        result = read_tool(GatewayClient(args.state_dir, args.port), name, arguments)
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))
    return 0
