"""Launch a signed app through LaunchServices with private, bounded IPC.

The lifetime FIFO has exactly one writer in the gateway. Native code watches
its EOF independently of request execution, so gateway death cannot orphan a
broker holding the durable state lock. No returned PID is ever signalled.
"""

import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def bundle_for_helper(helper):
    helper = Path(helper).resolve(strict=True)
    if helper.parent.name != "MacOS" or helper.parent.parent.name != "Contents":
        raise ValueError("EventKit requires the signed Calendar MCP Helper app bundle")
    bundle = helper.parent.parent.parent
    if bundle.suffix != ".app":
        raise ValueError("EventKit requires an app bundle")
    with (bundle / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (info.get("CFBundleExecutable") != helper.name or info.get("CFBundleIdentifier") != "local.calendar-mcp.helper"
            or info.get("CFBundlePackageType") != "APPL"):
        raise ValueError("Unexpected Calendar helper bundle identity")
    return bundle


class LaunchServicesProcess:
    def __init__(self, helper, arguments):
        self.directory = tempfile.TemporaryDirectory(prefix="calendar-mcp-", dir="/private/tmp")
        self.stdin = self.stdout = self.lifetime = self.launcher = None
        try:
            directory = Path(self.directory.name)
            os.chmod(directory, 0o700)
            paths = {name: directory / name for name in ("requests", "responses", "lifetime")}
            for path in paths.values():
                os.mkfifo(path, 0o600)
            flags = os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW
            self.stdin = os.fdopen(os.open(paths["requests"], flags), "wb", buffering=0)
            self.stdout = os.fdopen(os.open(paths["responses"], flags), "rb", buffering=0)
            self.lifetime = os.fdopen(os.open(paths["lifetime"], flags), "wb", buffering=0)
            bundle = bundle_for_helper(helper)
            command = ["/usr/bin/open", "-n", "-W", "-g", "--stdin", str(paths["requests"]),
                       "--stdout", str(paths["responses"]), "--stderr", "/dev/null", str(bundle),
                       "--args", *arguments, "--lifetime-fifo", str(paths["lifetime"])]
            self.launcher = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL, close_fds=True)
        except BaseException:
            self.close()
            raise

    def poll(self):
        return self.launcher.poll() if self.launcher is not None else 1

    def close(self):
        # EOF on requests is graceful. The independent lifetime EOF forcibly
        # stops a hung native execution, whose durable journal remains unknown.
        if self.stdin is not None:
            self.stdin.close()
        if self.launcher is not None and self.launcher.poll() is None:
            try:
                self.launcher.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if self.lifetime is not None:
            self.lifetime.close()
        if self.launcher is not None and self.launcher.poll() is None:
            try:
                self.launcher.wait(timeout=2)
            except subprocess.TimeoutExpired:
                # Kill only our open(1) wrapper. The native app is stopped by
                # lifetime EOF, without trusting or signalling a reusable PID.
                self.launcher.terminate()
                try:
                    self.launcher.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self.launcher.kill()
                    self.launcher.wait(timeout=1)
        if self.stdout is not None:
            self.stdout.close()
        self.directory.cleanup()
