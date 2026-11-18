"""A Garmin device in mass storage mode (a drive) on macOS: found by its disks below its USB
device in the IORegistry, its folder where macOS mounted it (diskutil), opened as a UmsStorage,
ejected after a write with `diskutil eject`, and the USB drive named for testing
(OPENEXPRESS_TEST_DRIVE_USB). Against made-up IORegistry and diskutil answers and a folder of
the test as the mounted volume: no USB device is listed and diskutil is never run."""

import logging
import plistlib
import subprocess
import types

import pytest
from conftest import DEVICE_XML

from openexpress.device import found, mac_storage
from openexpress.device.storage import DeviceError, UmsStorage
from openexpress.platform import mac_usb

# The real ones; conftest stubs them for every test (no_usb_on_macos).
DRIVE_DEVICES = mac_usb.drive_devices

TEST_DRIVE_ENV = "OPENEXPRESS_TEST_DRIVE_USB"
PORT = (2, 1, 3)


def _drive(product="2b4a", address=21, media=("disk4s1",), vendor=found.GARMIN_VID, port=PORT,
           classes=("08",)):
    return mac_usb.UsbDevice(2, address, product, classes, False, "Edge 520", "0000ab12",
                             vendor=vendor, port=port, media=media)


def _mounted(tmp_path, name="GARMIN", xml=True):
    """A folder of the test standing in for /Volumes/GARMIN."""
    root = tmp_path / name
    (root / "Garmin").mkdir(parents=True)  # a drive's own letter case
    if xml:
        (root / "Garmin" / "GarminDevice.xml").write_text(DEVICE_XML)
    return root


class FakeDiskutil:
    """diskutil as macOS answers it: `info -plist` of each disk (by its BSD name or the folder
    where it is mounted) from `disks`; `mount` mounts at `mount_at`; `eject` takes the disk
    away; each run kept in `runs`. `refuse`: what diskutil says when it refuses an eject."""

    def __init__(self):
        self.disks: dict[str, dict] = {}
        self.runs: list[tuple[str, ...]] = []
        self.mount_at: dict[str, str] = {}
        self.refuse: str | None = None

    def add(self, bsd, mount_point=None, name="GARMIN", whole=None, internal=False):
        self.disks[bsd] = {"DeviceIdentifier": bsd, "ParentWholeDisk": whole or bsd[:5],
                           "VolumeName": name, "VolumeUUID": "0E2B-11F1", "Internal": internal,
                           **({"MountPoint": str(mount_point)} if mount_point else {})}

    def __call__(self, *args, timeout=None):
        self.runs.append(args)
        if args[:2] == ("info", "-plist"):
            info = self.disks.get(args[2]) or next(
                (d for d in self.disks.values() if d.get("MountPoint") == args[2]), None)
            if info is None:
                return subprocess.CompletedProcess(args, 1, b"", b"Could not find disk")
            return subprocess.CompletedProcess(args, 0, plistlib.dumps(info), b"")
        if args[0] == "mount":
            self.disks[args[1]]["MountPoint"] = self.mount_at[args[1]]
            return subprocess.CompletedProcess(args, 0, b"Volume GARMIN mounted", b"")
        if args[0] == "eject":
            if self.refuse:
                return subprocess.CompletedProcess(args, 1, b"", self.refuse.encode())
            for bsd in [b for b, d in self.disks.items() if d["ParentWholeDisk"] == args[1]]:
                del self.disks[bsd]
            return subprocess.CompletedProcess(args, 0, b"Disk ejected", b"")
        raise AssertionError(f"diskutil {args}")


@pytest.fixture
def usb(monkeypatch):
    """The drives on USB (`usb.drives`) and the other Garmin devices (`usb.others`), diskutil
    (`usb.diskutil`) and the made-up clock (`usb.now`)."""
    state = types.SimpleNamespace(drives=[], others=[], diskutil=FakeDiskutil(), now=100.0,
                                  asked=[])

    def drive_devices(test_drive=None):
        state.asked.append(test_drive)
        return [d for d in state.drives
                if d.vendor == found.GARMIN_VID or (d.vendor, d.product) == test_drive]

    monkeypatch.setattr(mac_usb, "drive_devices", drive_devices)
    monkeypatch.setattr(mac_usb, "garmin_devices", lambda reuse=False: [
        *[d for d in state.drives if d.vendor == found.GARMIN_VID], *state.others])
    monkeypatch.setattr(mac_usb, "_diskutil", state.diskutil)
    monkeypatch.setattr(mac_storage, "_clock", lambda: state.now)
    return state


# --- the disks of a drive in the IORegistry -------------------------------------------------

