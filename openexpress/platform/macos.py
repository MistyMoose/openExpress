"""What macOS has in place of what Linux gives the program: the folders under ~/Library, the
start of the computer from sysctl and the mount of a drive from its device number. Used through
the functions of the package (platform), on macOS only.
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path

APP_NAME = "openExpress"  # the name of the app's folder under ~/Library

# The folder under ~/Library in place of each XDG one: config and data are kept together.
LIBRARY_FOLDERS = {
    "XDG_CONFIG_HOME": "Application Support",
    "XDG_DATA_HOME": "Application Support",
    "XDG_CACHE_HOME": "Caches",
    "XDG_STATE_HOME": "Logs",  # the log, where Console and the user both look for it
}


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
