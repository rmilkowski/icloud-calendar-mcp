# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Local credential file handling. Never return credential contents in diagnostics."""

import os
from pathlib import Path
import secrets
import stat

DEFAULT_STATE = Path.home() / "Library/Application Support/Private Calendar MCP"


def private_directory(path):
    path = Path(path).expanduser().absolute()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("State directory must be owned by this user with mode 0700")
    return path


RESOURCES = ("calendar", "reminders")
TOKEN_FILES = {"calendar": "gateway.token", "reminders": "reminders.token"}


def resource_name(resource):
    if type(resource) is not str or resource not in RESOURCES:
        raise ValueError("Select exactly one supported resource")
    return resource


def read_token(state, resource="calendar"):
    resource = resource_name(resource)
    state = private_directory(state)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = os.open(state / TOKEN_FILES[resource], flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise ValueError("Credential must be a private, user-owned regular file with mode 0600")
        data = os.read(descriptor, 257)
        if len(data) != 64 or any(c not in b"0123456789abcdef" for c in data):
            raise ValueError("Invalid local credential file; initialize a new credential locally")
        return data.decode("ascii")
    finally:
        os.close(descriptor)


def initialize(state, resource="calendar"):
    resource = resource_name(resource)
    state = private_directory(state)
    try:
        descriptor = os.open(state / TOKEN_FILES[resource], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        read_token(state, resource)
        return state
    try:
        os.write(descriptor, secrets.token_hex(32).encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(state, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return state