def _media(bsd, leaf=True, children=()):
    return {"IOObjectClass": "IOMedia", "BSD Name": bsd, "Leaf": leaf,
            "IORegistryEntryChildren": list(children)}


def _usb_storage(vendor, product, address, media):
    """A USB device with a mass storage interface, its driver stack down to its disks, as
    `ioreg -a -r -c IOUSBHostDevice -l` writes it."""
    driver = {"IOObjectClass": "IOBlockStorageDriver", "IORegistryEntryChildren": media}
    stack = {"IOObjectClass": "IOUSBMassStorageDriver", "IORegistryEntryChildren": [
        {"IOObjectClass": "IOSCSIPeripheralDeviceType00", "IORegistryEntryChildren": [
            {"IOObjectClass": "IOBlockStorageServices", "IORegistryEntryChildren": [driver]}]}]}
    return {"IOObjectClass": "IOUSBHostDevice", "idVendor": vendor, "idProduct": product,
            "USB Address": address, "locationID": 0x02130000, "USB Product Name": "Drive",
            "IORegistryEntryChildren": [
                {"IOObjectClass": "IOUSBHostInterface", "bInterfaceClass": 8,
                 "IORegistryEntryChildren": [stack]}]}


def test_the_disks_of_a_drive_are_the_leaves_below_its_usb_device(monkeypatch):
    """Its partition (not the whole disk that holds the partitions), or its whole disk when it
    has no partitions; a USB drive of another vendor only when it is the one named."""
    garmin = _usb_storage(0x091E, 0x2B4A, 21, [_media("disk4", leaf=False, children=[
        {"IOObjectClass": "IOFDiskPartitionScheme", "IORegistryEntryChildren": [
            _media("disk4s10"), _media("disk4s2")]}])])
    unpartitioned = _usb_storage(0x091E, 0x2B4B, 22, [_media("disk5")])
    pendrive = _usb_storage(0x0781, 0x5581, 23, [_media("disk6", leaf=False, children=[
        _media("disk6s1")])])
    read = plistlib.dumps([{"IOObjectClass": "IOUSBHostDevice", "idVendor": 0x05AC,
                            "USB Address": 1, "locationID": 0x02100000,
                            "IORegistryEntryChildren": [garmin, unpartitioned, pendrive]}])
    registered = mac_usb._registry(read, {(0x091E, None)})
    assert registered[(2, 21)].media == ("disk4s2", "disk4s10")
    assert registered[(2, 22)].media == ("disk5",)
    assert (2, 23) not in registered
    with_test_drive = mac_usb._registry(read, {(0x091E, None), (0x0781, 0x5581)})
    assert with_test_drive[(2, 23)].media == ("disk6s1",)
    assert mac_usb._registry(read, {(0x091E, None), (0x0781, 0x5583)}).keys() == {(2, 21),
                                                                                  (2, 22)}


def test_the_drives_on_usb_are_the_garmin_ones_in_mass_storage_mode_and_the_named_one(
        monkeypatch):
    """From libusb (an MTP device or one in Garmin USB mode is no drive), with their disks as
    the IORegistry tells them at that look."""
    monkeypatch.setattr(mac_usb, "drive_devices", DRIVE_DEVICES)
    asked = []

    def on_usb(wanted):
        asked.append(wanted)
        return [_drive(media=()), _drive("51b8", 22, classes=("ff",), media=()),
                _drive("5581", 23, vendor="0781", media=())]

    monkeypatch.setattr(mac_usb, "_on_usb", on_usb)
    read = plistlib.dumps([_usb_storage(0x091E, 0x2B4A, 21, [_media("disk4")]),
                           _usb_storage(0x0781, 0x5581, 23, [_media("disk6")])])
    monkeypatch.setattr(mac_usb, "_read_registry", lambda: read)
    drives = mac_usb.drive_devices(("0781", "5581"))
    assert [(d.usb_id, d.media) for d in drives] == [("091e:2b4a", ("disk4",)),
                                                     ("0781:5581", ("disk6",))]
    assert asked == [{(0x091E, None), (0x0781, 0x5581)}]
    assert drives[1].garmin_usb().vendor == "0781"


def test_what_diskutil_tells_of_a_disk(usb, tmp_path):
    usb.diskutil.add("disk4s1", tmp_path, whole="disk4")
    volume = mac_usb.volume_info("disk4s1")
    assert volume == mac_usb.Volume("disk4s1", "disk4", str(tmp_path), "GARMIN", "0E2B-11F1")
    assert mac_usb.volume_info(str(tmp_path)) == volume  # by the folder where it is mounted
    assert mac_usb.volume_info("disk9s1") is None


