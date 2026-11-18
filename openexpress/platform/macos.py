"""What macOS has in place of what Linux gives the program: the folders under ~/Library, the
start of the computer from sysctl, the mount of a drive from its device number, `caffeinate`
and Homebrew's libusb. Used through the functions of the package (platform), on macOS only.
"""

from __future__ import annotations

import ctypes
import os
import subprocess
from pathlib import Path

APP_NAME = "openExpress"  # the name of the app's folder under ~/Library

# The folder under ~/Library in place of each XDG one: config and data are kept together.
LIBRARY_FOLDERS = {
    "XDG_CONFIG_HOME": "Application Support",
    "XDG_DATA_HOME": "Application Support",
    "XDG_CACHE_HOME": "Caches",
    "XDG_STATE_HOME": "Logs",  # the log, where Console and the user both look for it
}

# Where Homebrew puts libusb (Apple silicon, then Intel): not where ctypes looks.
HOMEBREW_LIBUSB = ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib")

RELEASE_TIMEOUT_S = 5  # how long caffeinate may take to end


def app_dir(var: str) -> Path:
    """The app's folder under ~/Library in place of the XDG folder `var`."""
    return Path.home() / "Library" / LIBRARY_FOLDERS[var] / APP_NAME


class _Timeval(ctypes.Structure):
    _fields_ = (("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_int32))


def boot_id() -> str:
    """kern.boottime: the second the computer started, the same until it restarts; "" when it
    cannot be read."""
    try:
        libc = ctypes.CDLL("libc.dylib")
    except OSError:
        return ""
    value = _Timeval()
    size = ctypes.c_size_t(ctypes.sizeof(value))
    status = libc.sysctlbyname(b"kern.boottime", ctypes.byref(value), ctypes.byref(size),
                               None, 0)
    return str(value.tv_sec) if status == 0 else ""


def mount_id(root) -> str | None:
    """The device number of the filesystem at `root`: a drive gets a new /dev/diskN at each
    mount. None: it cannot be read."""
    try:
        return str(os.stat(root).st_dev)
    except OSError:
        return None


def keep_awake():
    """`caffeinate -i -w <pid>` started: the computer does not idle into sleep until the
    function returned is called. "-w" ends it with this process, should that die first."""
    process = subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def release() -> None:
        process.terminate()
        process.wait(timeout=RELEASE_TIMEOUT_S)

    return release


def libusb_places() -> list[str]:
    """Homebrew's libusb, where it is installed."""
    return [path for path in HOMEBREW_LIBUSB if os.path.isfile(path)]
