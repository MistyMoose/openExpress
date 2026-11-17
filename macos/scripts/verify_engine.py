"""Checks the engine inside an openExpress.app, as the app runs it: its launcher with a scrubbed
environment, over the engine protocol (docs/ENGINE.md). Read-only: hello, settings.get,
devices.list, shutdown (and account.status with --account); nothing is written to a device or
to the account. Run by verify-pkg.sh with the bundled Python itself (-I), so it needs nothing
else.

    python3.13 -I verify_engine.py /path/to/openExpress.app [--account] [--timeout SECONDS]

--account reads the sign-in from the Keychain. Items that another build of the engine saved
(the development venv's Python, an earlier ad-hoc build) make macOS ask whether this one may
read them: the call then waits for that answer, up to the timeout.

GPL-3.0-or-later.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


class Engine:
    def __init__(self, launcher: Path, env: dict[str, str]):
        self.proc = subprocess.Popen([str(launcher), "engine"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.next_id = 1
        self.buffer = b""

    def call(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        rid = self.next_id
        self.next_id += 1
        request = {"id": rid, "method": method} | ({"params": params} if params else {})
        self.proc.stdin.write(json.dumps(request).encode() + b"\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        fd = self.proc.stdout.fileno()
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == rid:
                    if "error" in message:
                        error = message["error"]
                        fail(f"{method}: {error.get('code')}: {error.get('message')}")
                    return message["result"]
            left = deadline - time.monotonic()
            if left <= 0:
                self.proc.kill()
                fail(f"{method}: no answer within {timeout:.0f} s")
            ready, _, _ = select.select([fd], [], [], left)
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    fail(f"{method}: the engine exited ({self.proc.wait()}): "
                         f"{self.proc.stderr.read().decode(errors='replace')[-2000:]}")
                self.buffer += chunk

    def close(self) -> str:
        try:
            self.call("shutdown", timeout=20)
        finally:
            self.proc.stdin.close()
        code = self.proc.wait(timeout=20)
        log = self.proc.stderr.read().decode(errors="replace")
        if code != 0:
            fail(f"the engine exited with {code}: {log[-2000:]}")
        return log


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--account", action="store_true", help="also account.status (Keychain)")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    app = args.app.resolve()
    engine_dir = app / "Contents/Resources/engine"
    launcher = engine_dir / "bin/openexpress"
    libusb = app / "Contents/Frameworks/libusb-1.0.dylib"

    # As little of the environment as a login gives, and no Homebrew on PATH.
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", ""),
           "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
    engine = Engine(launcher, env)
    hello = engine.call("hello", {"client": "verify-pkg"})
    print(f"hello: engine {hello['engine']}, protocol {hello['protocol']}, "
          f"platform {hello['platform']}, {len(hello['methods'])} methods")
    if hello["platform"] != "darwin":
        fail("platform is not darwin")

    # The launcher's environment, as the engine process has it.
    ps = subprocess.run(["ps", "-E", "-ww", "-o", "command=", "-p", str(engine.proc.pid)],
                        capture_output=True, text=True, check=False).stdout
    if f"OPENEXPRESS_LIBUSB={libusb}" not in ps:
        fail(f"OPENEXPRESS_LIBUSB is not the bundled libusb: {ps[:300]}")
    if f"PATH={engine_dir}/bin:" not in ps:
        fail("the engine's bin is not first on PATH")
    print("environment: OPENEXPRESS_LIBUSB is the bundled libusb, engine/bin first on PATH")

    settings = engine.call("settings.get", timeout=args.timeout)["settings"]
    print(f"settings.get: {len(settings)} settings")
    if args.account:
        status = engine.call("account.status", timeout=args.timeout)
        print(f"account.status: signed_in={status['signed_in']}, setup_done={status['setup_done']}")
    devices = engine.call("devices.list", timeout=args.timeout)["devices"]
    connected = [d for d in devices if d.get("connected")]
    names = ", ".join(str(d.get("name") or d.get("description") or d.get("model") or "?")
                      for d in connected)
    print(f"devices.list: {len(connected)} connected{f' ({names})' if names else ''}, "
          f"{len(devices) - len(connected)} remembered")

    # The libusb the engine process has loaded (devices.list loads it).
    lsof = subprocess.run(["lsof", "-Fn", "-p", str(engine.proc.pid)], capture_output=True,
                          text=True, check=False).stdout
    loaded = sorted({line[1:] for line in lsof.splitlines()
                     if line.startswith("n") and "libusb" in line})
    if loaded != [str(libusb)]:
        fail(f"libusb loaded from {loaded or 'nowhere'}, not {libusb}")
    if any("/opt/homebrew" in line or "/usr/local" in line for line in lsof.splitlines()):
        fail("the engine has files of Homebrew open")
    print(f"libusb loaded: {loaded[0]}")
    engine.close()
    print("shutdown: the engine exited cleanly")


if __name__ == "__main__":
    main()