# --- found, mounted, opened ------------------------------------------------------------------

def test_a_mounted_garmin_drive_is_found_at_its_folder(usb, tmp_path):
    root = _mounted(tmp_path)
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1", root)
    (drive,) = mac_storage.find_ums_devices()
    assert (drive.uri, drive.name, drive.mounted, drive.kind) == (root.as_uri(), "GARMIN", True,
                                                                  "ums")
    assert (drive.usb.product, drive.usb.bus, drive.usb.address) == ("2b4a", 2, 21)
    assert drive.usb.volume_uuid == "0E2B-11F1"
    assert mac_storage.find_all_devices() == [drive]
    summary = mac_storage.probe(drive)
    assert summary.ok and summary.description == "Test watch" and summary.storage is None


def test_a_drive_is_opened_as_the_folder_where_macos_mounted_it(usb, tmp_path):
    root = _mounted(tmp_path)
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1", root)
    (drive,) = mac_storage.find_ums_devices()
    storage = mac_storage.open_ums_storage(drive)
    assert isinstance(storage, UmsStorage) and storage.mass_storage
    assert storage.root == root and storage.usb is drive.usb and storage.volume_name == "GARMIN"
    assert storage.read("GARMIN/GarminDevice.xml") == DEVICE_XML.encode()
    storage.write("GARMIN/NewFiles/course.fit", b"course")
    assert (root / "Garmin" / "NewFiles" / "course.fit").read_bytes() == b"course"


def test_a_drive_unmounted_since_it_was_found_is_said_not_to_be_mounted(usb, tmp_path):
    drive = found.FoundDevice((tmp_path / "gone").as_uri(), "GARMIN", True, kind="ums")
    with pytest.raises(found.NotThereYet, match="not mounted"):
        mac_storage.open_ums_storage(drive)


def test_a_drive_without_garmin_device_xml_is_skipped(usb, tmp_path, caplog):
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1", _mounted(tmp_path, xml=False))
    with caplog.at_level(logging.INFO, logger=mac_storage.log.name):
        assert mac_storage.find_ums_devices() == []
    assert "(USB 091e:2b4a) without GARMIN/GarminDevice.xml, skipped" in caplog.text
    assert str(tmp_path) not in caplog.text


def test_a_drive_whose_disk_has_not_come_yet_is_waited_for_by_macos(usb, caplog):
    """Its USB device is there, its disk not yet: nothing to list, the state is that of a
    drive and the words say that macOS has not mounted it."""
    usb.drives = [_drive(media=())]
    with caplog.at_level(logging.INFO, logger=mac_storage.log.name):
        assert mac_storage.find_ums_devices() == []
    assert "waiting for macOS" in caplog.text
    assert mac_storage.usb_state() == found.MASS_STORAGE
    with pytest.raises(found.MassStorageNotice, match="macOS has not mounted it"):
        mac_storage.open_device_storage(wait=True)


def test_a_drive_macos_has_not_mounted_is_listed_and_mounted_when_chosen(usb, tmp_path):
    root = _mounted(tmp_path)
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1")
    usb.diskutil.mount_at["disk4s1"] = str(root)
    (drive,) = mac_storage.find_ums_devices()
    assert (drive.uri, drive.mounted, drive.kind) == ("ums-volume:/dev/disk4s1", False, "ums")
    assert mac_storage.probe(drive).reason == found.NOT_MOUNTED  # a list mounts nothing
    mounted = mac_storage.mount_drive(drive)
    assert ("mount", "disk4s1") in usb.diskutil.runs
    assert (mounted.uri, mounted.mounted, mounted.usb) == (root.as_uri(), True, drive.usb)
    assert mac_storage.open_ums_storage(mounted).exists("GARMIN/GarminDevice.xml")


def test_an_mtp_device_comes_before_a_drive_and_a_drive_alone_is_opened(usb, tmp_path,
                                                                         monkeypatch):
    """service.open_device_or_drive on macOS: no MTP device, so the drive."""
    from openexpress import platform, service

    monkeypatch.setattr(platform, "is_mac", lambda: True)
    root = _mounted(tmp_path)
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1", root)
    storage = service.open_device_or_drive()
    assert isinstance(storage, UmsStorage) and storage.root == root


# --- the engine ------------------------------------------------------------------------------

