"""The Garmin devices on USB on macOS, where there is no /sys and no gvfs: found through libusb
(ptp.load_libusb), their descriptors only, never opened to be looked at; what libusb does not
tell (the name a device gives itself, its serial, the program that holds it) is read from the
IORegistry (`ioreg`), which opens nothing either.

A Garmin device in mass storage mode (a drive) is mounted by macOS itself under /Volumes: its
disks are the IOMedia below its USB device in the IORegistry ("BSD Name"), and where each is
mounted is asked of `diskutil info` (DiskArbitration). It is ejected with `diskutil eject`.

A device another program holds for itself (Garmin Express Service, which keeps a connected
watch while it runs) is never asked to let go: opening it with libusb would ask the system to
take it from that program (USBDeviceOpenSeize). It is said by name instead (DeviceInUse).
macOS's camera service, ptpcamerad, which runs as the user, takes a PTP or MTP device for Image
Capture and Photos: it is paused (SIGSTOP) while the program has the device and goes on
(SIGCONT) when the device is closed, at exit and on SIGTERM, SIGHUP or SIGQUIT. Each process that
has it paused holds a lock file, shared, which the system lets go of with the process however
it ends: ptpcamerad goes on only once no process holds it, and one left stopped by a process
that was killed is woken at the next start (wake_camera_daemon_left_stopped).
"""

from __future__ import annotations

import atexit
import contextlib
import ctypes
import fcntl
import logging
import os
import plistlib
import signal
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field, replace
from pathlib import Path

from openexpress import applog
from openexpress.device import ptp
from openexpress.device.found import (
    GARMIN_VID,
    MASS_STORAGE,
    MASS_STORAGE_CLASS,
    PRESENT,
    STARTING,
    STARTING_PRODUCT,
    DeviceInUse,
    DriveNotMounted,
    GarminUsb,
    classify,
)
from openexpress.device.storage import DeviceError

log = logging.getLogger(__name__)

GARMIN_VENDOR = int(GARMIN_VID, 16)

_LIBUSB_ERROR_ACCESS = -3
_LIBUSB_ERROR_BUSY = -6
IOREG = "/usr/sbin/ioreg"
DISKUTIL = "/usr/sbin/diskutil"
KILLALL = "/usr/bin/killall"
PS = "/bin/ps"
TOOL_TIMEOUT_S = 10


class _DeviceDescriptor(ctypes.Structure):
    _fields_ = [("bLength", ctypes.c_uint8), ("bDescriptorType", ctypes.c_uint8),
                ("bcdUSB", ctypes.c_uint16), ("bDeviceClass", ctypes.c_uint8),
                ("bDeviceSubClass", ctypes.c_uint8), ("bDeviceProtocol", ctypes.c_uint8),
                ("bMaxPacketSize0", ctypes.c_uint8), ("idVendor", ctypes.c_uint16),
                ("idProduct", ctypes.c_uint16), ("bcdDevice", ctypes.c_uint16),
                ("iManufacturer", ctypes.c_uint8), ("iProduct", ctypes.c_uint8),
                ("iSerialNumber", ctypes.c_uint8), ("bNumConfigurations", ctypes.c_uint8)]


def _libusb():
    """libusb (ptp.load_libusb), with the calls that list devices without opening them."""
    lib = ptp.load_libusb()
    lib.libusb_get_device_descriptor.restype = ctypes.c_int
    lib.libusb_get_device_descriptor.argtypes = [ctypes.c_void_p,
                                                 ctypes.POINTER(_DeviceDescriptor)]
    lib.libusb_get_port_numbers.restype = ctypes.c_int
    lib.libusb_get_port_numbers.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8),
                                            ctypes.c_int]
    return lib


def _port(lib, device, bus: int) -> tuple[int, ...]:
    """Where a device is plugged in: its bus, then the port at each hub on the way (as the
    IORegistry's location ID), which stays when the device comes back under another address;
    () when libusb cannot tell."""
    ports = (ctypes.c_uint8 * 8)()
    count = lib.libusb_get_port_numbers(device, ports, len(ports))
    return (bus, *ports[:count]) if count > 0 else ()


