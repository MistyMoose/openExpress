"""What is found of a Garmin device on USB, the same on every system: where it is on USB, what a
list of the devices connected shows of each, the states a device on USB may be in and the
errors of a device that cannot be opened. Without GIO (PyGObject) or any other system's
library, so that the program finds and opens devices where there is none (macOS:
mac_storage); gio_storage gives the same names, for what imports them from there.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from openexpress.device import ptp
from openexpress.device.storage import DeviceError
from openexpress.errors import OrdinaryStop
from openexpress.i18n import _, pgettext

GARMIN_VID = "091e"


@dataclass(frozen=True)
class GarminUsb:
    """A Garmin device on USB. `product` is the USB product ID, when it is known."""

    product: str | None
    # Where the device is on USB, when known; not part of what the device is.
    bus: int | None = field(default=None, compare=False)
    address: int | None = field(default=None, compare=False)
    # What tells a drive from another of its model while nothing of it is read, so that two of
    # them are not taken for one: its USB serial (None: it gives none, as a Varia Rearview
    # Radar) and the UUID of its volume. As private as its unit ID (a fēnix 8's serial is its
    # unit ID): never shown, and hidden in the log as soon as they are read (applog.hide_usb).
    serial: str | None = field(default=None, compare=False, repr=False)
    volume_uuid: str | None = field(default=None, compare=False, repr=False)
    # Garmin's; another only for the drive named for testing (TEST_DRIVE_ENV), so that the log
    # names it by the vendor it has.
    vendor: str = field(default=GARMIN_VID, compare=False)
    # Where /sys cannot be read, the place on USB the address or the volume tells (bus, device
    # number): not checked, so never taken for `bus` and `address`; only what tells one
    # connection of the device from the next (history).
    told_place: tuple[int, int] | None = field(default=None, compare=False, repr=False)

    @property
    def usb_id(self) -> str:
        return f"{self.vendor}:{self.product or 'unknown'}"

    @property
    def for_testing(self) -> bool:
        """The drive named in TEST_DRIVE_ENV: of another vendor than Garmin."""
        return self.vendor != GARMIN_VID


@dataclass
class FoundDevice:
    uri: str
    name: str
    mounted: bool
    volume: object | None = None  # its Gio.Volume, where GIO finds devices
    usb: GarminUsb | None = None
    kind: str = "mtp"  # "mtp", or "ums" for a Garmin device in mass storage mode (a drive)


def usb_place(usb: GarminUsb | None) -> tuple[int, int] | None:
    """Where a device is on USB (bus, device number); None when not known."""
    if usb is None or usb.bus is None or usb.address is None:
        return None
    return usb.bus, usb.address


# The older form of gvfs's addresses, which carries the place on USB: mtp://[usb:BUS,DEVICE]/.
_USB_ADDRESS_URI = re.compile(r"mtp://\[usb:(\d+),(\d+)\]/?", re.IGNORECASE)


def device_uri(bus: int, address: int) -> str:
    """The address of the device at this place on USB."""
    return f"mtp://[usb:{bus:03d},{address:03d}]/"


def place_of(uri: str, whole: bool = True) -> tuple[int, int] | None:
    """(bus, device number) of an address of device_uri's form; None for any other. Not
    `whole`: an address that only begins with one (a folder of the device)."""
    found = (_USB_ADDRESS_URI.fullmatch(uri.strip()) if whole
             else _USB_ADDRESS_URI.match(uri))
    return (int(found.group(1)), int(found.group(2))) if found else None


# --- the states of the Garmin devices on USB ------------------------------------------------
#
# Right after the cable goes in, a Garmin watch is on USB under a transitional product ID
# for a while (about 19 s on the fēnix 8), then comes back as an MTP device. What each state
# means where the devices are found: gio_storage.usb_state, mac_storage.usb_state.

STARTING_PRODUCT = "0003"
ABSENT, STARTING, PRESENT = "absent", "starting", "present"
# Only Garmin devices in mass storage mode (e.g. the Varia RTL515): the system offers them
# as a USB drive, never over MTP, so there is nothing to wait for.
MASS_STORAGE = "mass-storage"
# A watch that connects as a USB drive, back on USB as 091e:0003 after its drive was
# ejected (a Forerunner 55): it is in its Garmin USB mode (Garmin's own protocol, which
# openExpress does not use), not a drive switched off, whatever the name of this state says;
# only plugging it in again helps, nothing to wait for (gio_storage._drive_places).
DRIVE_OFF = "drive-off"
# A Garmin device whose interfaces are HID, or HID beside mass storage (an inReach Mini of the
# first generation: a drive for its first minute, then HID only): it offers neither MTP nor a
# drive that stays, so openExpress cannot use it, and nothing is waited for (_unsupported).
UNSUPPORTED = "unsupported"
WAIT_FOR_DEVICE_S = 45
# Between its transitional mode and MTP the device is off the bus for a moment (about
# 0.3 s on the fēnix 8). Only a longer absence means that it was unplugged.
USB_GAP_S = 5


# The classes of the interfaces of a USB device, as /sys writes them.
HID_CLASS = "03"
MASS_STORAGE_CLASS = "08"


def classify(classes: list[str | None]) -> str | None:
    """What the classes of a USB device's interfaces say of it (None: a class that could not be
    read). MASS_STORAGE: every class read is mass storage, and one at least was read;
    UNSUPPORTED: every class was read, one is HID, and each is HID or mass storage (a device
    with an MTP or a vendor-specific interface never is); None: neither."""
    known = [c for c in classes if c is not None]
    if known and all(c == MASS_STORAGE_CLASS for c in known):
        return MASS_STORAGE
    if (HID_CLASS in known and len(known) == len(classes)
            and all(c in (HID_CLASS, MASS_STORAGE_CLASS) for c in known)):
        return UNSUPPORTED
    return None


class NotThereYet(DeviceError):
    """gvfs (or, on macOS, USB) does not offer a Garmin device, or its files cannot be seen
    yet."""


class MassStorageNotice(NotThereYet, OrdinaryStop):
    """A Garmin device in mass storage mode is on USB, but its drive is not mounted or is
    out of the Flatpak's sight: a notice, not an error (the command line writes no "Error:"
    before it; the exit code stays 1)."""

    log_reason = "a notice about the USB mode of the device"


class UnsupportedDevice(NotThereYet, OrdinaryStop):
    """The only Garmin devices on USB are ones openExpress cannot use (UNSUPPORTED): told at
    once, as a notice, not an error (the command line writes no "Error:" before it; the exit
    code stays 1); nothing is waited for."""

    log_reason = "a Garmin device that openExpress cannot use"


class NoDevice(NotThereYet, OrdinaryStop):
    """No Garmin device on USB at all: the state the program waits in (the window started
    without one), not a failure. The user is told as for NotThereYet; the log says it in one
    line of INFO."""

    log_reason = "no Garmin device is connected"


class SeveralDevices(DeviceError):
    """More than one device where one was to be opened. `devices`: what was found (kind,
    address, USB id), for a window that lets the user choose; the text is for the command
    line."""

    def __init__(self, message: str, devices: list[FoundDevice] | None = None):
        super().__init__(message)
        self.devices: list[FoundDevice] = list(devices or [])


class DeviceInUse(ptp.UsbUnavailable):
    """Another program holds the device for itself: it is not taken from it. The text names
    the program (`holder.name`; `holder.camera_daemon`: macOS's camera service) and says what
    to do."""

    def __init__(self, holder):
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


class DriveNotMounted(DeviceError):
    """The drive to eject is not mounted any more: ejected or unmounted meanwhile."""


def mass_storage_text() -> str:
    """What an open Garmin device in mass storage mode has not got: the refusal of the
    commands that do not apply to it (the window's pages say it in their own words). Its sync,
    backup and updates work, and the device page says why a drive is not synced."""
    return _("The device is connected in mass storage mode (as a USB drive): apps, maps and "
             "music are not supported in this mode.")


def no_device_text() -> str:
    """No Garmin device on USB (ABSENT)."""
    return _("No Garmin device (MTP) found. Connect the device with a USB cable "
             "and unlock it if it asks to allow the connection.")


def files_not_offered_text() -> str:
    """A Garmin device on USB in its normal mode (PRESENT) whose files are not offered."""
    return _("The Garmin device is connected, but it does not offer its files. Check its "
             "screen: if it is locked with a PIN or asks something, unlock it or confirm.")


def unsupported_device_text(name: str | None, usb_id: str) -> str:
    """Why a Garmin device on USB cannot be used (UNSUPPORTED), which one it is (`name`: the
    name it gives USB, if any; `usb_id`) and that `openexpress report` reports it: the words
    of the command line."""
    # TRANSLATORS: in the words about a Garmin device openExpress cannot use, after
    # "Connected:", when the device gives USB no name
    name = name or pgettext("in a sentence", "Garmin device")
    # TRANSLATORS: on the command line while the only Garmin device on USB is one openExpress
    # cannot use; {name}: the name it gives USB (e.g. "Garmin USB inReach"); {id}: its USB ID
    # (e.g. "091e:0b89"); "openexpress report" is a command, not to be translated
    return _("openExpress works with devices that connect as a media device (MTP) or a USB "
             "drive. This one uses a different connection. Connected: {name} (USB {id}). To "
             "report it, run openexpress report.").format(name=name, id=usb_id)


# --- a short look at a device found, for a list to choose from -----------------------------

# Why a summary has no details.
NOT_MOUNTED = "not-mounted"  # an MTP device whose volume is not mounted: never mounted here
NO_DEVICE_FILE = "no-device-file"  # no GARMIN/GarminDevice.xml on it
UNREADABLE = "unreadable"  # the device or its GarminDevice.xml could not be read


@dataclass
class DeviceSummary:
    """What GarminDevice.xml says about a device found: enough for an entry in a list."""
    found: FoundDevice
    description: str = ""
    part_number: str = ""
    software_version: str = ""
    unit_id: int | None = field(default=None, repr=False)  # in memory only, never written
    reason: str | None = None  # NOT_MOUNTED, NO_DEVICE_FILE or UNREADABLE: no details
    # What probe opened of an MTP device (its GarminDevice and storage), kept in memory for
    # the window's count of its activities in the background; None for a drive.
    device: object | None = field(default=None, repr=False, compare=False)
    storage: object | None = field(default=None, repr=False, compare=False)
    # Its activities not uploaded yet (sync.ActivitiesToSync) as the window counted them,
    # None: not counted (yet) or not known; whether a count was started.
    to_sync: object | None = field(default=None, repr=False, compare=False)
    to_sync_asked: bool = field(default=False, repr=False, compare=False)

    @property
    def ok(self) -> bool:
        return self.reason is None


def distinct_devices(summaries: list[DeviceSummary]) -> list[DeviceSummary]:
    """One entry per device. Entries with the same unit ID are one device seen in two ways
    (over MTP and as a drive, while it switches): the MTP entry stays, in the place of the
    first. Entries without details cannot be told apart and are each kept."""
    out: list[DeviceSummary] = []
    for s in summaries:
        seen = next((i for i, o in enumerate(out)
                     if s.unit_id is not None and o.unit_id == s.unit_id), None)
        if seen is None:
            out.append(s)
        elif out[seen].found.kind != "mtp" and s.found.kind == "mtp":
            out[seen] = s
    return out