def test_the_engine_finds_a_drive_and_holds_nothing_of_it(usb, tmp_path, monkeypatch):
    """A poll lists the drive with the MTP devices; a drive has no session to hold, let go or
    wait for, and no other process waits for it."""
    from openexpress import engine, platform

    monkeypatch.setattr(platform, "is_mac", lambda: True)
    monkeypatch.setattr(mac_usb, "open_transport",
                        lambda bus, address: pytest.fail("a drive is never opened over USB"))
    monkeypatch.setattr(mac_usb, "wanted_elsewhere",
                        lambda bus, address: pytest.fail("nobody waits for a drive"))
    root = _mounted(tmp_path)
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1", root)
    devices = engine.SystemDevices()
    (seen,) = devices.scan()
    assert seen.key == root.as_uri() and seen.found.kind == "ums" and seen.holder is None
    assert devices.hold(seen.found) is None
    assert devices.back(seen.found) is None
    assert devices.wanted(seen.found) is False
    assert devices.options(seen.found) == {}
    devices.release(seen.found)
    assert devices.probe(seen.found).description == "Test watch"


def test_without_a_drive_on_usb_a_poll_runs_no_diskutil(usb):
    usb.others = [_drive("51b8", 30, classes=("ff",), media=())]
    found_now, _holders = mac_storage.poll()
    assert usb.diskutil.runs == [] and usb.asked == []


# --- ejected after a write ---------------------------------------------------------------------

def _opened(usb, tmp_path):
    root = _mounted(tmp_path)
    usb.drives = [_drive()]
    usb.diskutil.add("disk4s1", root, whole="disk4")
    (drive,) = mac_storage.find_ums_devices()
    return drive, mac_storage.open_ums_storage(drive)


def test_a_drive_is_ejected_with_diskutil_and_not_opened_again_until_unplugged(usb, tmp_path):
    drive, storage = _opened(usb, tmp_path)
    told = []
    mac_storage.eject(storage, on_unplugged=lambda: told.append(1))
    assert usb.diskutil.runs[-1] == ("eject", "disk4")  # its whole disk: every volume of it
    assert mac_storage.ejected_by_us(drive.usb)
    usb.drives = [_drive(media=())]  # on USB still, its disk gone
    assert mac_storage.find_ums_devices() == []
    assert mac_storage.usb_state() == found.MASS_STORAGE
    assert mac_storage.not_ready_text(found.MASS_STORAGE) == found.ejected_text()
    usb.diskutil.add("disk4s1", tmp_path / "GARMIN", whole="disk4")  # mounted again meanwhile
    usb.drives = [_drive()]
    assert mac_storage.find_ums_devices() == []
    # Unplugged: its port empty for a while.
    usb.drives = []
    assert mac_storage.ejected_drive_waits()
    usb.now += found.USB_GAP_S
    assert not mac_storage.ejected_drive_waits()
    assert told == [1]
    usb.drives = [_drive(address=25)]
    assert len(mac_storage.find_ums_devices()) == 1


def test_a_drive_plugged_in_again_at_once_is_opened_again(usb, tmp_path):
    """Another device number at its port, without its Garmin USB mode between: replugged."""
    drive, storage = _opened(usb, tmp_path)
    mac_storage.eject(storage)
    usb.diskutil.add("disk5s1", tmp_path / "GARMIN", whole="disk5")
    usb.drives = [_drive(address=26, media=("disk5s1",))]
    (again,) = mac_storage.find_ums_devices()
    assert again.usb.address == 26
    assert not mac_storage.ejected_drive_waits()


def test_a_watch_in_its_garmin_usb_mode_after_the_eject_is_drive_off(usb, tmp_path):
    """A Forerunner 55: back on the cable as 091e:0003 at the port of its drive."""
    drive, storage = _opened(usb, tmp_path)
    mac_storage.eject(storage, update_waits=True)
    usb.drives = []
    usb.others = [_drive("0003", 27, classes=("ff",), media=())]
    assert mac_storage.usb_state() == found.DRIVE_OFF
    assert "leave the device unplugged" in mac_storage.not_ready_text(found.DRIVE_OFF)
    assert mac_storage.ejected_drive_waits()
    with pytest.raises(found.MassStorageNotice, match="Garmin USB mode"):
        mac_storage.open_device_storage()
    # Another device in its Garmin USB mode at another port is one starting.
    usb.others = [_drive("0003", 28, classes=("ff",), media=(), port=(2, 2))]
    assert mac_storage.usb_state() == found.STARTING


def test_a_drive_not_mounted_any_more_is_not_ejected(usb, tmp_path):
    drive, storage = _opened(usb, tmp_path)
    del usb.diskutil.disks["disk4s1"]
    with pytest.raises(found.DriveNotMounted, match="not mounted any more"):
        mac_storage.eject(storage)
    assert not [r for r in usb.diskutil.runs if r[0] == "eject"]
    assert not mac_storage.ejected_by_us(drive.usb)


