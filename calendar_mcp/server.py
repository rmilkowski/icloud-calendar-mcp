"""Bounded protected local and manual loopback HTTP listeners (JSON mode)."""

import fcntl
import hmac
import os
import stat
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import socket
from socketserver import ThreadingMixIn
import threading

from .protocol import VERSIONS, error, loads
from .native import NativeError
from .local_ipc import gateway_path, require_peer, validate_directory, validate_socket

MAX_BODY = 1024 * 1024
MAX_RESPONSE = 8 * 1024 * 1024


class BoundedRequests(ThreadingMixIn):
    daemon_threads = True
    block_on_close = True
    request_queue_size = 8

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


class UnixGatewayServer(BoundedRequests, HTTPServer):
    address_family = socket.AF_UNIX

    def __init__(self, owner, path):
        self.owner = owner
        self.slots = owner.slots
        super().__init__(str(path), Handler, bind_and_activate=False)

    def __getattr__(self, name):
        if name in ("token", "protocol", "authority", "origin"):
            return getattr(self.owner, name)
        raise AttributeError(name)

    def server_bind(self):
        # HTTPServer.server_bind assumes an internet address tuple.
        self.socket.bind(self.server_address)

    def get_request(self):
        connection, address = self.socket.accept()
        try:
            require_peer(connection)
            return connection, address
        except BaseException:
            connection.close()
            raise


class GatewayServer(BoundedRequests, HTTPServer):
    def __init__(self, port, token, protocol, state_directory=None):
        self.token = token
        self.protocol = protocol
        self.slots = threading.BoundedSemaphore(8)
        self._unix = None
        self._unix_thread = None
        self._unix_stop_lock = threading.Lock()
        self._endpoint = None
        self._endpoint_identity = None
        self._startup_lock = None
        self._serving = threading.Event()
        self._serving_thread = None
        # Bind TCP first: its port remains the conventional HTTP authority.
        super().__init__(("127.0.0.1", port), Handler)
        self.authority = "127.0.0.1:" + str(self.server_port)
        self.origin = "http://" + self.authority
        try:
            if state_directory is not None:
                self._open_unix(state_directory)
        except BaseException:
            self.server_close()
            raise

    def _open_unix(self, state):
        path = gateway_path(state, self.server_port)
        try:
            path.parent.mkdir(mode=0o700)
        except FileExistsError:
            pass
        validate_directory(path.parent, exact=True)
        # Persistent lock is private and cannot be replaced by another UID.
        descriptor = os.open(path.parent / "owner.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ValueError("Invalid local transport startup lock")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(descriptor)
            raise
        self._startup_lock = descriptor
        self._endpoint = path
        try:
            validate_socket(path)
        except FileNotFoundError:
            pass
        else:
            # Only a valid owned stale socket can be reclaimed under the lock.
            path.unlink()
        self._unix = UnixGatewayServer(self, path)
        self._unix.server_bind()
        # Capture our inode before permission/activation operations can fail.
        info = path.lstat()
        self._endpoint_identity = (info.st_dev, info.st_ino)
        path.chmod(0o600)
        validate_socket(path)
        self._unix.server_activate()

    def serve_forever(self, poll_interval=0.5):
        self._serving_thread = threading.get_ident()
        self._serving.set()
        try:
            if self._unix is not None:
                self._unix_thread = threading.Thread(target=self._unix.serve_forever,
                    kwargs={"poll_interval": poll_interval}, daemon=True)
                self._unix_thread.start()
            super().serve_forever(poll_interval=poll_interval)
        finally:
            self._stop_unix()
            self._serving.clear()

    def _stop_unix(self):
        with self._unix_stop_lock:
            thread = self._unix_thread
            if thread is not None and thread.is_alive():
                self._unix.shutdown()
                if thread.ident != threading.get_ident():
                    thread.join()
            self._unix_thread = None

    def shutdown(self):
        # BaseServer.shutdown deadlocks when called before serve_forever.
        if self._serving.is_set() and self._serving_thread != threading.get_ident():
            super().shutdown()

    def server_close(self):
        self._stop_unix()
        if self._unix is not None:
            self._unix.server_close()
            self._unix = None
        super().server_close()
        if self._endpoint_identity is not None:
            try:
                info = self._endpoint.lstat()
                if (info.st_dev, info.st_ino) == self._endpoint_identity and stat.S_ISSOCK(info.st_mode):
                    self._endpoint.unlink()
            except FileNotFoundError:
                pass
            self._endpoint_identity = None
        if self._startup_lock is not None:
            os.close(self._startup_lock)
            self._startup_lock = None


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