# --- who holds a device: the IORegistry ----------------------------------------------------

@dataclass(frozen=True)
class Holder:
    """A program that holds a USB device for itself (the IORegistry's UsbExclusiveOwner)."""

    name: str
    pid: int | None = None

    @property
    def camera_daemon(self) -> bool:
        """macOS's camera service, which this program pauses (pause_camera_daemon)."""
        return self.name == CAMERA_DAEMON

    @property
    def this_process(self) -> bool:
        return self.pid == os.getpid()


@dataclass(frozen=True)
class _Registered:
    """What the IORegistry tells of a USB device that libusb does not."""

    name: str | None = None  # the name it gives itself (its product string)
    serial: str | None = field(default=None, repr=False)
    holder: Holder | None = None
    # The BSD names of the disks of a drive that hold a filesystem (the IOMedia below it that
    # are leaves: a partition, or a whole disk without partitions).
    media: tuple[str, ...] = ()


# The name of the program of each process ID asked (_program_name), so that `ps` is not run
# again for a holder seen at every look: by (pid, the IORegistry's short name).
_names: dict[tuple[int, str], str] = {}
_names_lock = threading.Lock()
# What another process of the program is named as a holder (_program_name).
OUR_NAME = "openExpress"


def _program_name(pid: int, short: str) -> str:
    """The name of the program with this process ID (the IORegistry cuts it at 16
    characters: "Garmin Express S"); `short` when it cannot be told. Another openexpress
    process (the app's engine, a command in a Terminal) is "openExpress" (OUR_NAME), not the
    "Python" that runs it. Asked once a process (_names)."""
    with _names_lock:
        known = _names.get((pid, short))
    if known is not None:
        return known
    name = _ask_program_name(pid, short)
    with _names_lock:
        if len(_names) > 64:
            _names.clear()
        _names[(pid, short)] = name
    return name


