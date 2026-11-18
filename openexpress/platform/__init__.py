"""What differs between the systems openExpress runs on, chosen here once: on Linux the devices
are found and opened through GIO (gvfs: device/gio_storage.py), on macOS over USB by the
program itself (device/mac_storage.py, platform/mac_usb.py). Nothing is imported here until it
is asked for, so that importing this package never needs PyGObject or libusb; the modules of
this package (mac_usb, and others) are imported by name where they are used.
"""

from __future__ import annotations

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
