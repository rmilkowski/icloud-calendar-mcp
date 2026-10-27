# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Protected Darwin local endpoints and peer identity, independent of TMPDIR."""

import ctypes
import errno
import hashlib
import http.client
import os
from pathlib import Path
import socket
import stat
import sys


def temporary_base():
    if sys.platform != "darwin":
        raise ValueError("Protected local transport requires Darwin")
    value = os.confstr(os.confstr_names.get("CS_DARWIN_USER_TEMP_DIR", 65537))
    if not isinstance(value, str) or not value.startswith("/") or len(os.fsencode(value)) > 4095:
        raise ValueError("Invalid protected user temporary directory")
    supplied = Path(value)
    validate_directory(supplied)
    canonical = Path(os.path.realpath(supplied, strict=True))
    validate_directory(canonical)
    return canonical


def validate_directory(path, *, exact=False):
    info = Path(path).lstat()
    mode = stat.S_IMODE(info.st_mode)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or (mode != 0o700 if exact else mode & 0o077)):
        raise ValueError("Local transport directory must be private and user-owned")
    return info


def gateway_path(state, port):
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("Invalid local port")
    state = Path(state).expanduser().absolute()
    validate_directory(state)
    canonical = Path(os.path.realpath(state, strict=True))
    validate_directory(canonical)
    material = str(canonical).encode("utf-8", errors="strict") + b"\0" + str(port).encode("ascii")
    fingerprint = hashlib.sha256(material).hexdigest()[:20]
    path = temporary_base() / ("cmgw-" + fingerprint) / "s"
    if len(os.fsencode(path)) >= 104:
        raise ValueError("Protected local transport path is too long")
    return path


def validate_socket(path):
    validate_directory(path.parent, exact=True)
    info = path.lstat()
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        raise ValueError("Local transport socket must be private and user-owned")
    return info


def peer_uid(connection):
    """Darwin's documented getpeereid uses unsigned 32-bit uid_t/gid_t."""
    if sys.platform != "darwin":
        raise OSError(errno.ENOTSUP, "Protected peer identity requires Darwin")
    try:
        function = ctypes.CDLL(None, use_errno=True).getpeereid
    except (AttributeError, OSError):
        raise OSError(errno.ENOTSUP, "Protected peer identity unavailable") from None
    function.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
    function.restype = ctypes.c_int
    uid, gid = ctypes.c_uint32(), ctypes.c_uint32()
    if function(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
        raise OSError(ctypes.get_errno() or errno.EACCES, "Protected peer identity failed")
    return uid.value


def require_peer(connection):
    if peer_uid(connection) != os.getuid():
        raise OSError(errno.EACCES, "Local transport peer rejected")


class LocalHTTPConnection(http.client.HTTPConnection):
    """The authority is HTTP metadata only; connect never opens a TCP socket."""
    def __init__(self, state, port, timeout=50):
        super().__init__("127.0.0.1", port, timeout=timeout)
        self.state = state

    def connect(self):
        path = gateway_path(self.state, self.port)
        validate_socket(path)
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.settimeout(self.timeout)
            connection.connect(str(path))
            require_peer(connection)
            self.sock = connection
        except BaseException:
            connection.close()
            raise
