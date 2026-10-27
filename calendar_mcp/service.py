# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Opt-in Aqua launch agents and conservative, metadata-only recovery.

No calendar operation is submitted here. Recovery restarts transports, never MCP
requests; the native journal remains the authority for uncertain writes.
"""

import fcntl
import hashlib
from functools import wraps
import http.client
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import shlex
import stat
import subprocess
import sys
import tempfile
import time

from .adapter import GatewayClient
from .launch_services import bundle_for_helper
from .security import DEFAULT_STATE, private_directory

GATEWAY = "local.calendar-mcp.gateway"
MONITOR = "local.calendar-mcp.monitor"
LIMIT = 128 * 1024
GRACE = 120
BUDGET = 3


def _read(path, limit=LIMIT):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise ValueError("Service files must be private owned regular files")
        data = os.read(descriptor, limit + 1)
        if len(data) > limit:
            raise ValueError("Service file too large")
        return data
    finally:
        os.close(descriptor)


def _write(path, data):
    # Same private directory, exclusive temporary file and atomic replacement.
    descriptor, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as sink:
            sink.write(data)
            sink.flush()
            os.fsync(sink.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def _json_write(path, value):
    _write(path, json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode())


def _directory(state):
    return private_directory(private_directory(state) / "service")


def _locked(function):
    @wraps(function)
    def locked(first, *args, **kwargs):
        state = first.state_dir if function.__name__ == "render" else first
        descriptor = os.open(_directory(state) / "lifecycle.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise ValueError("Unsafe service lifecycle lock")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if function.__name__ == "monitor":
                    return 0
                raise ValueError("Another service lifecycle operation is active") from None
            return function(first, *args, **kwargs)
        finally:
            os.close(descriptor)
    return locked


def _absolute(value, executable=False):
    path = Path(value).expanduser().resolve(strict=True)
    if executable and (not path.is_file() or not os.access(path, os.X_OK)):
        raise ValueError("Service executable is unavailable")
    return str(path)


def load_config(state):
    directory = _directory(state)
    config = json.loads(_read(directory / "config.json"))
    keys = {"version", "repo", "python", "helper", "state", "port", "backend", "tunnel_client",
            "tunnel_id", "tunnel_env", "profile_dir", "alias", "profile", "notify"}
    if (not isinstance(config, dict) or set(config) - {"enable_reminders"} != keys or config["version"] != 1
            or ("enable_reminders" in config and type(config["enable_reminders"]) is not bool)):
        raise ValueError("Invalid service config")
    if (type(config["port"]) is not int or not 1 <= config["port"] <= 65535
            or config["backend"] != "eventkit" or type(config["notify"]) is not bool):
        raise ValueError("Invalid service config")
    for key in ("repo", "python", "helper", "state", "tunnel_client", "tunnel_env", "profile_dir"):
        if not isinstance(config[key], str) or not Path(config[key]).is_absolute():
            raise ValueError("Service paths must be absolute")
    if Path(config["state"]) != Path(state).expanduser().absolute():
        raise ValueError("Service state mismatch")
    for key in ("alias", "profile"):
        if not isinstance(config[key], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", config[key]):
            raise ValueError("Invalid tunnel alias/profile")
    if not isinstance(config["tunnel_id"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", config["tunnel_id"]):
        raise ValueError("Set the existing tunnel ID locally")
    return config


def runtime_environment(path):
    """Parse one literal assignment; never source shell code or log its contents."""
    private_directory(Path(path).parent)
    raw = _read(path, 16 * 1024).decode("utf-8")
    assignments = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if not line.startswith("CONTROL_PLANE_API_KEY="):
            raise ValueError("Unexpected runtime credential assignment")
        value = line.partition("=")[2]
        if any(character in value for character in ("$", "`", "\\", ";", "\x00")):
            raise ValueError("Runtime credential must be a literal assignment")
        pieces = shlex.split(value, comments=True, posix=True)
        if len(pieces) != 1 or not pieces[0] or any(c.isspace() for c in pieces[0]):
            raise ValueError("Invalid runtime credential assignment")
        assignments.append(pieces[0])
    if len(assignments) != 1:
        raise ValueError("One runtime credential assignment required")
    return {"CONTROL_PLANE_API_KEY": assignments[0]}


def environment():
    # launchd and the tunnel get a deterministic environment, no shell startup.
    return {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/tmp", "LANG": "en_US.UTF-8"}


def run(command, *, timeout=15, extra_env=None):
    """Bound captured child output and wall time; callers never print it raw."""
    child_env = environment()
    child_env.update(extra_env or {})
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env=child_env, close_fds=True,
                             cwd=Path(__file__).resolve().parent.parent)
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Service child timeout")
            for key, _ in selector.select(min(remaining, 0.1)):
                chunk = os.read(key.fileobj.fileno(), 16384)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(chunk)
                    if len(output) > LIMIT:
                        raise ValueError("Service child output limit")
        try:
            child.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise TimeoutError("Service child timeout") from None
        return child.returncode, bytes(output)
    finally:
        selector.close()
        child.stdout.close()
        if child.poll() is None:
            child.kill()  # Only this child, never a reported/reused native PID.
            child.wait(timeout=2)


def plists(config):
    base = [config["python"], "-m", "calendar_mcp"]
    directory = Path(config["state"]) / "service"
    common = {"RunAtLoad": True, "LimitLoadToSessionType": "Aqua", "ProcessType": "Background",
              "WorkingDirectory": config["repo"], "Umask": 0o077,
              "EnvironmentVariables": environment(), "KeepAlive": False}
    gateway = dict(common, Label=GATEWAY, ProgramArguments=base + ["serve", "--helper", config["helper"],
        "--backend", "eventkit", "--state-dir", config["state"], "--port", str(config["port"])],
        StandardOutPath=str(directory / "gateway-launch.log"), StandardErrorPath=str(directory / "gateway-launch.log"))
    if config.get("enable_reminders", False):
        gateway["ProgramArguments"].append("--enable-reminders")
    monitor = dict(common, Label=MONITOR, ProgramArguments=base + ["service", "_monitor", "--state-dir", config["state"]],
        StartInterval=60, StandardOutPath=str(directory / "monitor-launch.log"),
        StandardErrorPath=str(directory / "monitor-launch.log"))
    return {GATEWAY: gateway, MONITOR: monitor}


@_locked
def render(args):
    directory = _directory(args.state_dir)
    if (directory / "installed.json").exists():
        raise ValueError("Uninstall the service before replacing its reviewed configuration")
    config = {"version": 1, "repo": str(Path(__file__).resolve().parent.parent),
              "python": _absolute(args.python, True), "helper": _absolute(args.helper, True),
              "state": str(Path(args.state_dir).expanduser().absolute()), "port": args.port, "backend": "eventkit",
              "tunnel_client": _absolute(args.tunnel_client, True), "tunnel_id": args.tunnel_id,
              "tunnel_env": str(args.tunnel_env.expanduser().absolute()), "profile_dir": _absolute(args.profile_dir),
              "alias": args.alias, "profile": args.profile, "notify": not args.no_notify}
    if getattr(args, "enable_reminders", False):
        config["enable_reminders"] = True
    bundle_for_helper(config["helper"])
    _json_write(directory / "config.json", config)
    config = load_config(args.state_dir)
    for label, value in plists(config).items():
        _write(directory / (label + ".plist"), plistlib.dumps(value))
    print(json.dumps({"service": "staged", "active": False, "directory": str(directory),
                      "review": ["config.json", GATEWAY + ".plist", MONITOR + ".plist"]}))
    return 0


class System:
    def __init__(self, config, runner=run):
        self.config = config
        self.run = runner
        self.domain = "gui/" + str(os.getuid())

    def launch(self, operation, label):
        return self.run(["/bin/launchctl", operation, self.domain + "/" + label])[0] == 0

    def session(self):
        """Opaque boot/login episode identity; never record command output."""
        try:
            boot_code, boot = self.run(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], timeout=5)
            audit_code, audit = self.run(["/usr/bin/id", "-A"], timeout=5)
            boot = boot.decode("ascii").strip()
            audit = audit.decode("ascii").strip()
            audit_sessions = [line for line in audit.splitlines() if line.startswith("asid=")]
            if (boot_code or audit_code or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", boot)
                    or len(audit_sessions) != 1 or not re.fullmatch(r"asid=[0-9]+", audit_sessions[0])):
                return None
            return hashlib.sha256((boot.lower() + ":" + audit_sessions[0]).encode()).hexdigest()
        except (OSError, ValueError, TimeoutError):
            return None

    def gateway(self):
        try:
            reply = GatewayClient(self.config["state"], self.config["port"]).status(timeout=5)
            if not isinstance(reply, dict) or reply.get("gateway") != "reachable":
                return "indeterminate"
            native = reply.get("native", {})
            if not isinstance(native, dict) or ("error" in native and not isinstance(native["error"], dict)):
                return "indeterminate"
            if native.get("error", {}).get("code") == "broker_busy":
                return "busy"
            if "error" in native:
                return "native_unavailable" if native["error"].get("code") in ("broker_unavailable", "outcome_unknown") else "indeterminate"
            if native.get("backend_mode") != "eventkit":
                return "indeterminate"
            authorization = native.get("authorization_status")
            return "healthy" if authorization == "full_access" else "permission" if authorization in ("denied", "not_determined", "restricted", "write_only", "unknown") else "indeterminate"
        except ConnectionRefusedError:
            return "down"
        except TimeoutError:
            return "timeout"
        except (OSError, ValueError, http.client.HTTPException):
            return "indeterminate"

    def tunnel(self):
        try:
            code, output = self.run([self.config["tunnel_client"], "runtimes", "status", self.config["alias"], "--json"])
            if code:
                return "indeterminate"
            value = json.loads(output)
            if not isinstance(value, dict) or any(value.get(remote) != self.config[local] for remote, local in
                    (("alias", "alias"), ("tunnel_id", "tunnel_id"), ("profile_name", "profile"), ("profile_dir", "profile_dir"))):
                return "ownership_conflict"
            return tunnel_health(value)
        except (OSError, ValueError, TimeoutError):
            return "indeterminate"

    def recover(self, component):
        if component == "gateway":
            # Never kill a responsive busy/indeterminate broker. The monitor
            # invokes this only for confirmed absence or failed native channel.
            return self.run(["/bin/launchctl", "kickstart", "-k", self.domain + "/" + GATEWAY])[0] == 0
        config = self.config
        if self.tunnel() not in ("down", "unhealthy"):
            return False
        code, _ = self.run([config["tunnel_client"], "runtimes", "stop", config["alias"]])
        if code:
            return False
        command = [config["tunnel_client"], "runtimes", "connect", "--alias", config["alias"],
                   "--profile", config["profile"], "--profile-dir", config["profile_dir"],
                   "--runtime-api-key", "env:CONTROL_PLANE_API_KEY", "--tunnel-id", config["tunnel_id"],
                   "--mcp-command", shlex.join([config["python"], "-m", "calendar_mcp", "stdio",
                    "--state-dir", config["state"], "--port", str(config["port"])])]
        return self.run(command, timeout=30, extra_env=runtime_environment(config["tunnel_env"]))[0] == 0

    def notify(self, component, event):
        if self.config["notify"]:
            # Only fixed enum strings enter AppleScript; no remote text or secrets.
            message = "Calendar MCP " + component + ": " + event
            self.run(["/usr/bin/osascript", "-e", 'display notification "' + message + '" with title "Calendar MCP"'], timeout=5)


def tunnel_health(value):
    # Strict v0.0.17 status contract; unknown versions/shapes fail closed.
    if not isinstance(value, dict):
        return "indeterminate"
    if type(value.get("process_running")) is not bool:
        return "indeterminate"
    if type(value.get("healthy")) is not bool or type(value.get("ready")) is not bool:
        return "indeterminate"
    if value["process_running"] is False:
        local = value.get("local", {})
        if not isinstance(local, dict):
            return "indeterminate"
        live_ui = local.get("live_admin_ui", {})
        if not isinstance(live_ui, dict):
            return "indeterminate"
        return "down" if (value.get("runtime_state") == "stopped" and not value["healthy"]
                          and not value["ready"] and live_ui.get("found") is not True) else "indeterminate"
    poll = value.get("control_plane_poll_health", {})
    if not isinstance(poll, dict):
        return "indeterminate"
    poll_state = poll.get("state", "")
    return "healthy" if value["healthy"] and value["ready"] and poll_state in ("", "unknown", "healthy", "direct") else "unhealthy"


def _ownership(config):
    return {"version": 1, "config_sha256": hashlib.sha256(json.dumps(config, sort_keys=True,
            separators=(",", ":")).encode()).hexdigest()}


def _event(directory, system, component, event, now, notify=True):
    path = directory / "monitor.log"
    if path.exists() and len(_read(path, 1024 * 1024)) > 256 * 1024:
        os.replace(path, directory / "monitor.log.1")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise ValueError("Unsafe monitor log")
        os.write(descriptor, (json.dumps({"time": int(now), "component": component, "event": event}) + "\n").encode())
    finally:
        os.close(descriptor)
    try:
        if notify:
            system.notify(component, event)
    except (OSError, ValueError, TimeoutError):
        pass


def check(config, directory, system, now):
    path = directory / "monitor-state.json"
    state = json.loads(_read(path)) if path.exists() else {"version": 1, "started": now, "components": {}}
    validate_monitor_state(state)
    session = getattr(system, "session", lambda: None)()
    if session is not None and session != state.get("session"):
        state.update(session=session, episode_started=now, tunnel_start_pending=True, tunnel_start_attempted=False)
        for item in state["components"].values():
            item["failures"] = 0
            item.pop("healthy_since", None)
        # New GUI/boot episodes reset observations, never the durable budget,
        # backoff, existing incidents or earlier unknown execution history.
        _json_write(path, state)
    gateway = system.gateway()
    observations = {"gateway": gateway, "tunnel": system.tunnel()}
    for component, health in observations.items():
        item = state["components"].setdefault(component, {"failures": 0, "attempts": [], "next": 0, "incident": None})
        item.setdefault("backoff", 0)
        # Future timestamps remain consumed after wall-clock rollback.
        item["attempts"] = [stamp for stamp in item["attempts"] if now - stamp < 3600]
        if health == "healthy":
            if component == "tunnel":
                state["tunnel_start_pending"] = False
            item["healthy_since"] = item.get("healthy_since", now)
            if item["incident"] is not None and now - item["healthy_since"] >= GRACE:
                item["incident"] = None
                _json_write(path, state)
                _event(directory, system, component, "recovered", now)
            item["failures"] = 0
            if now - item["healthy_since"] >= GRACE:
                item["next"] = 0
                item["backoff"] = 0
        elif health == "busy":
            # Genuine native activity is neither a failure nor a restart trigger.
            item["failures"] = 0
        else:
            item.pop("healthy_since", None)
            item["failures"] += 1
            if item["failures"] < 3 or now - state.get("episode_started", state["started"]) < GRACE or now < item["next"]:
                continue
            startup = (component == "tunnel" and session is not None and session == state.get("session")
                       and state.get("tunnel_start_pending") is True and state.get("tunnel_start_attempted") is False
                       and health == "down" and gateway == "healthy" and len(item["attempts"]) < BUDGET)
            if item["incident"] is None and not startup:
                item["incident"] = health
                _json_write(path, state)
                _event(directory, system, component, health, now)
            eligible = health in ("down", "native_unavailable", "unhealthy", "timeout")
            if component == "tunnel" and gateway != "healthy":
                eligible = False
            if not eligible or len(item["attempts"]) >= BUDGET:
                continue
            # Persist the budget and grace BEFORE any command. Timeout/crash
            # may have started a process; never erase the consumed attempt.
            item["attempts"].append(now)
            item["next"] = now + max(GRACE, min(900, 60 * 2 ** item["backoff"]))
            item["backoff"] = min(4, item["backoff"] + 1)
            if startup:
                state["tunnel_start_attempted"] = True
            _json_write(path, state)
            if startup:
                _event(directory, system, component, "startup_requested", now, notify=False)
            try:
                ok = system.recover(component)
            except (OSError, ValueError, TimeoutError):
                ok = False
            _event(directory, system, component, "restart_requested" if ok else "restart_failed", now, notify=False)
    state["last_check"] = now
    state["observations"] = observations
    _json_write(path, state)
    return state


def validate_monitor_state(state):
    def stamp(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    if (not isinstance(state, dict) or state.get("version") != 1 or not stamp(state.get("started"))
            or not isinstance(state.get("components"), dict) or not set(state["components"]) <= {"gateway", "tunnel"}):
        raise ValueError("Invalid monitor state")
    if (any(key in state and type(state[key]) is not bool for key in ("tunnel_start_pending", "tunnel_start_attempted"))
            or ("episode_started" in state and not stamp(state["episode_started"]))
            or ("session" in state and (not isinstance(state["session"], str) or not re.fullmatch(r"[a-f0-9]{64}", state["session"])))):
        raise ValueError("Invalid monitor episode state")
    for value in state["components"].values():
        if (not isinstance(value, dict) or type(value.get("failures")) is not int or value["failures"] < 0
                or not isinstance(value.get("attempts"), list) or len(value["attempts"]) > BUDGET
                or not all(stamp(t) for t in value["attempts"]) or not stamp(value.get("next"))
                or type(value.get("backoff", 0)) is not int or not 0 <= value.get("backoff", 0) <= 4
                or value.get("incident") not in (None, "down", "permission", "indeterminate", "timeout", "native_unavailable", "unhealthy", "ownership_conflict")
                or ("healthy_since" in value and not stamp(value["healthy_since"]))):
            raise ValueError("Invalid monitor state")


@_locked
def monitor(state, *, system=None, now=None):
    config = load_config(state)
    directory = _directory(state)
    installed = json.loads(_read(directory / "installed.json"))
    if installed != _ownership(config):
        raise ValueError("Service is not installed")
    descriptor = os.open(directory / "monitor.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise ValueError("Unsafe monitor lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        actual = system or System(config)
        if not actual.launch("print", GATEWAY):
            raise ValueError("Gateway service is not registered")
        try:
            if not (directory / "monitor-state.json").exists():
                raise ValueError("Monitor state missing")
            check(config, directory, actual, time.time() if now is None else now)
        except (ValueError, TypeError, KeyError):
            marker = directory / "monitor-error.json"
            if not marker.exists():
                _json_write(marker, {"error": "monitor_state_invalid"})
                _event(directory, actual, "monitor", "state_invalid", time.time() if now is None else now)
            raise ValueError("Monitor state invalid; recovery suspended") from None
    finally:
        os.close(descriptor)
    return 0


@_locked
def install(state, *, system=None):
    config = load_config(state)
    directory = _directory(state)
    actual = system or System(config)
    if (directory / "installed.json").exists():
        raise ValueError("Service is already installed")
    # Explicit cutover is required; an installer never adopts a live process.
    if actual.gateway() != "down" or actual.tunnel() != "down":
        raise ValueError("Stop the existing gateway and managed tunnel before service installation")
    for label in (GATEWAY, MONITOR):
        if actual.launch("print", label):
            raise ValueError("A service with this label is already loaded")
        if plistlib.loads(_read(directory / (label + ".plist"))) != plists(config)[label]:
            raise ValueError("Staged plist/config mismatch; render again")
    agents = Path.home() / "Library/LaunchAgents"
    agents.mkdir(mode=0o700, parents=True, exist_ok=True)
    if agents.is_symlink() or agents.stat().st_uid != os.getuid():
        raise ValueError("Unsafe LaunchAgents directory")
    installed_paths = []
    try:
        for label in (GATEWAY, MONITOR):
            destination = agents / (label + ".plist")
            if destination.exists() or destination.is_symlink():
                raise ValueError("Existing launch agent must be reviewed manually")
            _write(destination, _read(directory / (label + ".plist")))
            installed_paths.append(destination)
        # Log files are protected before launchd opens them.
        for name in ("gateway-launch.log", "monitor-launch.log"):
            if not (directory / name).exists():
                _write(directory / name, b"")
            _read(directory / name, 1024 * 1024)
        _json_write(directory / "installed.json", _ownership(config))
        _json_write(directory / "monitor-state.json", {"version": 1, "started": time.time(), "components": {}})
        for destination in installed_paths:
            if actual.run(["/bin/launchctl", "bootstrap", actual.domain, str(destination)])[0]:
                raise ValueError("Service registration failed")
    except BaseException:
        cleanup_failed = False
        for label in (MONITOR, GATEWAY):
            try:
                if not actual.launch("bootout", label) and actual.launch("print", label):
                    cleanup_failed = True
            except (OSError, ValueError, TimeoutError):
                cleanup_failed = True
        if cleanup_failed:
            # Retain the exact ownership/config/plists so a later uninstall
            # can finish safely; never abandon a possibly running service.
            raise ValueError("Service registration failed and cleanup is incomplete; retry uninstall") from None
        (directory / "installed.json").unlink(missing_ok=True)
        for destination in installed_paths:
            destination.unlink(missing_ok=True)
        raise
    print(json.dumps({"service": "installed", "active": True, "session": "Aqua", "health": "pending_monitor"}))
    return 0


@_locked
def uninstall(state, *, system=None):
    config = load_config(state)
    directory = _directory(state)
    if not (directory / "installed.json").exists() or json.loads(_read(directory / "installed.json")) != _ownership(config):
        raise ValueError("Service is not installed")
    actual = system or System(config)
    for label in (MONITOR, GATEWAY):
        path = Path.home() / "Library/LaunchAgents" / (label + ".plist")
        if path.exists() and plistlib.loads(_read(path)) != plists(config)[label]:
            raise ValueError("Installed launch agent changed; review manually")
    # Stop monitor before removing the gateway or its managed tunnel.
    if not actual.launch("bootout", MONITOR) and actual.launch("print", MONITOR):
        raise ValueError("Monitor could not be stopped")
    if actual.tunnel() not in ("down", "healthy", "unhealthy"):
        raise ValueError("Tunnel ownership or status uncertain; stop safely before uninstalling")
    if actual.run([config["tunnel_client"], "runtimes", "stop", config["alias"]])[0]:
        raise ValueError("Managed tunnel could not be stopped")
    if not actual.launch("bootout", GATEWAY) and actual.launch("print", GATEWAY):
        raise ValueError("Gateway could not be stopped")
    for label in (MONITOR, GATEWAY):
        path = Path.home() / "Library/LaunchAgents" / (label + ".plist")
        if path.exists():
            if plistlib.loads(_read(path)) != plists(config)[label]:
                raise ValueError("Installed launch agent changed; review manually")
            path.unlink()
    (directory / "installed.json").unlink()
    print(json.dumps({"service": "uninstalled", "credentials_and_native_state": "preserved"}))
    return 0


@_locked
def status(state):
    directory = _directory(state)
    config = load_config(state)
    installed = (directory / "installed.json").exists()
    result = {"service": "installed" if installed else "staged", "active": False}
    if installed:
        if json.loads(_read(directory / "installed.json")) != _ownership(config):
            raise ValueError("Service ownership/config mismatch")
        actual = System(config)
        result.update(gateway_registered=actual.launch("print", GATEWAY), monitor_registered=actual.launch("print", MONITOR),
                      gateway=actual.gateway(), tunnel=actual.tunnel())
        result["active"] = result["gateway_registered"] and result["monitor_registered"]
        if (directory / "monitor-state.json").exists():
            saved = json.loads(_read(directory / "monitor-state.json"))
            validate_monitor_state(saved)
            result["last_check"] = saved.get("last_check")
            result["monitor_stale"] = not isinstance(saved.get("last_check"), (int, float)) or time.time() - saved["last_check"] > 180
            result["restart_attempts_last_hour"] = {key: sum(time.time() - t < 3600 for t in value.get("attempts", []))
                                                    for key, value in saved.get("components", {}).items()}
    print(json.dumps(result))
    return 0


def add_parser(sub):
    parser = sub.add_parser("service", help="Opt-in Studio startup and metadata-only monitoring")
    commands = parser.add_subparsers(dest="service_command", required=True)
    for command in ("render", "install", "status", "uninstall", "_monitor"):
        item = commands.add_parser(command)
        item.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
        if command == "render":
            item.add_argument("--helper", type=Path, required=True)
            item.add_argument("--python", type=Path, default=Path(sys.executable))
            item.add_argument("--tunnel-client", type=Path, required=True)
            item.add_argument("--tunnel-id", required=True)
            item.add_argument("--tunnel-env", type=Path, required=True)
            item.add_argument("--profile-dir", type=Path, required=True)
            item.add_argument("--alias", default="calendar-studio")
            item.add_argument("--profile", default="calendar-studio")
            item.add_argument("--port", type=int, default=18765)
            item.add_argument("--no-notify", action="store_true")
            item.add_argument("--enable-reminders", action="store_true", help="Opt in to Reminders for the rendered gateway; no OS permission request")


def dispatch(args):
    if args.service_command == "render":
        return render(args)
    return {"install": install, "status": status, "uninstall": uninstall, "_monitor": monitor}[args.service_command](args.state_dir)