@pytest.mark.parametrize("other", ["another folder", "an internal disk"])
def test_only_the_disk_mounted_at_the_drives_folder_is_ever_ejected(usb, tmp_path, other):
    """diskutil tells the volume that holds a folder: never the Mac's own disk, nor another
    volume than the one mounted at the drive's folder."""
    drive, storage = _opened(usb, tmp_path)
    if other == "an internal disk":
        usb.diskutil.add("disk4s1", storage.root, whole="disk4", internal=True)
    else:
        usb.diskutil.disks["disk4s1"]["MountPoint"] = str(tmp_path)
        usb.diskutil.disks["disk3s1"] = {**usb.diskutil.disks["disk4s1"],
                                         "MountPoint": str(storage.root)[:-1] + "X"}
    with pytest.raises(found.DriveNotMounted):
        mac_storage.eject(storage)
    assert not [r for r in usb.diskutil.runs if r[0] == "eject"]


def test_an_eject_macos_refuses_is_said_with_its_reason(usb, tmp_path):
    drive, storage = _opened(usb, tmp_path)
    usb.diskutil.refuse = "Volume GARMIN on disk4s1 failed to unmount: dissented by PID 77"
    with pytest.raises(DeviceError, match="Cannot eject the device: .*dissented"):
        mac_storage.eject(storage)
    assert not mac_storage.ejected_by_us(drive.usb)


def test_after_a_write_the_drive_is_ejected_through_the_devices_of_macos(usb, tmp_path,
                                                                          monkeypatch):
    """service.eject_drive, as after a sync or an update: diskutil, and the words of macOS."""
    from openexpress import platform, service

    monkeypatch.setattr(platform, "is_mac", lambda: True)
    drive, storage = _opened(usb, tmp_path)
    said, errors = [], []
    assert service.eject_drive(storage, files=True, say=said.append, error=errors.append)
    assert said == ["Ejecting the device…", found.ejected_text(update_waits=False)]
    assert errors == [] and usb.diskutil.runs[-1] == ("eject", "disk4")
    usb.diskutil.add("disk4s1", storage.root, whole="disk4")
    usb.diskutil.refuse = "busy"
    assert not service.eject_drive(storage, files=True, say=said.append, error=errors.append)
    assert "Finder" in errors[-1]


# --- the USB drive named for testing -----------------------------------------------------------

def test_the_drive_named_for_testing_is_taken_for_a_garmin_drive(usb, tmp_path, monkeypatch,
                                                                 caplog):
    monkeypatch.setenv(TEST_DRIVE_ENV, "0781:5581")
    root = _mounted(tmp_path, name="PENDRIVE")
    usb.drives = [_drive("5581", 23, vendor="0781", media=("disk6s1",)),
                  _drive("5583", 24, vendor="0781", media=("disk7s1",))]
    usb.diskutil.add("disk6s1", root, name="PENDRIVE")
    with caplog.at_level(logging.INFO, logger=mac_storage.log.name):
        (drive,) = mac_storage.find_ums_devices()
        assert len(mac_storage.find_ums_devices()) == 1
    assert usb.asked[-1] == ("0781", "5581")
    assert drive.usb.usb_id == "0781:5581" and drive.usb.for_testing
    storage = mac_storage.open_ums_storage(drive)
    assert storage.test_drive and storage.exists("GARMIN/GarminDevice.xml")
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    (warning,) = warnings  # once, not at every look
    assert TEST_DRIVE_ENV in warning and "0781:5581" in warning and "testing" in warning
    assert "091e" not in caplog.text
    # Its unplugging is seen too, though it is no Garmin device.
    mac_storage.eject(storage)
    assert usb.diskutil.runs[-1] == ("eject", "disk6")
    assert mac_storage.ejected_drive_waits()
    usb.drives = []
    assert mac_storage.usb_state() == found.ABSENT
    usb.now += found.USB_GAP_S
    assert not mac_storage.ejected_drive_waits()


@pytest.mark.parametrize("value", ["0781-5581", "pendrive"])
def test_a_variable_in_another_form_is_ignored_with_a_warning(usb, monkeypatch, caplog, value):
    monkeypatch.setenv(TEST_DRIVE_ENV, value)
    usb.drives = [_drive("5581", 23, vendor="0781")]
    with caplog.at_level(logging.INFO, logger=mac_storage.log.name):
        assert mac_storage.find_ums_devices() == []
        mac_storage.find_ums_devices()
    assert usb.asked == [None, None]
    (warning,) = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert "VVVV:PPPP" in warning and "ignored" in warning
