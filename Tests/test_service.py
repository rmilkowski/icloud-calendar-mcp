# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Service tests use temporary state, fake launchctl/tunnel and synthetic HTTP."""

from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import shlex
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from calendar_mcp import service
from calendar_mcp.__main__ import main
from calendar_mcp.protocol import Protocol
from calendar_mcp.security import initialize
from calendar_mcp.server import GatewayServer


class FakeSystem:
    def __init__(self, gateway="healthy", tunnel="healthy"):
        self.gateway_health = gateway
        self.tunnel_health = tunnel
        self.reminders_tunnel_health = "healthy"
        self.restarts = []
        self.events = []
        self.commands = []
        self.registered = {service.GATEWAY, service.MONITOR}
        self.domain = "gui/test"
        self.recovery_result = True
        self.episode = None

    def session(self):
        return self.episode

    def gateway(self):
        return self.gateway_health

    def tunnel(self, component="tunnel"):
        return self.reminders_tunnel_health if component == "reminders_tunnel" else self.tunnel_health

    def recover(self, component):
        self.restarts.append(component)
        return self.recovery_result

    def notify(self, component, event):
        self.events.append((component, event))

    def launch(self, operation, label):
        self.commands.append((operation, label))
        if operation == "print":
            return label in self.registered
        self.registered.discard(label)
        return True

    def run(self, command, **kwargs):
        self.commands.append(command)
        if command[1] == "bootstrap":
            self.registered.add(Path(command[-1]).stem)
        return 0, b""


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home_patch = patch.object(Path, "home", return_value=self.root)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.state = initialize(self.root / "private state")
        self.directory = service._directory(self.state)
        self.env = self.root / "runtime.env"
        service._write(self.env, b"CONTROL_PLANE_API_KEY='synthetic-runtime-secret'\n")
        bundle = self.root / "Calendar MCP Helper.app"
        helper = bundle / "Contents/MacOS/CalendarHelper"
        helper.parent.mkdir(parents=True)
        helper.write_text("#!/bin/sh\nexit 0\n")
        helper.chmod(0o700)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "CalendarHelper",
            "CFBundleIdentifier": "local.calendar-mcp.helper", "CFBundlePackageType": "APPL"}))
        profiles = self.root / "profiles"
        profiles.mkdir(mode=0o700)
        self.config = {"version": 1, "repo": str(Path(__file__).resolve().parent.parent), "python": sys.executable,
            "helper": str(helper), "state": str(self.state), "port": 18765, "backend": "eventkit",
            "tunnel_client": "/usr/bin/true", "tunnel_id": "synthetic-id", "tunnel_env": str(self.env),
            "profile_dir": str(profiles), "alias": "fixture", "profile": "fixture", "notify": True}
        self.write_profile(self.config, "tunnel")
        service._json_write(self.directory / "config.json", self.config)
        for label, value in service.plists(self.config).items():
            service._write(self.directory / (label + ".plist"), plistlib.dumps(value))

    def write_profile(self, config, component):
        service._json_write(Path(config["profile_dir"]) / (config["profile"] + ".yaml"), {
            "config_version": 1, "control_plane": {"tunnel_id": config["tunnel_id"],
                "api_key": "env:CONTROL_PLANE_API_KEY"}, "mcp": {"commands": [{
                    "channel": "main", "command": shlex.join(service.adapter_command(config, component))}]}})

    def tearDown(self):
        self.temp.cleanup()

    def activate_fixture(self):
        service._json_write(self.directory / "installed.json", service._ownership(self.config))

    def check(self, system, times):
        value = None
        for now in times:
            value = service.check(self.config, self.directory, system, now)
        return value

    def test_render_is_reviewable_and_never_registers_services(self):
        with patch.object(service, "run", side_effect=AssertionError("No child allowed")), redirect_stdout(io.StringIO()) as output:
            result = main(["service", "render", "--state-dir", str(self.state), "--helper", self.config["helper"],
                "--tunnel-client", "/usr/bin/true", "--tunnel-id", "synthetic-id", "--tunnel-env", str(self.env),
                "--profile-dir", self.config["profile_dir"]])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["active"], False)
        self.assertFalse((self.directory / "installed.json").exists())
        self.assertEqual(stat.S_IMODE((self.directory / "config.json").stat().st_mode), 0o600)

    def test_plists_have_absolute_commands_aqua_and_separate_monitor(self):
        plists = service.plists(self.config)
        for value in plists.values():
            self.assertTrue(Path(value["ProgramArguments"][0]).is_absolute())
            self.assertEqual(value["WorkingDirectory"], self.config["repo"])
            self.assertEqual(value["LimitLoadToSessionType"], "Aqua")
            self.assertTrue(value["RunAtLoad"])
            self.assertFalse(value["KeepAlive"])
            encoded = plistlib.dumps(value)
            self.assertNotIn(b"synthetic-runtime-secret", encoded)
            self.assertNotIn(b"CONTROL_PLANE_API_KEY", encoded)
        self.assertEqual(plists[service.MONITOR]["StartInterval"], 60)
        self.assertNotIn("AbandonProcessGroup", plists[service.MONITOR])

    def test_reminders_service_opt_in_is_explicit_persistent_and_strict(self):
        args = ["service", "render", "--state-dir", str(self.state), "--helper", self.config["helper"],
                "--tunnel-client", "/usr/bin/true", "--tunnel-id", "synthetic-id", "--tunnel-env", str(self.env),
                "--profile-dir", self.config["profile_dir"]]
        with patch.object(service, "run", side_effect=AssertionError("No child allowed")), redirect_stdout(io.StringIO()):
            self.assertEqual(main(args), 0)
            legacy = service.load_config(self.state)
            self.assertNotIn("enable_reminders", legacy)
            original = service.plists(legacy)
            self.assertNotIn("--enable-reminders", original[service.GATEWAY]["ProgramArguments"])
            self.assertEqual(main([*args, "--enable-reminders"]), 0)
        enabled = service.load_config(self.state)
        self.assertIs(enabled["enable_reminders"], True)
        enabled_plists = service.plists(enabled)
        self.assertEqual(enabled_plists[service.GATEWAY]["ProgramArguments"],
                         original[service.GATEWAY]["ProgramArguments"] + ["--enable-reminders"])
        self.assertEqual(enabled_plists[service.MONITOR], original[service.MONITOR])
        self.assertNotIn("--authorize-reminders", enabled_plists[service.GATEWAY]["ProgramArguments"])
        for invalid in (None, 0, 1, "true", []):
            service._json_write(self.directory / "config.json", {**enabled, "enable_reminders": invalid})
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                service.load_config(self.state)
        service._json_write(self.directory / "config.json", {**enabled, "enable_reminders": False})
        self.assertEqual(service.plists(service.load_config(self.state)), original)

    def test_reminders_permission_does_not_change_calendar_monitor_health(self):
        class Client:
            def __init__(self, state, port):
                pass

            def status(self, timeout):
                return {"gateway": "reachable", "native": {"backend_mode": "eventkit", "authorization_status": "full_access"},
                        "reminders": {"authorization_status": "denied"}}

        with patch("calendar_mcp.service.GatewayClient", Client):
            self.assertEqual(service.System(self.config).gateway(), "healthy")

    def enable_reminders_tunnel(self):
        profiles = self.root / "reminder profiles"
        profiles.mkdir(mode=0o700, exist_ok=True)
        self.config.update(enable_reminders=True, reminders_tunnel={
            "tunnel_id": "synthetic-reminders-id", "tunnel_env": str(self.env),
            "profile_dir": str(profiles), "alias": "reminders-fixture", "profile": "fixture"})
        self.write_profile(service.tunnel_config(self.config, "reminders_tunnel"), "reminders_tunnel")
        service._json_write(self.directory / "config.json", self.config)
        for label, value in service.plists(self.config).items():
            service._write(self.directory / (label + ".plist"), plistlib.dumps(value))

    def test_render_optional_reminders_runtime_requires_complete_reviewed_options(self):
        profiles = self.root / "reminders-profile"
        profiles.mkdir(mode=0o700)
        args = ["service", "render", "--state-dir", str(self.state), "--helper", self.config["helper"],
            "--tunnel-client", "/usr/bin/true", "--tunnel-id", self.config["tunnel_id"],
            "--tunnel-env", str(self.env), "--profile-dir", self.config["profile_dir"]]
        reminder_args = ["--reminders-tunnel-id", "reminder-id", "--reminders-tunnel-env", str(self.env),
            "--reminders-profile-dir", str(profiles), "--reminders-alias", "reminders", "--reminders-profile", "fixture"]
        with patch.object(service, "run", side_effect=AssertionError("No child allowed")), redirect_stdout(io.StringIO()):
            self.assertEqual(main(args + reminder_args), 1)
            self.assertEqual(main(args + ["--enable-reminders", "--reminders-alias", "reminders"]), 1)
            self.assertEqual(main(args + ["--enable-reminders"] + reminder_args), 0)
        configured = service.load_config(self.state)
        self.assertEqual(configured["reminders_tunnel"]["alias"], "reminders")
        self.assertEqual(configured["reminders_tunnel"]["tunnel_env"], str(self.env))
        self.assertEqual(set(service.plists(configured)), {service.GATEWAY, service.MONITOR})

    def test_reminders_tunnel_config_is_exact_and_distinct(self):
        self.enable_reminders_tunnel()
        self.assertEqual(service.load_config(self.state), self.config)
        original = self.config["reminders_tunnel"]
        invalids = [None, [], {**original, "extra": True},
                    {key: value for key, value in original.items() if key != "alias"}]
        invalids += [{**original, key: self.config[key]} for key in ("alias", "tunnel_id", "profile_dir")]
        invalids += [{**original, key: False} for key in original]
        for invalid in invalids:
            with self.subTest(invalid=invalid):
                service._json_write(self.directory / "config.json", {**self.config, "reminders_tunnel": invalid})
                with self.assertRaises(ValueError):
                    service.load_config(self.state)
        service._json_write(self.directory / "config.json", {**self.config, "enable_reminders": False})
        with self.assertRaises(ValueError):
            service.load_config(self.state)
        alias = self.root / "profile-alias"
        alias.symlink_to(self.config["profile_dir"], target_is_directory=True)
        service._json_write(self.directory / "config.json", {**self.config,
            "reminders_tunnel": {**original, "profile_dir": str(alias)}})
        with self.assertRaises(ValueError):
            service.load_config(self.state)

    def test_reminders_runtime_command_is_fixed_scoped_without_second_gateway(self):
        self.enable_reminders_tunnel()
        calls = []
        def runner(command, **kwargs):
            calls.append((command, kwargs))
            if command[2] == "status":
                target = self.config["reminders_tunnel"]
                return 0, json.dumps({"alias": target["alias"], "tunnel_id": target["tunnel_id"],
                    "profile_name": target["profile"], "profile_dir": target["profile_dir"],
                    "process_running": False, "healthy": False, "ready": False, "runtime_state": "stopped"}).encode()
            return 0, b""
        self.assertTrue(service.System(self.config, runner).recover("reminders_tunnel"))
        command = calls[-1][0]
        self.assertEqual(command[command.index("--tunnel-id") + 1], "synthetic-reminders-id")
        import shlex
        adapter = shlex.split(command[command.index("--mcp-command") + 1])
        self.assertEqual(adapter[-2:], ["--resource", "reminders"])
        self.assertEqual(adapter.count("stdio"), 1)
        self.assertNotIn("serve", adapter)
        self.assertEqual(set(service.plists(self.config)), {service.GATEWAY, service.MONITOR})
        self.assertTrue(all("synthetic-runtime-secret" not in " ".join(c) for c, _ in calls))
        with self.assertRaises(ValueError):
            service.System(self.config, runner).recover("caller-resource")

    def test_reminders_profile_target_fails_closed_for_other_resources_or_unsafe_shape(self):
        self.enable_reminders_tunnel()
        config = service.tunnel_config(self.config, "reminders_tunnel")
        path = Path(config["profile_dir"]) / (config["profile"] + ".yaml")
        original = json.loads(service._read(path))
        self.assertTrue(service.fixed_profile_target(config, "reminders_tunnel"))
        changes = [
            {"commands": [{"channel": "main", "command": shlex.join(service.adapter_command(config, "tunnel"))}]},
            {"commands": original["mcp"]["commands"] * 2},
            {"commands": [{**original["mcp"]["commands"][0], "channel": "other"}]},
            {"commands": original["mcp"]["commands"], "servers": []},
            {"server_url": "http://127.0.0.1:1"}]
        for changed in changes:
            service._json_write(path, {**original, "mcp": changed})
            self.assertFalse(service.fixed_profile_target(config, "reminders_tunnel"))
        for raw in (b'{"config_version":1,"config_version":1}', b'{"x":NaN}',
                    b'mcp:\n  commands: []\n'):
            service._write(path, raw)
            with self.assertRaises(ValueError):
                service.fixed_profile_target(config, "reminders_tunnel")
        service._json_write(path, original)
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            service.fixed_profile_target(config, "reminders_tunnel")
        path.chmod(0o600)
        Path(config["profile_dir"]).chmod(0o755)
        with self.assertRaises(ValueError):
            service.fixed_profile_target(config, "reminders_tunnel")
        Path(config["profile_dir"]).chmod(0o700)

    def test_reminders_profile_requires_exact_canonical_shell_quoting(self):
        self.enable_reminders_tunnel()
        config = service.tunnel_config(self.config, "reminders_tunnel")
        config["state"] = str(self.root / "private$(id)`id`")
        self.write_profile(config, "reminders_tunnel")
        path = Path(config["profile_dir"]) / (config["profile"] + ".yaml")
        profile = json.loads(service._read(path))
        canonical = profile["mcp"]["commands"][0]["command"]
        self.assertTrue(service.fixed_profile_target(config, "reminders_tunnel"))
        for altered in (canonical.replace(shlex.quote(config["state"]), config["state"]),
                        canonical.replace(shlex.quote(config["state"]), '"' + config["state"] + '"')):
            # Parsing alone loses the shell quoting distinction. No command is executed.
            self.assertEqual(shlex.split(altered), service.adapter_command(config, "reminders_tunnel"))
            profile["mcp"]["commands"][0]["command"] = altered
            service._json_write(path, profile)
            self.assertFalse(service.fixed_profile_target(config, "reminders_tunnel"))

    def test_reminders_unavailable_or_ambiguous_gateway_never_restarts_runtime(self):
        self.enable_reminders_tunnel()
        for health in ("busy", "indeterminate", "native_unavailable", "down"):
            (self.directory / "monitor-state.json").unlink(missing_ok=True)
            fake = FakeSystem(gateway=health)
            fake.reminders_tunnel_health = "down"
            self.check(fake, [1000, 1060, 1120, 1240])
            self.assertNotIn("reminders_tunnel", fake.restarts)

    def test_reminders_restart_budget_and_calendar_permission_are_independent(self):
        self.enable_reminders_tunnel()
        fake = FakeSystem(gateway="permission", tunnel="unhealthy")
        fake.reminders_tunnel_health = "down"
        fake.episode = "a" * 64
        saved = self.check(fake, [1000, 1060, 1120, 1240, 1480, 1960])
        self.assertEqual(fake.restarts, ["reminders_tunnel"] * 3)
        self.assertEqual(len(saved["components"]["reminders_tunnel"]["attempts"]), 3)
        self.assertEqual(saved["components"]["tunnel"]["attempts"], [])
        self.assertEqual(saved["components"]["gateway"]["attempts"], [])
        fake.episode = "b" * 64
        saved = self.check(fake, [2100, 2160, 2220])
        self.assertEqual(len(fake.restarts), 3)
        self.assertTrue(saved["components"]["reminders_tunnel"]["start_pending"])

    def test_install_preserves_existing_monitor_history_and_refuses_corruption(self):
        self.enable_reminders_tunnel()
        fake = FakeSystem(gateway="down", tunnel="down")
        fake.reminders_tunnel_health = "down"
        fake.registered.clear()
        original = {"version": 1, "started": 1000, "session": "a" * 64,
            "tunnel_start_pending": False, "tunnel_start_attempted": True,
            "components": {"tunnel": {"failures": 7, "attempts": [2000, 2100],
                "next": 2500, "backoff": 3, "incident": "down"}}}
        service._json_write(self.directory / "monitor-state.json", original)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(service.install(self.state, system=fake), 0)
        self.assertEqual(json.loads(service._read(self.directory / "monitor-state.json")), original)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(service.uninstall(self.state, system=fake), 0)
        service._write(self.directory / "monitor-state.json", b"invalid")
        fake.commands.clear()
        with self.assertRaises(ValueError):
            service.install(self.state, system=fake)
        self.assertFalse(any(isinstance(command, list) and "bootstrap" in command for command in fake.commands))

    def test_reminders_ownership_conflict_never_stops_either_tunnel(self):
        self.enable_reminders_tunnel()
        self.activate_fixture()
        fake = FakeSystem()
        fake.reminders_tunnel_health = "ownership_conflict"
        with self.assertRaises(ValueError):
            service.uninstall(self.state, system=fake)
        self.assertFalse(any(isinstance(command, list) and "stop" in command for command in fake.commands))
        self.assertNotIn(("bootout", service.GATEWAY), fake.commands)

    def test_literal_loader_rejects_code_extra_keys_and_insecure_file(self):
        self.assertEqual(service.runtime_environment(self.env), {"CONTROL_PLANE_API_KEY": "synthetic-runtime-secret"})
        for raw in (b"CONTROL_PLANE_API_KEY=$(touch /tmp/should-not-exist)", b"CONTROL_PLANE_API_KEY=`id`",
                    b"OTHER_KEY=value", b"CONTROL_PLANE_API_KEY=x; id", b"CONTROL_PLANE_API_KEY=x\nCONTROL_PLANE_API_KEY=y"):
            service._write(self.env, raw)
            with self.assertRaises(ValueError):
                service.runtime_environment(self.env)
        service._write(self.env, b"export CONTROL_PLANE_API_KEY=synthetic\n# comment\n")
        self.assertEqual(service.runtime_environment(self.env)["CONTROL_PLANE_API_KEY"], "synthetic")
        self.env.chmod(0o644)
        with self.assertRaises(ValueError):
            service.runtime_environment(self.env)

    def test_symlink_and_hardlink_credentials_rejected(self):
        target = self.env.with_name("target")
        self.env.rename(target)
        self.env.symlink_to(target)
        with self.assertRaises(OSError):
            service.runtime_environment(self.env)
        self.env.unlink()
        os.link(target, self.env)
        with self.assertRaises(ValueError):
            service.runtime_environment(self.env)

    def test_exact_tunnel_status_shape_and_poll_health(self):
        healthy = {"process_running": True, "healthy": True, "ready": True, "runtime_state": "ready",
                   "control_plane_poll_health": {"state": "healthy"}}
        self.assertEqual(service.tunnel_health(healthy), "healthy")
        self.assertEqual(service.tunnel_health(dict(healthy, process_running=False)), "indeterminate")
        stopped = dict(healthy, process_running=False, healthy=False, ready=False, runtime_state="stopped")
        self.assertEqual(service.tunnel_health(stopped), "down")
        self.assertEqual(service.tunnel_health(dict(stopped, local={"live_admin_ui": {"found": True}})), "indeterminate")
        self.assertEqual(service.tunnel_health(dict(healthy, ready=False)), "unhealthy")
        self.assertEqual(service.tunnel_health(dict(healthy, control_plane_poll_health={"state": "failing"})), "unhealthy")
        self.assertEqual(service.tunnel_health({"runtime": {"status": "running"}}), "indeterminate")

    def test_startup_grace_consecutive_failures_bounded_persisted_budget(self):
        fake = FakeSystem(gateway="down")
        self.check(fake, [1000, 1060, 1119])
        self.assertEqual(fake.restarts, [])
        self.check(fake, [1120, 1180, 1240, 1360, 1600, 2000])
        self.assertEqual(fake.restarts, ["gateway"] * 3)
        saved = json.loads(service._read(self.directory / "monitor-state.json"))
        self.assertEqual(len(saved["components"]["gateway"]["attempts"]), 3)
        # A fresh one-shot monitor cannot lose its rolling budget, even if
        # the wall clock moves backwards after a restart.
        other = FakeSystem(gateway="down")
        self.check(other, [900, 2100, 2200])
        self.assertEqual(other.restarts, [])

    def test_failed_recovery_consumes_budget_before_child_action(self):
        fake = FakeSystem(gateway="down")
        def crash(component):
            saved = json.loads(service._read(self.directory / "monitor-state.json"))
            self.assertEqual(len(saved["components"][component]["attempts"]), 1)
            raise TimeoutError()
        fake.recover = crash
        saved = self.check(fake, [1000, 1060, 1120])
        self.assertEqual(len(saved["components"]["gateway"]["attempts"]), 1)
        self.assertIn(b'restart_failed', service._read(self.directory / "monitor.log"))
        self.assertEqual(fake.events, [("gateway", "down")])

    def test_busy_permission_indeterminate_never_restart_and_tunnel_dependency(self):
        for health in ("busy", "permission", "indeterminate"):
            with self.subTest(health=health):
                (self.directory / "monitor-state.json").unlink(missing_ok=True)
                fake = FakeSystem(gateway=health, tunnel="unhealthy")
                self.check(fake, [1000, 1060, 1120, 1300, 1600])
                self.assertEqual(fake.restarts, [])
                if health == "busy":
                    self.assertFalse(any(component == "gateway" for component, _ in fake.events))

    def test_down_tunnel_only_recovers_with_healthy_gateway(self):
        fake = FakeSystem(tunnel="down")
        self.check(fake, [1000, 1060, 1120])
        self.assertEqual(fake.restarts, ["tunnel"])

    def test_incident_dedup_and_recovery_notification(self):
        fake = FakeSystem(gateway="permission")
        self.check(fake, [1000, 1060, 1120, 1180, 1240])
        self.assertEqual(fake.events, [("gateway", "permission")])
        fake.gateway_health = "healthy"
        self.check(fake, [1300, 1360, 1420])
        self.assertEqual(fake.events, [("gateway", "permission"), ("gateway", "recovered")])
        log = service._read(self.directory / "monitor.log")
        self.assertNotIn(b"synthetic-runtime-secret", log)
        self.assertNotIn(b"synthetic-id", log)

    def test_inactive_monitor_and_uninstall_cannot_adopt_manual_runtime(self):
        fake = FakeSystem()
        with self.assertRaises(FileNotFoundError):
            service.monitor(self.state, system=fake)
        with self.assertRaises(ValueError):
            service.uninstall(self.state, system=fake)
        self.assertEqual(fake.commands, [])
        self.assertEqual(fake.restarts, [])

    def test_install_refuses_manual_runtime_and_preserves_state(self):
        for gateway, tunnel in (("healthy", "down"), ("down", "healthy"), ("indeterminate", "down")):
            fake = FakeSystem(gateway=gateway, tunnel=tunnel)
            with self.assertRaises(ValueError):
                service.install(self.state, system=fake)
            self.assertEqual(fake.commands, [])
            self.assertFalse((self.directory / "installed.json").exists())
        self.assertTrue((self.state / "gateway.token").exists())

    def test_install_uninstall_with_fake_home_and_runner_preserves_journal(self):
        fake = FakeSystem(gateway="down", tunnel="down")
        fake.registered = set()
        native = self.state / "native-eventkit"
        native.mkdir(mode=0o700)
        journal = native / "synthetic-journal-marker"
        journal.write_text("preserve")
        with patch.object(Path, "home", return_value=self.root), redirect_stdout(io.StringIO()):
            for label, value in service.plists(self.config).items():
                service._write(self.directory / (label + ".plist"), plistlib.dumps(value))
            self.assertEqual(service.install(self.state, system=fake), 0)
            self.assertEqual(fake.registered, {service.GATEWAY, service.MONITOR})
            self.assertTrue((self.directory / "installed.json").exists())
            fake.commands.clear()
            self.assertEqual(service.uninstall(self.state, system=fake), 0)
        self.assertEqual(fake.commands[0], ("bootout", service.MONITOR))
        self.assertFalse((self.directory / "installed.json").exists())
        self.assertEqual(journal.read_text(), "preserve")
        self.assertTrue(self.env.exists())

    def test_changed_configuration_cannot_authorize_monitor_or_uninstall(self):
        self.activate_fixture()
        changed = dict(self.config, alias="different")
        service._json_write(self.directory / "config.json", changed)
        fake = FakeSystem()
        for function in (service.monitor, service.uninstall):
            with self.assertRaises(ValueError):
                function(self.state, system=fake)
        self.assertEqual(fake.commands, [])

    def test_bootstrap_failure_with_incomplete_rollback_retains_ownership(self):
        fake = FakeSystem(gateway="down", tunnel="down")
        fake.registered = set()
        def runner(command, **kwargs):
            fake.commands.append(command)
            if command[-1].endswith(service.GATEWAY + ".plist"):
                fake.registered.add(service.GATEWAY)
                return 0, b""
            return 1, b""
        def launch(operation, label):
            if operation == "print":
                return label in fake.registered
            return False
        fake.run, fake.launch = runner, launch
        with patch.object(Path, "home", return_value=self.root):
            for label, value in service.plists(self.config).items():
                service._write(self.directory / (label + ".plist"), plistlib.dumps(value))
            with self.assertRaises(ValueError):
                service.install(self.state, system=fake)
        self.assertTrue((self.directory / "installed.json").exists())
        self.assertTrue((self.root / "Library/LaunchAgents" / (service.GATEWAY + ".plist")).exists())

    def test_missing_monitor_state_never_resets_restart_budget(self):
        self.activate_fixture()
        fake = FakeSystem(gateway="down")
        with self.assertRaises(ValueError):
            service.monitor(self.state, system=fake, now=1120)
        self.assertEqual(fake.restarts, [])
        self.assertFalse((self.directory / "monitor-state.json").exists())
        self.assertEqual(fake.events, [("monitor", "state_invalid")])

    def test_sustained_health_resets_backoff_preserving_rolling_budget(self):
        fake = FakeSystem(gateway="down")
        saved = self.check(fake, [1000, 1060, 1120])
        self.assertEqual(saved["components"]["gateway"]["backoff"], 1)
        fake.gateway_health = "healthy"
        saved = self.check(fake, [1180, 1240, 1300])
        item = saved["components"]["gateway"]
        self.assertEqual(item["backoff"], 0)
        self.assertEqual(len(item["attempts"]), 1)

    def test_initial_tunnel_start_is_logged_without_outage_or_recovery_alert(self):
        fake = FakeSystem(tunnel="down")
        fake.episode = "a" * 64
        saved = self.check(fake, [1000, 1060, 1120])
        self.assertEqual(fake.restarts, ["tunnel"])
        self.assertEqual(fake.events, [])
        self.assertTrue(saved["tunnel_start_attempted"])
        self.assertIn(b"startup_requested", service._read(self.directory / "monitor.log"))
        fake.tunnel_health = "healthy"
        self.check(fake, [1180, 1240, 1300])
        self.assertEqual(fake.events, [])

    def test_new_boot_login_episode_starts_tunnel_without_resetting_budget(self):
        fake = FakeSystem(tunnel="down")
        fake.episode = "a" * 64
        self.check(fake, [1000, 1060, 1120])
        fake.tunnel_health = "healthy"
        self.check(fake, [1180, 1240, 1300])
        fake.episode = "b" * 64
        fake.tunnel_health = "down"
        saved = self.check(fake, [2000, 2060, 2120])
        self.assertEqual(fake.restarts, ["tunnel", "tunnel"])
        self.assertEqual(fake.events, [])
        self.assertEqual(len(saved["components"]["tunnel"]["attempts"]), 2)

    def test_failed_initial_start_alerts_after_normal_grace(self):
        fake = FakeSystem(tunnel="down")
        fake.episode = "a" * 64
        fake.recovery_result = False
        self.check(fake, [1000, 1060, 1120, 1180])
        self.assertEqual(fake.events, [])
        self.check(fake, [1240])
        self.assertEqual(fake.events, [("tunnel", "down")])

    def test_established_outage_unknown_episode_and_exhausted_budget_alert(self):
        fake = FakeSystem()
        fake.episode = "a" * 64
        self.check(fake, [1000])
        fake.tunnel_health = "down"
        self.check(fake, [1060, 1120, 1180])
        self.assertEqual(fake.events, [("tunnel", "down")])
        (self.directory / "monitor-state.json").unlink()
        fake = FakeSystem(tunnel="down")  # Unknown detector stays conservative.
        self.check(fake, [1000, 1060, 1120])
        self.assertEqual(fake.events, [("tunnel", "down")])
        saved = json.loads(service._read(self.directory / "monitor-state.json"))
        saved["components"]["tunnel"].update(attempts=[1000, 1060, 1120], next=0, incident=None)
        service._json_write(self.directory / "monitor-state.json", saved)
        fake.events.clear()
        fake.episode = "b" * 64
        self.check(fake, [2000, 2060, 2120])
        self.assertEqual(fake.events, [("tunnel", "down")])

    def test_episode_detector_accepts_only_exact_safe_command_shapes(self):
        commands = []
        def runner(command, **kwargs):
            commands.append((command, kwargs))
            return 0, b"12345678-1234-5678-9012-123456789abc\n" if command[0].endswith("sysctl") else b"auid=501\nmask.success=0xffffffff\nmask.failure=0xffffffff\nasid=12345\ntermid_addr.port=0\ntermid_addr.addr[0]=0\nflags=0x30\n"
        system = service.System(self.config, runner)
        first = system.session()
        self.assertEqual(len(first), 64)
        self.assertEqual(first, system.session())
        self.assertTrue(all(kwargs["timeout"] == 5 for _, kwargs in commands))
        system.run = lambda *args, **kwargs: (0, b"unexpected extra data")
        self.assertIsNone(system.session())
        system.run = lambda command, **kwargs: (0, b"12345678-1234-5678-9012-123456789abc\n" if command[0].endswith("sysctl") else b"asid=12345\nasid=12346\n")
        self.assertIsNone(system.session())

    def test_staged_plist_tamper_prevents_install(self):
        fake = FakeSystem(gateway="down", tunnel="down")
        fake.registered = set()
        service._write(self.directory / (service.GATEWAY + ".plist"), plistlib.dumps({"Label": "different"}))
        with self.assertRaises(ValueError):
            service.install(self.state, system=fake)
        self.assertFalse((self.directory / "installed.json").exists())
        self.assertFalse(any(isinstance(cmd, list) and "bootstrap" in cmd for cmd in fake.commands))

    def test_monitor_refuses_corrupt_budget_and_unregistered_gateway(self):
        self.activate_fixture()
        fake = FakeSystem(gateway="down")
        service._write(self.directory / "monitor-state.json", b"not json")
        with self.assertRaises(ValueError):
            service.monitor(self.state, system=fake, now=1000)
        self.assertEqual(fake.restarts, [])
        fake.registered = set()
        with self.assertRaises(ValueError):
            service.monitor(self.state, system=fake, now=1000)

    def test_busy_interrupts_consecutive_failure_streak(self):
        fake = FakeSystem(gateway="timeout")
        self.check(fake, [1000, 1060])
        fake.gateway_health = "busy"
        self.check(fake, [1120])
        fake.gateway_health = "timeout"
        self.check(fake, [1180, 1240])
        self.assertEqual(fake.restarts, [])
        self.check(fake, [1300])
        self.assertEqual(fake.restarts, ["gateway"])

    def test_uninstall_plist_tamper_never_stops_owned_or_manual_runtime(self):
        self.activate_fixture()
        agents = self.root / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        service._write(agents / (service.GATEWAY + ".plist"), plistlib.dumps({"Label": "unrelated"}))
        fake = FakeSystem()
        with patch.object(Path, "home", return_value=self.root), self.assertRaises(ValueError):
            service.uninstall(self.state, system=fake)
        self.assertEqual(fake.commands, [])

    def test_shared_lifecycle_lock_suppresses_monitor_and_other_mutation(self):
        import fcntl
        descriptor = os.open(self.directory / "lifecycle.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            self.assertEqual(service.monitor(self.state, system=FakeSystem()), 0)
            with self.assertRaises(ValueError):
                service.install(self.state, system=FakeSystem())
        finally:
            os.close(descriptor)

    def test_invalid_persisted_budget_is_alerted_once_without_recovery(self):
        self.activate_fixture()
        service._json_write(self.directory / "monitor-state.json", {"version": 1, "started": 1000,
            "components": {"gateway": {"failures": -1, "attempts": [], "next": 0, "incident": None}}})
        fake = FakeSystem(gateway="down")
        for now in (1120, 1180):
            with self.assertRaises(ValueError):
                service.monitor(self.state, system=fake, now=now)
        self.assertEqual(fake.restarts, [])
        self.assertEqual(fake.events, [("monitor", "state_invalid")])

    def test_failed_monitor_shutdown_preserves_registration_and_tunnel(self):
        self.activate_fixture()
        fake = FakeSystem()
        def launch(operation, label):
            fake.commands.append((operation, label))
            return operation == "print"
        fake.launch = launch
        with self.assertRaises(ValueError):
            service.uninstall(self.state, system=fake)
        self.assertEqual(fake.commands, [("bootout", service.MONITOR), ("print", service.MONITOR)])
        self.assertTrue((self.directory / "installed.json").exists())

    def test_tunnel_reconnect_uses_exact_alias_env_reference_no_shell(self):
        captured = []
        def runner(command, **kwargs):
            captured.append((command, kwargs))
            if command[2] == "status":
                return 0, json.dumps({"alias": "fixture", "tunnel_id": "synthetic-id", "profile_name": "fixture",
                    "profile_dir": self.config["profile_dir"], "process_running": False, "healthy": False,
                    "ready": False, "runtime_state": "stopped"}).encode()
            return 0, b"ignored"
        self.assertTrue(service.System(self.config, runner).recover("tunnel"))
        command, kwargs = captured[-1]
        self.assertEqual(command[:3], ["/usr/bin/true", "runtimes", "connect"])
        self.assertIn("env:CONTROL_PLANE_API_KEY", command)
        self.assertNotIn("synthetic-runtime-secret", " ".join(command))
        self.assertEqual(kwargs["extra_env"]["CONTROL_PLANE_API_KEY"], "synthetic-runtime-secret")
        self.assertIn("--tunnel-id", command)
        self.assertIn(sys.executable, command[-1])
        self.assertEqual(captured[1][0][-2:], ["stop", "fixture"])

    def test_tunnel_alias_replacement_is_never_stopped(self):
        commands = []
        def runner(command, **kwargs):
            commands.append(command)
            return 0, json.dumps({"alias": "fixture", "tunnel_id": "replacement", "profile_name": "fixture",
                "profile_dir": self.config["profile_dir"], "process_running": False, "healthy": False,
                "ready": False, "runtime_state": "stopped"}).encode()
        system = service.System(self.config, runner)
        self.assertEqual(system.tunnel(), "ownership_conflict")
        self.assertFalse(system.recover("tunnel"))
        self.assertTrue(all(command[2] == "status" for command in commands))

    def test_runner_bounds_child_output_timeout_and_does_not_leak_stderr(self):
        self.assertEqual(service.run([sys.executable, "-c", "import sys; print('ok'); print('secret',file=sys.stderr)"]), (0, b"ok\n"))
        with self.assertRaises(ValueError):
            service.run([sys.executable, "-c", "print('x'*200000)"])
        with self.assertRaises(TimeoutError):
            service.run([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.1)
        with self.assertRaises(TimeoutError):
            service.run([sys.executable, "-c", "import os,time; os.close(1); time.sleep(10)"], timeout=0.1)

    def test_actual_synthetic_http_probe_calls_only_native_status(self):
        class Broker:
            calls = []
            status = "full_access"
            def authorization_status(self):
                self.calls.append("authorization_status")
                return {"backend_mode": "eventkit", "authorization_status": self.status,
                        "authorization_status_raw": 3, "pid": 1234}
            def call(self, *args):
                raise AssertionError("Calendar operation must never be dispatched")
        broker = Broker()
        from calendar_mcp.security import read_token
        server = GatewayServer(0, read_token(self.state), Protocol(broker), state_directory=self.state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            config = dict(self.config, port=server.server_port)
            actual = service.System(config)
            self.assertEqual(actual.gateway(), "healthy")
            broker.status = "denied"
            self.assertEqual(actual.gateway(), "permission")
            self.assertEqual(broker.calls, ["authorization_status"] * 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
