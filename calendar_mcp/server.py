"""Bounded private loopback Streamable HTTP server (JSON response mode only)."""

import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import socket
from socketserver import ThreadingMixIn
import threading

from .protocol import VERSIONS, error, loads
from .native import NativeError

MAX_BODY = 1024 * 1024
MAX_RESPONSE = 8 * 1024 * 1024


class GatewayServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    block_on_close = True
    request_queue_size = 8

    def __init__(self, port, token, protocol):
        self.token = token
        self.protocol = protocol
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(("127.0.0.1", port), Handler)
        self.authority = "127.0.0.1:" + str(self.server_port)
        self.origin = "http://" + self.authority

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # No traceback or request/credential/calendar data in logs.
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CalendarMCP"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def handle(self):
        # Absolute connection deadline also bounds slow headers/body. One request per connection.
        def expire():
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        timer = threading.Timer(55, expire)
        timer.daemon = True
        timer.start()
        try:
            super().handle()
        finally:
            timer.cancel()

    def __getattr__(self, name):
        # Authenticate even unsupported HTTP methods, before returning 405.
        if name.startswith("do_"):
            return self.route
        raise AttributeError(name)

    def log_message(self, format, *args):
        pass

    def version_string(self):
        return self.server_version

    def reply(self, status, payload=None, **headers):
        data = b"" if payload is None else json.dumps(payload, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode()
        if len(data) > MAX_RESPONSE:
            status, data = 500, b'{"error":"Response limit exceeded; narrow the query"}'
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        for key, value in headers.items():
            self.send_header(key.replace("_", "-"), value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def route(self):
        self.close_connection = True
        auth = self.headers.get_all("Authorization", [])
        supplied = auth[0] if len(auth) == 1 else ""
        if not hmac.compare_digest(supplied.encode("utf-8"), ("Bearer " + self.server.token).encode("ascii")):
            self.reply(401, {"error": "Authentication required"}, WWW_Authenticate='Bearer realm="calendar-local"')
            return
        hosts, origins = self.headers.get_all("Host", []), self.headers.get_all("Origin", [])
        if hosts != [self.server.authority] or len(origins) > 1 or (origins and origins != [self.server.origin]):
            self.reply(403, {"error": "Host or Origin rejected"})
            return
        if self.path == "/status":
            if self.command != "GET":
                self.reply(405, {"error": "Only GET is supported for local diagnostics"}, Allow="GET")
                return
            try:
                native = self.server.protocol.broker.authorization_status()
                self.reply(200, {"gateway": "reachable", "native": native})
            except NativeError as exc:
                self.reply(503, {"gateway": "reachable", "native": {"error": {"code": exc.code, "message": str(exc)}}})
            return
        if self.path != "/mcp":
            self.reply(404, {"error": "Not found"})
            return
        if self.command != "POST":
            self.reply(405, {"error": "Only POST is supported; no SSE subscription"}, Allow="POST")
            return
        versions = self.headers.get_all("MCP-Protocol-Version", [])
        if len(versions) > 1 or (versions and versions[0] not in VERSIONS):
            self.reply(400, {"error": "Unsupported MCP protocol version"})
            return
        if self.headers.get_all("Transfer-Encoding") or self.headers.get_all("Content-Encoding"):
            self.reply(400, {"error": "Transfer/content encoding unsupported"})
            return
        content_types = self.headers.get_all("Content-Type", [])
        if len(content_types) != 1 or content_types[0].lower() not in ("application/json", "application/json; charset=utf-8"):
            self.reply(415, {"error": "Expected application/json"})
            return
        accept = ",".join(self.headers.get_all("Accept", [])).lower()
        if "application/json" not in accept:
            self.reply(406, {"error": "Client must accept application/json and text/event-stream"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit():
            self.reply(411, {"error": "One Content-Length required"})
            return
        length = int(lengths[0]) if len(lengths[0]) < 12 else MAX_BODY + 1
        if not 0 < length <= MAX_BODY:
            self.reply(413, {"error": "Body limit exceeded"})
            return
        try:
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError()
            request = loads(data.decode("utf-8"))
        except (ValueError, UnicodeError, RecursionError):
            self.reply(400, error(None, -32700, "Invalid or excessive JSON"))
            return
        except (OSError, TimeoutError):
            self.reply(408, {"error": "Request timeout"})
            return
        result = self.server.protocol.handle(request)
        self.reply(202 if result is None else 200, result)
