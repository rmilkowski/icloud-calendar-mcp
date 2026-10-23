"""Newline stdio MCP adapter for a fixed local gateway; no retry or redirect."""

import http.client
import json
import sys

from .protocol import VERSIONS, error, loads
from .security import read_token
from .server import MAX_BODY, MAX_RESPONSE


class GatewayClient:
    def __init__(self, state, port=8765):
        self.token = read_token(state)
        if not 1 <= port <= 65535:
            raise ValueError("Invalid local port")
        self.port = port

    def send(self, wire, version=VERSIONS[-1]):
        # HTTPConnection bypasses proxy environment and has no redirect/retry behavior.
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=50)
        try:
            connection.request("POST", "/mcp", body=wire,
                               headers={"Authorization": "Bearer " + self.token,
                                        "Content-Type": "application/json",
                                        "Accept": "application/json, text/event-stream",
                                        "MCP-Protocol-Version": version})
            response = connection.getresponse()
            body = response.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                raise ValueError("Gateway response too large")
            if response.status == 202 and not body:
                return None
            if response.status != 200:
                raise ValueError("Gateway rejected request")
            return loads(body)
        finally:
            connection.close()

    def status(self, timeout=50):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            connection.request("GET", "/status", headers={"Authorization": "Bearer " + self.token,
                                                          "Accept": "application/json"})
            response = connection.getresponse()
            body = response.read(MAX_RESPONSE + 1)
            if response.status not in (200, 503) or len(body) > MAX_RESPONSE:
                raise ValueError("Gateway status request rejected")
            return loads(body)
        finally:
            connection.close()


def run_stdio(client, source=None, sink=None):
    source = source or sys.stdin.buffer
    sink = sink or sys.stdout.buffer
    version = VERSIONS[-1]
    while True:
        wire = source.readline(MAX_BODY + 1)
        if not wire:
            return 0
        if len(wire) > MAX_BODY or not wire.endswith(b"\n"):
            # Stop on framing errors instead of treating remainder as another request.
            sink.write(json.dumps(error(None, -32700, "Invalid or oversized stdio message")).encode() + b"\n")
            sink.flush()
            return 1
        identifier = None
        try:
            request = loads(wire)
            if isinstance(request, dict):
                identifier = request.get("id")
                if request.get("method") == "initialize":
                    requested = request.get("params", {}).get("protocolVersion")
                    if requested in VERSIONS:
                        version = requested
            result = client.send(wire, version)
        except (ValueError, UnicodeError, RecursionError, TypeError, AttributeError):
            result = error(identifier, -32700, "Invalid request or gateway response")
        except (OSError, http.client.HTTPException):
            result = error(identifier, -32603, "Gateway transport failed; no retry. If a write was submitted, query get_change_status by nonce after reconnecting")
        if result is not None:
            sink.write(json.dumps(result, ensure_ascii=True, allow_nan=False).encode() + b"\n")
            sink.flush()
