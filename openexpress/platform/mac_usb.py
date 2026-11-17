"""The Garmin devices on USB on macOS, where there is no /sys and no gvfs: found through libusb
(ptp.load_libusb), their descriptors only, never opened to be looked at; what libusb does not
tell (the name a device gives itself, its serial, the program that holds it) is read from the
IORegistry (`ioreg`), which opens nothing either.

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
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from openexpress import applog
from openexpress.device import ptp
from openexpress.device.found import (
    GARMIN_VID,
    MASS_STORAGE,
    PRESENT,
    STARTING,
    STARTING_PRODUCT,
    UNSUPPORTED,
    GarminUsb,
)
from openexpress.i18n import _

log = logging.getLogger(__name__)

GARMIN_VENDOR = int(GARMIN_VID, 16)
# The classes of USB interfaces, as /sys writes them (report.INTERFACES names them).
HID_CLASS, STILL_IMAGE_CLASS, MASS_STORAGE_CLASS = "03", "06", "08"

_LIBUSB_ERROR_ACCESS = -3
_LIBUSB_ERROR_BUSY = -6
IOREG = "/usr/sbin/ioreg"
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
    return lib


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


def _program_name(pid: int, short: str) -> str:
    """The name of the program with this process ID (the IORegistry cuts it at 16
    characters: "Garmin Express S"); `short` when it cannot be told."""
    try:
        path = subprocess.run([PS, "-p", str(pid), "-o", "comm="], capture_output=True,
                              text=True, timeout=TOOL_TIMEOUT_S, check=False).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return short
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
    if read is None:
        try:
            read = subprocess.run([IOREG, "-a", "-r", "-c", "IOUSBHostDevice", "-l", "-w0"],
                                  capture_output=True, timeout=TOOL_TIMEOUT_S,
                                  check=False).stdout
        except (OSError, subprocess.TimeoutExpired) as e:
            log.info("USB: the IORegistry could not be read (%s)", type(e).__name__)
            return {}
    try:
        entries = plistlib.loads(read) if read else []
    except Exception as e:  # noqa: BLE001 - only the names and the holder depend on it
        log.info("USB: the IORegistry could not be read (%s)", type(e).__name__)
        return {}
    found = {}
    for entry in _walk(entries if isinstance(entries, list) else [entries]):
        if entry.get("idVendor") != GARMIN_VENDOR or "USB Address" not in entry:
            continue
        place = (int(entry.get("locationID", 0)) >> 24, int(entry["USB Address"]))
        holder = parse_holder(entry.get("UsbExclusiveOwner"))
        for child in entry.get("IORegistryEntryChildren", []):
            holder = holder or parse_holder(child.get("UsbExclusiveOwner"))
        serial = entry.get("USB Serial Number") or entry.get("kUSBSerialNumberString")
        found[place] = _Registered(entry.get("USB Product Name") or None,
                                   serial if isinstance(serial, str) and serial else None,
                                   holder)
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

    @property
    def usb_id(self) -> str:
        return f"{GARMIN_VID}:{self.product}"

    @property
    def mode(self) -> str:
        """STARTING: 091e:0003, its Garmin USB mode (where a watch is for a while after it is
        plugged in); MASS_STORAGE: a drive only; UNSUPPORTED: HID, or HID beside mass storage;
        PRESENT: anything else, as a device offering MTP is."""
        if self.product == STARTING_PRODUCT:
            return STARTING
        if self.classes and all(c == MASS_STORAGE_CLASS for c in self.classes):
            return MASS_STORAGE
        if HID_CLASS in self.classes and all(c in (HID_CLASS, MASS_STORAGE_CLASS)
                                             for c in self.classes):
            return UNSUPPORTED
        return PRESENT

    def garmin_usb(self) -> GarminUsb:
        """The device as the rest of the program knows one, its serial hidden in the log at
        once (as private as its unit ID)."""
        usb = GarminUsb(self.product, self.bus, self.address, serial=self.serial)
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


def garmin_devices() -> list[UsbDevice]:
    """Every Garmin device on USB (vendor 091e), whatever mode it is in, in the order libusb
    lists them. Nothing is opened or sent to a device. Empty when libusb is not there (said in
    the log once)."""
    try:
        lib = _libusb()
    except ptp.UsbUnavailable as e:
        _say_once("libusb", "USB: no libusb, no device can be found: %s", e)
        return []
    context = ctypes.c_void_p()
    if lib.libusb_init(ctypes.byref(context)) < 0:
        return []
    found = []
    try:
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
                if descriptor.idVendor != GARMIN_VENDOR:
                    continue
                classes, transfer = _interfaces(lib, device)
                found.append(UsbDevice(lib.libusb_get_bus_number(device),
                                       lib.libusb_get_device_address(device),
                                       f"{descriptor.idProduct:04x}", classes, transfer))
        finally:
            lib.libusb_free_device_list(devices, 1)
    finally:
        lib.libusb_exit(context)
    if not found:
        return []
    registered = registered_devices()
    out = []
    for device in found:
        known = registered.get((device.bus, device.address), _Registered())
        out.append(UsbDevice(device.bus, device.address, device.product, device.classes,
                             device.file_transfer, known.name, known.serial, known.holder))
    return out


_said: set[str] = set()


def _say_once(key: str, *message) -> None:
    if key not in _said:
        _said.add(key)
        log.info(*message)


# --- the device to ourselves ----------------------------------------------------------------

class DeviceInUse(ptp.UsbUnavailable):
    """Another program holds the device for itself: it is not taken from it. The text names
    the program and says what to do."""

    def __init__(self, holder: Holder):
        self.holder = holder
        if holder.camera_daemon:
            # TRANSLATORS: macOS: its camera service holds the device; "ptpcamerad" is the
            # name of a program, not to be translated
            text = _("macOS's camera service (ptpcamerad) is using the device, for Image "
                     "Capture or Photos. Quit them, then unplug the device and plug it in "
                     "again.")
        else:
            # TRANSLATORS: macOS: another program (e.g. "Garmin Express Service") holds the
            # device, so openExpress cannot open it
            text = _("{program} is using the device. Quit it, then try again.").format(
                program=holder.name)
        super().__init__(text)


def check_free(bus: int, address: int) -> None:
    """DeviceInUse when another program than this one and the camera service holds the device
    at this place on USB; nothing is asked of the device."""
    holder = holder_of(bus, address)
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


def _hold() -> None:
    """The lock file held shared by this process (waited for while another one is waking
    ptpcamerad, a moment); nothing when it cannot be opened."""
    global _held
    if _held is not None:
        return
    try:
        fd = os.open(pause_lock_path(), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
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
        fd = os.open(pause_lock_path(), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
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
    if sys.platform != "darwin" or not daemon_stopped():
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
    if sys.platform != "darwin":
        return False
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
