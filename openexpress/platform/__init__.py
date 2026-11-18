"""What differs between the systems openExpress runs on, chosen here once: on Linux the devices
are found and opened through GIO (gvfs: device/gio_storage.py), on macOS over USB by the
program itself (device/mac_storage.py, platform/mac_usb.py); macOS's folders, secrets and the
rest are in platform/macos.py and platform/keychain.py. A function that answers None leaves
the caller to its own (Linux) way. Nothing is imported here until it is asked for, so that
importing this package never needs PyGObject or libusb.
"""

from __future__ import annotations

import os
import sys

# The commands of the desktop of Linux (a GTK window, the background service of systemd and
# their launchers): not on macOS.
LINUX_ONLY_COMMANDS = ("gui", "watch", "install-desktop")


def is_mac() -> bool:
    return sys.platform == "darwin"


def needs_pygobject() -> bool:
    """Whether the command line needs PyGObject to open a device: on Linux (GIO); on macOS
    only the window would, which is not there."""
    return not is_mac()


def devices():
    """The module that finds and opens the Garmin devices here: gio_storage on Linux,
    mac_storage on macOS. Both have the same names for it: find_devices, find_all_devices,
    find_ums_devices, probe, distinct_devices, open_device_storage, open_ums_storage, mount,
    mount_drive, close_found, holders, usb_state (and its states ABSENT, STARTING, PRESENT,
    MASS_STORAGE, DRIVE_OFF, UNSUPPORTED), garmin_usb_summary, mtp_missing and the errors of
    found.py."""
    if is_mac():
        from openexpress.device import mac_storage

        return mac_storage
    from openexpress.device import gio_storage

    return gio_storage


def open_device_storage(uri: str | None = None, wait: bool = False, notify=None):
    """The storage of the connected device that has GARMIN/GarminDevice.xml (`uri`: the one
    named with --device-uri), as the module of this system opens it (devices)."""
    return devices().open_device_storage(uri, wait=wait, notify=notify)


def app_dir(var: str):
    """The app's folder in place of the XDG folder `var` (e.g. XDG_DATA_HOME), a Path: on
    macOS its folder under ~/Library, unless `var` is set; else None."""
    if not is_mac() or os.environ.get(var):
        return None
    from openexpress.platform import macos

    return macos.app_dir(var)


def boot_id() -> str | None:
    """This start of the computer, on macOS (kern.boottime; "" when it cannot be read); None
    elsewhere."""
    if not is_mac():
        return None
    from openexpress.platform import macos

    return macos.boot_id()


def mount_id(root) -> str | None:
    """On macOS, which keeps no table of mounts, the ID of the mount of a drive at `root`
    (the device number of its filesystem); None elsewhere, or when it cannot be read."""
    if not is_mac():
        return None
    from openexpress.platform import macos

    return macos.mount_id(root)


def keep_awake():
    """On macOS, the computer kept from idling into sleep (caffeinate): the function that lets
    it sleep again. None elsewhere, where the desktop is asked (awake)."""
    if not is_mac():
        return None
    from openexpress.platform import macos

    return macos.keep_awake()


def libusb_places() -> list[str]:
    """Where this system keeps a libusb-1.0 the library path does not have: Homebrew's on
    macOS."""
    if not is_mac():
        return []
    from openexpress.platform import macos

    return macos.libusb_places()


def secrets():
    """Where the secrets are kept (keychain.Backend): the Keychain on macOS, which takes in
    the file of an earlier version; a file readable by the user alone elsewhere."""
    from openexpress.platform import keychain

    return keychain.KeychainSecrets() if is_mac() else keychain.FileSecrets()


def at_start() -> None:
    """What the program sets right at its start on this system: on macOS, the camera service a
    killed run of ours may have left stopped goes on again (mac_usb). Never an error: a failure
    goes to the log."""
    if not is_mac():
        return
    try:
        from openexpress.platform import mac_usb

        mac_usb.wake_camera_daemon_left_stopped()
    except Exception as e:  # noqa: BLE001 - a safety net of its own; the command goes on
        import logging

        logging.getLogger(__name__).info("start: the camera service not looked at (%s)",
                                         type(e).__name__)
