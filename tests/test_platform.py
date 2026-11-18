"""platform: what the program uses on each system to find and open devices, chosen by the
system it runs on, and the command line on macOS, which needs no PyGObject. No device is
listed or opened."""

import subprocess
import sys
import types

import pytest

from openexpress import platform
from openexpress.device import found


def test_the_devices_are_found_by_gio_on_linux_and_over_usb_on_macos(monkeypatch):
    import openexpress.device
    from openexpress.device import mac_storage

    gio = types.ModuleType("openexpress.device.gio_storage")  # GIO itself is not needed
    monkeypatch.setitem(sys.modules, "openexpress.device.gio_storage", gio)
    # Where the real one was imported (Linux), the package's attribute is what an import finds.
    monkeypatch.setattr(openexpress.device, "gio_storage", gio, raising=False)
    monkeypatch.setattr(platform, "is_mac", lambda: False)
    assert platform.devices() is gio and platform.needs_pygobject()
    monkeypatch.setattr(platform, "is_mac", lambda: True)
    assert platform.devices() is mac_storage and not platform.needs_pygobject()


# What the command line, service, report and engine ask of platform.devices().
DEVICES_NAMES = ("find_devices", "find_all_devices", "find_ums_devices", "probe",
                 "distinct_devices", "open_device_storage", "open_ums_storage", "mount",
                 "mount_drive", "close_found", "holders", "usb_state", "garmin_usb_summary",
                 "mtp_missing", "ABSENT", "STARTING", "PRESENT", "MASS_STORAGE", "DRIVE_OFF",
                 "UNSUPPORTED", "SeveralDevices", "NotThereYet", "MassStorageNotice",
                 "UnsupportedDevice")


def test_the_names_of_the_devices_module_are_the_same_on_both_systems():
    from openexpress.device import mac_storage

    for name in DEVICES_NAMES:
        assert hasattr(mac_storage, name), name
    assert mac_storage.SeveralDevices is found.SeveralDevices


def test_gio_storage_has_the_names_of_the_devices_module_too():
    pytest.importorskip("gi")
    from openexpress.device import gio_storage

    for name in DEVICES_NAMES:
        assert hasattr(gio_storage, name), name
    assert gio_storage.holders() == {}


def test_importing_the_platform_and_the_storage_of_macos_needs_neither_pygobject_nor_libusb():
    code = ("import sys, openexpress.platform, openexpress.device.mac_storage, "
            "openexpress.devicelist, openexpress.device.found\n"
            "from openexpress.device import ptp\n"
            "assert not [m for m in sys.modules if m == 'gi' or m.startswith('gi.')]\n"
            "assert 'openexpress.device.gio_storage' not in sys.modules\n"
            "assert ptp._libusb is None\n")
    subprocess.run([sys.executable, "-c", code], check=True)


@pytest.mark.parametrize("command", platform.LINUX_ONLY_COMMANDS)
@pytest.mark.usefixtures("as_mac")
def test_the_commands_of_the_linux_desktop_say_so_on_macos(command, monkeypatch, capsys,
                                                          tmp_path):
    from openexpress import cli

    monkeypatch.setenv("HOME", str(tmp_path))  # macOS's folders are under ~/Library
    monkeypatch.setattr(cli.applog, "setup", lambda *a, **k: pytest.fail("not started"))
    assert cli.main([command]) == 1
    assert f"openexpress {command} is only available on Linux" in capsys.readouterr().err


@pytest.mark.usefixtures("as_mac")
def test_the_command_line_on_macos_opens_a_device_without_pygobject(monkeypatch, capsys,
                                                                     tmp_path):
    """No "install PyGObject": the device is asked of mac_storage, which says what it found."""
    from openexpress import cli
    from openexpress.device import mac_storage

    monkeypatch.setenv("HOME", str(tmp_path))  # macOS's folders are under ~/Library
    monkeypatch.setattr(cli.importlib.util, "find_spec", lambda name: None)
    asked = []

    def nothing_there(uri=None, wait=False, notify=None):
        asked.append(uri)
        raise found.NoDevice("No Garmin device (MTP) found.")

    monkeypatch.setattr(mac_storage, "open_device_storage", nothing_there)
    assert cli.main(["info", "--device-uri", "mtp://[usb:008,037]/"]) == 1
    assert asked == ["mtp://[usb:008,037]/"]
    assert "No Garmin device (MTP) found." in capsys.readouterr().err


@pytest.mark.usefixtures("as_mac")
def test_the_command_line_on_macos_does_not_ask_for_pygobject(monkeypatch, capsys, tmp_path):
    from openexpress import cli

    monkeypatch.setenv("HOME", str(tmp_path))  # macOS's folders are under ~/Library
    monkeypatch.setitem(sys.modules, "gi", None)  # as if PyGObject were not installed
    cli.main(["cache"])
    assert "PyGObject" not in capsys.readouterr().err


@pytest.mark.usefixtures("as_mac")
def test_no_command_on_macos_lists_the_commands_instead_of_opening_a_window(monkeypatch,
                                                                            capsys, tmp_path):
    from openexpress import cli

    monkeypatch.setenv("HOME", str(tmp_path))  # macOS's folders are under ~/Library
    monkeypatch.setattr(cli, "cmd_gui", lambda args: pytest.fail("a window"))
    assert cli.main([]) == 0
    out = capsys.readouterr()
    assert out.out.startswith("usage: openexpress") and out.err == ""
    assert cli.main(["gui"]) == 1