def _ask_program_name(pid: int, short: str) -> str:
    try:
        path = subprocess.run([PS, "-p", str(pid), "-o", "comm="], capture_output=True,
                              text=True, timeout=TOOL_TIMEOUT_S, check=False).stdout.strip()
        args = subprocess.run([PS, "-p", str(pid), "-o", "args="], capture_output=True,
                              text=True, timeout=TOOL_TIMEOUT_S, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return short
    if any(os.path.basename(word) == "openexpress" or word == "openexpress"
           for word in args.split()[:3]):
        return OUR_NAME
    name = os.path.basename(path)
    return name if name.startswith(short) else short


def parse_holder(owner) -> Holder | None:
    """The holder of a device from the IORegistry's UsbExclusiveOwner ("pid 97373, Garmin
    Express S"); None when there is none."""
    if not isinstance(owner, str) or not owner.strip():
        return None
    head, _comma, short = owner.partition(",")
    words = head.split()
    pid = int(words[1]) if len(words) == 2 and words[0] == "pid" and words[1].isdigit() else None
    short = short.strip() or owner.strip()
    return Holder(_program_name(pid, short) if pid is not None else short, pid)


def _walk(entries):
    for entry in entries:
        yield entry
        yield from _walk(entry.get("IORegistryEntryChildren", []))


def registered_devices(read=None) -> dict[tuple[int, int], _Registered]:
    """What the IORegistry tells of each Garmin device on USB, by its place as libusb numbers
    it (bus: the top byte of its location ID; device number: its USB address). Empty when
    `ioreg` cannot be read. `read`: the plist ioreg writes (tests)."""
    return _registry(read, {(GARMIN_VENDOR, None)})


def _read_registry() -> bytes | None:
    try:
        return subprocess.run([IOREG, "-a", "-r", "-c", "IOUSBHostDevice", "-l", "-w0"],
                              capture_output=True, timeout=TOOL_TIMEOUT_S, check=False).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        log.info("USB: the IORegistry could not be read (%s)", type(e).__name__)
        return None


def _media(entry) -> tuple[str, ...]:
    """The BSD names of the IOMedia below a USB device that are leaves (each holds a
    filesystem, not partitions), disk4s2 before disk4s10."""
    names = {e["BSD Name"] for e in _walk(entry.get("IORegistryEntryChildren", []))
             if e.get("IOObjectClass") == "IOMedia" and e.get("Leaf") is True
             and isinstance(e.get("BSD Name"), str)}
    return tuple(sorted(names, key=lambda name: (len(name), name)))


def _registry(read, wanted: set[tuple[int, int | None]]) -> dict[tuple[int, int], _Registered]:
    """registered_devices for the USB devices of `wanted`: (vendor, product), product None for
    any of the vendor."""
    if read is None:
        read = _read_registry()
        if read is None:
            return {}
    try:
        entries = plistlib.loads(read) if read else []
    except Exception as e:  # noqa: BLE001 - only the names and the holder depend on it
        log.info("USB: the IORegistry could not be read (%s)", type(e).__name__)
        return {}
    found = {}
    for entry in _walk(entries if isinstance(entries, list) else [entries]):
        vendor = entry.get("idVendor")
        if "USB Address" not in entry or ((vendor, None) not in wanted
                                          and (vendor, entry.get("idProduct")) not in wanted):
            continue
        place = (int(entry.get("locationID", 0)) >> 24, int(entry["USB Address"]))
        holder = parse_holder(entry.get("UsbExclusiveOwner"))
        for child in entry.get("IORegistryEntryChildren", []):
            holder = holder or parse_holder(child.get("UsbExclusiveOwner"))
        serial = entry.get("USB Serial Number") or entry.get("kUSBSerialNumberString")
        found[place] = _Registered(entry.get("USB Product Name") or None,
                                   serial if isinstance(serial, str) and serial else None,
                                   holder, _media(entry))
    return found


def holder_of(bus: int, address: int) -> Holder | None:
    """The program that holds the device at this place on USB for itself; None when none does
    or it cannot be told."""
    registered = registered_devices().get((bus, address))
    return registered.holder if registered is not None else None


# --- the Garmin devices on USB: libusb ------------------------------------------------------

@dataclass(frozen=True)
class UsbDevice:
    """A Garmin device on USB, as its descriptors and the IORegistry tell it."""

    bus: int
    address: int
    product: str  # the USB product ID, four hexadecimal digits ("51b8")
    # The class of each interface of its active configuration, as /sys writes them ("ff"),
    # and whether one of them, not of mass storage, has a bulk endpoint each way: the file
    # transfer interface of MTP (or PTP) that ptp claims.
    classes: tuple[str, ...] = ()
    file_transfer: bool = False
    name: str | None = None
    serial: str | None = field(default=None, repr=False)
    holder: Holder | None = None
    # Garmin's, or that of the USB drive named for testing (found.TEST_DRIVE_ENV).
    vendor: str = GARMIN_VID
    port: tuple[int, ...] = ()  # where it is plugged in (_port); () when not known
    media: tuple[str, ...] = ()  # of a drive: the BSD names of its disks (_Registered.media)

    @property
    def usb_id(self) -> str:
        return f"{self.vendor}:{self.product}"

    @property
    def mode(self) -> str:
        """STARTING: 091e:0003, its Garmin USB mode (where a watch is for a while after it is
        plugged in); MASS_STORAGE: a drive only; UNSUPPORTED: HID, or HID beside mass storage;
        PRESENT: anything else, as a device offering MTP is."""
        if self.product == STARTING_PRODUCT:
            return STARTING
        return classify(list(self.classes)) or PRESENT

    def garmin_usb(self) -> GarminUsb:
        """The device as the rest of the program knows one, its serial hidden in the log at
        once (as private as its unit ID)."""
        usb = GarminUsb(self.product, self.bus, self.address, serial=self.serial,
                        vendor=self.vendor)
        applog.hide_usb(usb)
        return usb


def _interfaces(lib, device) -> tuple[tuple[str, ...], bool]:
    """(the class of each interface, whether one that is not mass storage has bulk endpoints
    both ways) of a device's active configuration, read without opening it; ((), False) when
    libusb cannot tell."""
    config = ctypes.POINTER(ptp._Config)()
    if lib.libusb_get_active_config_descriptor(device, ctypes.byref(config)) < 0:
        return (), False
    try:
        classes, transfer = [], False
        for i in range(config.contents.bNumInterfaces):
            interface = config.contents.interface[i]
            if interface.num_altsetting < 1:
                continue
            alt = interface.altsetting[0]
            cls = f"{alt.bInterfaceClass:02x}"
            classes.append(cls)
            directions = {alt.endpoint[e].bEndpointAddress & 0x80
                          for e in range(alt.bNumEndpoints)
                          if alt.endpoint[e].bmAttributes & 3 == 2}  # bulk
            transfer = transfer or (cls != MASS_STORAGE_CLASS and len(directions) == 2)
        return tuple(classes), transfer
    finally:
        lib.libusb_free_config_descriptor(config)


# While nothing else changed, how often the IORegistry is read again for a device another
# program holds (garmin_devices with `reuse`): to see that it let go.
HELD_LOOK_S = 10.0


@dataclass
class _Look:
    """What the IORegistry told at the last look (registered_devices), of the Garmin devices
    then on USB: (bus, address, product) of each."""

    devices: frozenset
    registered: dict
    at: float


_last_look: _Look | None = None
_look_lock = threading.Lock()
_clock = time.monotonic


def look_again() -> None:
    """The next garmin_devices with `reuse` reads the IORegistry (a holder may have come)."""
    global _last_look
    with _look_lock:
        _last_look = None


def _registered(found: list[UsbDevice], reuse: bool) -> dict:
    """registered_devices() for the devices libusb found; with `reuse`, what the last look
    told while the same Garmin devices are on USB (bus, address and product), unless another
    program than this one held one of them then and HELD_LOOK_S went by."""
    global _last_look
    devices = frozenset((d.bus, d.address, d.product) for d in found)
    with _look_lock:
        last = _last_look
    if reuse and last is not None and last.devices == devices:
        held = any(r.holder is not None and not r.holder.this_process
                   for r in last.registered.values())
        if not held or _clock() - last.at < HELD_LOOK_S:
            return last.registered
    registered = registered_devices()
    with _look_lock:
        _last_look = _Look(devices, registered, _clock())
    return registered


_context_lock = threading.Lock()
_context: ctypes.c_void_p | None = None


def _context_of_the_process(lib) -> ctypes.c_void_p | None:
    """One libusb context for the life of the process, never exited: on macOS libusb stops its
    thread of USB events in the libusb_exit of its last context, and a device coming or going
    at that moment deadlocks both (seen with an Edge 1040 plugged in again while the engine
    looked at USB). With this one kept, the context of a transport is never the last."""
    global _context
    with _context_lock:
        if _context is None:
            context = ctypes.c_void_p()
            if lib.libusb_init(ctypes.byref(context)) < 0:
                return None
            _context = context
        return _context


def garmin_devices(reuse: bool = False) -> list[UsbDevice]:
    """Every Garmin device on USB (vendor 091e), whatever mode it is in, in the order libusb
    lists them, with what the IORegistry tells of each (its name, serial and holder). Nothing
    is opened or sent to a device. Empty when libusb is not there (said in the log once).
    `reuse` (the engine's polling): the IORegistry is read again only when the Garmin devices
    on USB changed, or a while after another program was seen holding one (_registered)."""
    found = _on_usb({(GARMIN_VENDOR, None)})
    if not found:
        return []
    registered = _registered(found, reuse)
    return [_with(device, registered) for device in found]


def drive_devices(test_drive: tuple[str, str] | None = None) -> list[UsbDevice]:
    """The Garmin devices on USB in mass storage mode (drives), and the USB drive named for
    testing (`test_drive`: its vendor and product, found.test_drive_ids), with the disks of
    each (`media`) as the IORegistry tells them now: read anew at each call, as a disk comes a
    moment after its device and is gone once it is ejected. Nothing is opened."""
    wanted: set[tuple[int, int | None]] = {(GARMIN_VENDOR, None)}
    if test_drive is not None:
        wanted.add((int(test_drive[0], 16), int(test_drive[1], 16)))
    found = [d for d in _on_usb(wanted) if d.mode == MASS_STORAGE]
    if not found:
        return []
    registered = _registry(None, wanted)
    return [_with(device, registered) for device in found]


def _with(device: UsbDevice, registered: dict) -> UsbDevice:
    known = registered.get((device.bus, device.address), _Registered())
    return replace(device, name=known.name, serial=known.serial, holder=known.holder,
                   media=known.media)


def _on_usb(wanted: set[tuple[int, int | None]]) -> list[UsbDevice]:
    """The USB devices of `wanted` ((vendor, product), product None for any of the vendor), in
    the order libusb lists them: their descriptors only. Empty when libusb is not there (said
    in the log once)."""
    try:
        lib = _libusb()
    except ptp.UsbUnavailable as e:
        _say_once("libusb", "USB: no libusb, no device can be found: %s", e)
        return []
    context = _context_of_the_process(lib)
    if context is None:
        return []
    found = []
    devices = ctypes.POINTER(ctypes.c_void_p)()
    count = lib.libusb_get_device_list(context, ctypes.byref(devices))
    if count < 0:
        return []
    try:
        for i in range(count):
            device = ctypes.c_void_p(devices[i])
            descriptor = _DeviceDescriptor()
            if lib.libusb_get_device_descriptor(device, ctypes.byref(descriptor)) < 0:
                continue
            if ((descriptor.idVendor, None) not in wanted
                    and (descriptor.idVendor, descriptor.idProduct) not in wanted):
                continue
            classes, transfer = _interfaces(lib, device)
            bus = lib.libusb_get_bus_number(device)
            found.append(UsbDevice(bus, lib.libusb_get_device_address(device),
                                   f"{descriptor.idProduct:04x}", classes, transfer,
                                   vendor=f"{descriptor.idVendor:04x}",
                                   port=_port(lib, device, bus)))
    finally:
        lib.libusb_free_device_list(devices, 1)
    return found


_said: set[str] = set()


def _say_once(key: str, *message) -> None:
    if key not in _said:
        _said.add(key)
        log.info(*message)


# --- the disks of a drive: diskutil (DiskArbitration) ---------------------------------------

DISK_TIMEOUT_S = 60  # a mount or an eject: the system writes out what it holds first


@dataclass(frozen=True)
class Volume:
    """A disk of a drive as `diskutil info` tells it."""

    bsd: str  # its BSD name ("disk4s1")
    whole: str  # the BSD name of the whole disk it is on ("disk4")
    mount_point: str | None  # where macOS mounted it; None: not mounted
    name: str | None = None  # the name of the volume ("GARMIN")
    uuid: str | None = field(default=None, repr=False)  # of its filesystem, when it has one
    internal: bool = False  # a disk inside the Mac: never a drive's


def _diskutil(*args: str, timeout: float = TOOL_TIMEOUT_S) -> subprocess.CompletedProcess:
    """A run of diskutil; OSError or subprocess.TimeoutExpired when it cannot be run."""
    return subprocess.run([DISKUTIL, *args], capture_output=True, timeout=timeout, check=False)


def volume_info(disk: str) -> Volume | None:
    """The disk with this BSD name ("disk4s1"), or the volume mounted at this folder, as
    `diskutil info` tells it; None when there is none (gone, or never there) or diskutil cannot
    be run."""
    try:
        done = _diskutil("info", "-plist", disk)
    except (OSError, subprocess.TimeoutExpired) as e:
        log.info("drive: diskutil could not be run (%s)", type(e).__name__)
        return None
    if done.returncode != 0 or not done.stdout:
        return None
    try:
        info = plistlib.loads(done.stdout)
    except Exception as e:  # noqa: BLE001 - not a disk then
        log.info("drive: what diskutil said could not be read (%s)", type(e).__name__)
        return None

    def text(key: str) -> str | None:
        value = info.get(key) if isinstance(info, dict) else None
        return value if isinstance(value, str) and value else None

    bsd = text("DeviceIdentifier")
    if bsd is None:
        return None
    return Volume(bsd, text("ParentWholeDisk") or bsd, text("MountPoint"), text("VolumeName"),
                  text("VolumeUUID"), info.get("Internal") is True)


def _refused(what: str, done: subprocess.CompletedProcess) -> DeviceError:
    said = (done.stderr or done.stdout or b"").decode("utf-8", "replace").strip()
    return DeviceError(f"{what}: {said.splitlines()[-1] if said else done.returncode}")


def mount_volume(disk: str, what: str) -> None:
    """The disk with this BSD name mounted where macOS mounts it (`diskutil mount`);
    DeviceError (`what`, then why) when it cannot be."""
    try:
        done = _diskutil("mount", disk, timeout=DISK_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise DeviceError(f"{what}: {type(e).__name__}") from e
    if done.returncode != 0:
        raise _refused(what, done)


def eject_drive_at(mount_point: str, what: str, not_mounted: str) -> Volume:
    """The drive whose volume is mounted at this folder ejected: `diskutil eject` of its whole
    disk unmounts every volume of it, writes out what the system holds and tells the device
    that it may go. Its volume as it was. DriveNotMounted (`not_mounted`) when no volume of a
    disk outside the Mac is mounted there any more; DeviceError (`what`, then why) when macOS
    refuses, e.g. while a program uses the drive."""
    volume = volume_info(mount_point)
    if (volume is None or volume.internal or volume.mount_point is None
            or os.path.realpath(volume.mount_point) != os.path.realpath(mount_point)):
        raise DriveNotMounted(not_mounted)
    try:
        done = _diskutil("eject", volume.whole, timeout=DISK_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise DeviceError(f"{what}: {type(e).__name__}") from e
    if done.returncode != 0:
        raise _refused(what, done)
    return volume


# --- the device to ourselves ----------------------------------------------------------------

# How long a process waits for another process of the program (the app's engine, which keeps
# a device open a few seconds after its last request) to let go of a device it wants.
HANDOVER_WAIT_S = 15.0
HANDOVER_EVERY_S = 0.5


def want_lock_path(bus: int, address: int) -> Path:
    """The lock file of the processes that wait for the device at this place on USB while
    another process of the program holds it (held shared while they wait); the one that holds
    it lets that device go when it sees the lock held (wanted_elsewhere), and only that one."""
    name = f"openexpress-{os.getuid()}-want-{bus:03d}-{address:03d}.lock"
    return Path(tempfile.gettempdir()) / name


def wanted_elsewhere(bus: int, address: int) -> bool:
    """Whether another process of the program waits for the device at this place on USB
    (holds its want lock); no program is run for it."""
    try:
        fd = os.open(want_lock_path(bus, address), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC,
                     0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        os.close(fd)
    return False


def _handed_over(bus: int, address: int, holder: Holder) -> Holder | None:
    """The holder of the device once another process of the program that held it let go, the
    want lock held meanwhile (at most HANDOVER_WAIT_S): None when nothing holds it then."""
    try:
        fd = os.open(want_lock_path(bus, address), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC,
                     0o600)
    except OSError:
        return holder
    try:
        fcntl.flock(fd, fcntl.LOCK_SH)
        log.info("USB: the device is held by another openExpress process; waiting for it")
        deadline = _clock() + HANDOVER_WAIT_S
        while holder is not None and holder.name == OUR_NAME and not holder.this_process \
                and _clock() < deadline:
            _sleep(HANDOVER_EVERY_S)
            holder = holder_of(bus, address)
        return holder
    finally:
        os.close(fd)


def check_free(bus: int, address: int) -> None:
    """DeviceInUse when another program than this one and the camera service holds the device
    at this place on USB; nothing is asked of the device. Another process of the program is
    waited for a while: it lets go when it sees that one waits (wanted_elsewhere)."""
    holder = holder_of(bus, address)
    if holder is not None and holder.name == OUR_NAME and not holder.this_process:
        holder = _handed_over(bus, address, holder)
    if holder is not None and not holder.this_process and not holder.camera_daemon:
        log.info("USB: the device is held by %s (pid %s); not taken from it", holder.name,
                 holder.pid if holder.pid is not None else "?")
        raise DeviceInUse(holder)


class MacTransport(ptp.LibusbTransport):
    """The transport of ptp on macOS: the camera service is paused before the interface is
    claimed, and a claim refused while something lets go of the device is tried again a few
    times; the camera service goes on once the transport is closed."""

    @classmethod
    def _claim_interface(cls, lib, handle, interface: int) -> None:
        pause_camera_daemon()
        try:
            for wait in (*CLAIM_WAITS_S, None):
                result = lib.libusb_claim_interface(handle, interface)
                if result >= 0:
                    return  # the camera service stays paused until close()
                if result not in (_LIBUSB_ERROR_ACCESS, _LIBUSB_ERROR_BUSY) or wait is None:
                    cls._check(lib, result)
                log.info("USB: the interface is in use, tried again in %.2f s", wait)
                _sleep(wait)
        except BaseException:
            resume_camera_daemon()
            raise

    def close(self) -> None:
        claimed = bool(self._handle)
        super().close()
        if claimed:
            resume_camera_daemon()


# The waits before each new try of a claim refused (LIBUSB_ERROR_ACCESS or BUSY).
CLAIM_WAITS_S = (0.25, 0.5, 1.0, 2.0)
_sleep = time.sleep


def open_transport(bus: int, address: int) -> MacTransport:
    """The file transfer interface of the device at this place on USB, claimed: DeviceInUse
    when another program holds the device (looked at before it is opened, and again when the
    claim is refused); UsbUnavailable for anything else."""
    check_free(bus, address)
    try:
        return MacTransport.open(bus, address)
    except ptp.UsbUnavailable as e:
        if e.code in (_LIBUSB_ERROR_ACCESS, _LIBUSB_ERROR_BUSY):
            holder = holder_of(bus, address)
            if holder is not None and not holder.this_process:
                raise DeviceInUse(holder) from e
        raise


# --- macOS's camera service -----------------------------------------------------------------

CAMERA_DAEMON = "ptpcamerad"
_paused = 0  # how many transports have it paused
_pause_lock = threading.RLock()
_hooks = False  # atexit and the signal handlers are in place
_held: int | None = None  # the descriptor of the lock file, held shared while it is paused
PGREP = "/usr/bin/pgrep"


def pause_lock_path() -> Path:
    """The lock file of the processes that have ptpcamerad paused: in the user's own temporary
    folder (on macOS $TMPDIR is the user's)."""
    return Path(tempfile.gettempdir()) / f"openexpress-{os.getuid()}-ptpcamerad.lock"


def _open_pause_lock() -> int:
    """The lock file opened (made if it is not there); OSError when it cannot be."""
    return os.open(pause_lock_path(), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)


def _hold() -> None:
    """The lock file held shared by this process (waited for while another one is waking
    ptpcamerad, a moment); nothing when it cannot be opened."""
    global _held
    if _held is not None:
        return
    try:
        fd = _open_pause_lock()
    except OSError as e:
        log.info("USB: the lock of %s not held (%s)", CAMERA_DAEMON, type(e).__name__)
        return
    fcntl.flock(fd, fcntl.LOCK_SH)
    _held = fd


def _let_go() -> None:
    global _held
    if _held is not None:
        os.close(_held)  # the lock goes with it
        _held = None


@contextlib.contextmanager
def _nobody_pausing():
    """True for the block when no process holds the lock file (then none comes to hold it
    until the block ends); False when one does. True when the file cannot be opened: nothing
    tells of another process."""
    try:
        fd = _open_pause_lock()
    except OSError:
        yield True
        return
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        os.close(fd)


def _go_on() -> bool:
    """SIGCONT to ptpcamerad, once this process lets go of the lock, unless another process
    still has it paused; whether it was sent and got."""
    _let_go()
    with _nobody_pausing() as nobody:
        return _signal_daemon("CONT") if nobody else False


def daemon_stopped() -> bool:
    """Whether a ptpcamerad of this user is stopped (state T); False when not known."""
    try:
        pids = subprocess.run([PGREP, "-x", "-U", str(os.getuid()), CAMERA_DAEMON],
                              capture_output=True, text=True, timeout=TOOL_TIMEOUT_S,
                              check=False).stdout.split()
        if not pids:
            return False
        states = subprocess.run([PS, "-o", "stat=", "-p", ",".join(pids)], capture_output=True,
                                text=True, timeout=TOOL_TIMEOUT_S, check=False).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        return False
    return any(state.startswith("T") for state in states)


def wake_camera_daemon_left_stopped() -> bool:
    """At the start of the program on macOS: a ptpcamerad left stopped by a process of ours
    that ended without letting it go on (killed) goes on, unless a process of ours still has it
    paused. Whether it was woken."""
    if not daemon_stopped():
        return False
    with _nobody_pausing() as nobody:
        if not nobody:
            return False
        woken = _signal_daemon("CONT")
    if woken:
        log.info("USB: %s was left stopped, it goes on", CAMERA_DAEMON)
    return woken


def _signal_daemon(name: str) -> bool:
    """Send SIGSTOP or SIGCONT (`name`: "STOP", "CONT") to ptpcamerad; whether one got it."""
    try:
        done = subprocess.run([KILLALL, f"-{name}", CAMERA_DAEMON], capture_output=True,
                              timeout=TOOL_TIMEOUT_S, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        log.warning("USB: %s could not be sent to %s (%s)", name, CAMERA_DAEMON,
                    type(e).__name__)
        return False
    return done.returncode == 0


def pause_camera_daemon() -> None:
    """ptpcamerad paused (SIGSTOP) until resume_camera_daemon is called as often; it goes on
    at exit whatever happens before."""
    global _paused
    with _pause_lock:
        _paused += 1
        if _paused > 1:
            return
        _install_hooks()
        _hold()  # before the signal: a process starting meanwhile does not wake it
        stopped = _signal_daemon("STOP")
    log.info("USB: %s %s", CAMERA_DAEMON, "paused" if stopped else "not running")


def resume_camera_daemon() -> None:
    global _paused
    with _pause_lock:
        if _paused == 0:
            return
        _paused -= 1
        if _paused:
            return
        went_on = _go_on()
    if went_on:
        log.info("USB: %s goes on", CAMERA_DAEMON)


def resume_camera_daemon_now() -> None:
    """ptpcamerad goes on now, whatever still has it paused (at exit, on a signal)."""
    global _paused
    with _pause_lock:
        if _paused == 0:
            return
        _paused = 0
        _go_on()


# The signals that end the program without its exit handlers: the camera service goes on first.
RESUME_ON = ("SIGTERM", "SIGHUP", "SIGQUIT")


def _install_hooks() -> None:
    global _hooks
    if _hooks:
        return
    _hooks = True
    atexit.register(resume_camera_daemon_now)
    if threading.current_thread() is not threading.main_thread():
        return  # handlers can be set in the main thread only; atexit stays
    for name in RESUME_ON:
        number = getattr(signal, name, None)
        if number is None:
            continue
        previous = signal.getsignal(number)
        signal.signal(number, lambda signum, frame, previous=previous:
                      _on_signal(signum, frame, previous))


def _on_signal(signum, frame, previous) -> None:
    """The camera service goes on at once; then what the signal did before: a handler of the
    program's own, nothing (ignored), or the end of the program, through its exit handlers
    (SystemExit, so that the device is closed as well)."""
    resume_camera_daemon_now()
    if callable(previous):
        previous(signum, frame)
    elif previous != signal.SIG_IGN:
        raise SystemExit(128 + signum)
