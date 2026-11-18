"""Access to an MTP device on macOS, where there is no gvfs: the program has the device to
itself through its own PTP client (ptp.Session, over libusb) for as long as the storage is
open, and reads, writes, deletes and makes folders with it. Found and opened as gio_storage
finds and opens devices on Linux, under the same names (platform.devices), so that the
command line goes the same way on both.

What a listing shows is what ordinary MTP shows (GetObjectHandles), as through gvfs: the
folders a device hides are read through exclusive_ptp, as on Linux, which here lends the
session the storage has open. A storage keeps what it listed (names, sizes and handles), so
that a path is looked up without asking the device again; refresh() drops it, and what is
done through the lent session drops it too.

A device is addressed as mtp://[usb:BUS,DEVICE]/ (its place on USB, new at each plugging in),
the older form of gvfs's addresses, which --device-uri takes as well.
"""

from __future__ import annotations

import atexit
import logging
import os
import posixpath
import threading
import time
from contextlib import contextmanager
from pathlib import Path

from openexpress.device import ptp
from openexpress.device.found import probe as found_probe
from openexpress.device.found import (  # noqa: F401 - the names of platform.devices()
    ABSENT,
    DRIVE_OFF,
    GARMIN_VID,
    MASS_STORAGE,
    NO_DEVICE_FILE,
    NOT_MOUNTED,
    PRESENT,
    STARTING,
    STARTING_PRODUCT,
    UNREADABLE,
    UNSUPPORTED,
    USB_GAP_S,
    WAIT_FOR_DEVICE_S,
    DeviceInUse,
    DeviceSummary,
    DriveNotMounted,
    FoundDevice,
    GarminUsb,
    MassStorageNotice,
    NoDevice,
    NotThereYet,
    SeveralDevices,
    UnsupportedDevice,
    device_uri,
    distinct_devices,
    files_not_offered_text,
    mass_storage_text,
    no_device_text,
    one_device,
    place_of,
    unsupported_device_text,
    usb_place,
    wait_for_device,
)
from openexpress.device.storage import (
    CopyNotStarted,
    DeviceError,
    DeviceNotResponding,
    Entry,
    Storage,
    UmsStorage,
    entry_named,
)
from openexpress.i18n import _, pgettext
from openexpress.platform import mac_usb

log = logging.getLogger(__name__)

def _entry(info: ptp.ObjectInfo) -> Entry:
    return Entry(info.name, info.is_dir, 0 if info.is_dir else info.size, info.modified)


class MacStorage(Storage):
    """One storage of an MTP device (its internal storage), through a PTP session of its own,
    open from the opening to close(). Over MTP the old file under a name is deleted before
    the new one is sent (replaces_atomically False), as through gvfs."""

    def __init__(self, session: ptp.Session, store: int, usb: GarminUsb | None = None,
                 uri: str | None = None, description: str = ""):
        self._session = session
        self.store = store
        self.usb = usb
        self.device_uri = uri
        # As gvfs names the storage of a device: its address, then the storage's name.
        self.label = (uri or "mtp://") + (description or f"{store:08x}")
        self._lock = threading.RLock()
        # What was listed, by the real path of each folder ("": the top level), and the handle
        # of each object listed by its real path.
        self._folders: dict[str, list[ptp.ObjectInfo]] = {}
        # Each write that failed after the device made its object: the handle it left behind,
        # by the real path (_discard_partial).
        self._partial: dict[str, int] = {}
        self._closed = False

    # --- the session --------------------------------------------------------------------

    @property
    def closed(self) -> bool:
        return self._closed

    def _responding(self) -> None:
        """As Storage._responding; DeviceError once it is closed."""
        super()._responding()
        if self._closed:
            raise DeviceError(_("The connection to the device is closed."))

    def _call(self, what: str, action):
        """action(session), its PtpError said as `what` failing (DeviceError). A session out
        of step after it (a transfer that failed or had no answer in time) is a device that
        stopped responding: DeviceNotResponding, now and for every later operation, and the
        device is let go."""
        self._responding()
        with self._lock:
            try:
                return action(self._session)
            except ptp.PtpError as e:
                if self._session.broken:
                    raise self._stall(what, e) from e
                raise DeviceError(f"{what}: {e}") from e

    def _stall(self, what: str, error: Exception) -> DeviceNotResponding:
        stalled = self._stalled_during(what)
        note_stalled(self.usb)
        log.warning("device: the PTP session broke off (%s: %s); the device is let go",
                    type(error).__name__, error)
        self._release()
        return stalled

    def close(self) -> None:
        """The session closed and the device let go (the camera service goes on); nothing can
        be done with the storage afterwards. Again: nothing."""
        with self._lock:
            if self._closed:
                return
            self._release()
        log.info("device: closed (USB %s)", self.usb_id or "?")

    def _release(self) -> None:
        self._closed = True
        try:
            self._session.close()  # CloseSession unless broken; the transport released anyway
        finally:
            _forget_open(self)

    # --- what was listed ----------------------------------------------------------------

    def _objects(self, real_path: str, what: str) -> list[ptp.ObjectInfo]:
        """The objects ordinary MTP shows in the folder at this real path, listed once."""
        if real_path in self._folders:
            return self._folders[real_path]
        if real_path:
            folder = self._object(real_path, what)
            if folder is None:
                raise DeviceError(f"{what}: " + _("File not found on the device: {path}").format(
                    path=real_path))
            if not folder.is_dir:
                raise DeviceError(_("Not a directory: {path}").format(path=real_path))
            handle = folder.handle
        else:
            handle = ptp.ROOT
        found = self._call(what, lambda s: s.children(self.store, handle))
        self._folders[real_path] = found
        return found

    def _object(self, real_path: str, what: str) -> ptp.ObjectInfo | None:
        """The object at this real path, from the listing of its folder; None: not there."""
        parent, name = posixpath.split(real_path)
        return entry_named(self._objects(parent, what), name) if name else None

    def _known(self, real_path: str) -> ptp.ObjectInfo | None:
        """The object at this real path if its folder was listed already; nothing is asked."""
        parent, name = posixpath.split(real_path)
        listed = self._folders.get(parent)
        return entry_named(listed, name) if listed is not None and name else None

    def _folder_handle(self, real_path: str, what: str) -> int:
        if not real_path:
            return ptp.ROOT
        folder = self._object(real_path, what)
        if folder is None or not folder.is_dir:
            raise DeviceError(_("Not a directory: {path}").format(path=real_path))
        return folder.handle

    def _file(self, real_path: str, what: str) -> ptp.ObjectInfo:
        found = self._object(real_path, what)
        if found is None or found.is_dir:
            raise DeviceError(_("File not found on the device: {path}").format(path=real_path))
        return found

    def _note(self, real_path: str, info: ptp.ObjectInfo) -> None:
        """The object now at this real path (just made, or looked at again), in the listing
        of its folder when that is kept."""
        parent, _name = posixpath.split(real_path)
        listed = self._folders.get(parent)
        if listed is not None:
            self._folders[parent] = [o for o in listed if o.handle != info.handle] + [info]
        if info.is_dir and real_path not in self._folders:
            self._folders[real_path] = []  # a folder just made is empty

    def _forget(self, real_path: str) -> None:
        """Nothing is kept any more of the object at this real path nor, for a folder, of
        what was in it."""
        parent, name = posixpath.split(real_path)
        listed = self._folders.get(parent)
        if listed is not None:
            gone = entry_named(listed, name)
            self._folders[parent] = [o for o in listed if o is not gone]
        for path in [p for p in self._folders if p == real_path
                     or p.startswith(real_path + "/")]:
            del self._folders[path]

    # --- Storage ------------------------------------------------------------------------

    def resolve(self, path: str, strict: bool = False) -> str | None:
        """As Storage.resolve, once the storage is known to answer: a closed one, or one whose
        device stopped responding, is never taken for a missing file."""
        self._responding()
        return super().resolve(path, strict)

    def _list(self, real_path: str) -> list[Entry]:
        self._responding()
        what = _("Cannot list {path}").format(path=real_path or "/")
        return [_entry(o) for o in self._objects(real_path, what)]

    def info(self, real_path: str) -> Entry | None:
        """The object asked about again (GetObjectInfo) when its folder was listed already: its
        size now, also of a file the device wrote since; else as its folder lists it."""
        known = self._known(real_path)
        if known is None:
            return super().info(real_path)
        what = _("Cannot read {path}").format(path=real_path)
        try:
            fresh = self._call(what, lambda s: s.info(known.handle))
        except DeviceNotResponding:
            raise
        except DeviceError:
            # Gone since it was listed (its handle is not valid any more): its folder listed
            # anew.
            self._folders.pop(posixpath.dirname(real_path), None)
            return super().info(real_path)
        self._note(real_path, fresh)
        return _entry(fresh)

    def _read(self, real_path: str) -> bytes:
        what = _("Cannot read {path}").format(path=real_path)
        found = self._file(real_path, what)
        content = bytearray()
        self._call(what, lambda s: s.read_into(found.handle, content.extend, size=found.size))
        return bytes(content)

    def _read_start(self, real_path: str, count: int) -> bytes:
        """The first bytes alone (GetPartialObject); the whole file cut, on a device that does
        not read parts."""
        what = _("Cannot read {path}").format(path=real_path)
        found = self._file(real_path, what)
        if count <= 0:
            return b""

        def part(session):
            try:
                return session.read_part(found.handle, 0, min(count, ptp.MAX_OBJECT_SIZE))
            except ptp.PtpRefused as e:
                if e.code != ptp.OPERATION_NOT_SUPPORTED:
                    raise
                return None

        data = self._call(what, part)
        return self._read(real_path)[:count] if data is None else data

    def _write(self, real_path: str, data: bytes) -> None:
        what = _("Cannot write {path}").format(path=real_path)
        self._send(real_path, data, what)

    def _write_file(self, real_path: str, local: Path, progress=None) -> None:
        """Sent as it is read from the file, never held whole; `progress(done, total)` after
        each piece (ptp.WRITE_CHUNK). The file that cannot be read, or is too large for MTP,
        is CopyNotStarted: the old file stays."""
        self._responding()
        what = _("Cannot write {path}").format(path=real_path)
        try:
            stream = open(local, "rb")  # noqa: SIM115 - closed below, after the send
        except OSError as e:
            raise CopyNotStarted(f"{what}: {e.strerror or e}") from e
        with stream:
            try:
                size = os.fstat(stream.fileno()).st_size
            except OSError as e:
                raise CopyNotStarted(f"{what}: {e.strerror or e}") from e
            if size > ptp.MAX_OBJECT_SIZE:
                raise CopyNotStarted(f"{what}: " + _("The file is too large to send."))
            sent = (lambda done: progress(done, size)) if progress else None
            self._send(real_path, ptp.Outgoing(stream, size, sent), what)

    def _send(self, real_path: str, data, what: str) -> None:
        """A new object under this real path (SendObjectInfo, SendObject), the old file of the
        name deleted first: MTP replaces none. Refused before anything was touched (no old
        file, and SendObjectInfo refused): CopyNotStarted. The object a failed SendObject left
        is kept for _discard_partial."""
        parent_path, name = posixpath.split(real_path)
        parent = self._folder_handle(parent_path, what)
        old = self._object(real_path, what)
        if old is not None and old.is_dir:
            raise DeviceError(_("Cannot write {path}: it is a directory").format(path=real_path))
        if old is not None:
            self._call(what, lambda s: s.delete(old.handle, old.size))
            self._forget(real_path)

        def send(session) -> int:
            try:
                return session.send_object(self.store, parent, name, data)
            except ptp.PtpRefused as e:
                if old is None and e.operation == ptp.SEND_OBJECT_INFO:
                    raise CopyNotStarted(f"{what}: {e}") from e
                raise
            except ptp.PtpWriteError as e:
                if e.handle is not None:
                    self._partial[real_path] = e.handle
                raise

        handle = self._call(what, send)
        self._note(real_path, self._call(what, lambda s: s.info(handle)))

    def _discard_partial(self, real_path: str) -> None:
        """The object a failed send left under the name, deleted; nothing when it left none.
        A failed delete is only logged."""
        handle = self._partial.pop(real_path, None)
        self._forget(real_path)
        if handle is None or self.stalled or self.closed:
            return
        try:
            self._call(_("Cannot delete {path}").format(path=real_path),
                       lambda s: s.delete(handle))
        except DeviceNotResponding:
            raise  # a stall stops what meets it: nothing more is asked of the device
        except DeviceError as e:
            log.warning("Cannot delete a partly copied file: %s", type(e).__name__)

    def _delete(self, real_path: str) -> None:
        # TRANSLATORS: error: a file on the device cannot be deleted ({path}: the file)
        what = _("Cannot delete {path}").format(path=real_path)
        found = self._object(real_path, what)
        if found is None:
            raise DeviceError(_("File not found on the device: {path}").format(path=real_path))
        self._call(what, lambda s: s.delete(found.handle, None if found.is_dir else found.size))
        self._forget(real_path)

    def _mkdir(self, real_path: str) -> None:
        what = _("Cannot create directory {path}").format(path=real_path)
        parent_path, name = posixpath.split(real_path)
        parent = self._folder_handle(parent_path, what)
        handle = self._call(what, lambda s: s.create_folder(self.store, parent, name))
        self._note(real_path, self._call(what, lambda s: s.info(handle)))

    def _space(self) -> ptp.StorageInfo | None:
        try:
            return self._call(_("Cannot read the space on the device"),
                              lambda s: s.storage_info(self.store))
        except DeviceNotResponding:
            raise
        except DeviceError:
            return None

    def free_space(self) -> int | None:
        space = self._space()
        return space.free if space is not None else None

    def capacity(self) -> int | None:
        # A size of 0 means "unknown" (a real storage is never empty-sized).
        space = self._space()
        return (space.capacity or None) if space is not None else None

    def battery(self) -> int | None:
        """The device's battery charge in percent: None, as Garmin's devices do not tell it
        over MTP. A fēnix 8 answers BatteryLevel with its default, 50 (of 0, 10, … 100), at
        any charge (seen at 100 % on its own screen), so a number from it would mislead."""
        return None

    def refresh(self, progress=None) -> bool:
        """What was listed is dropped: the next look asks the device (its sizes now)."""
        self._responding()
        with self._lock:
            self._folders.clear()
        return True

    def exclusive_ptp(self):
        """The session of the storage, lent for the block (no unmount: nothing else holds the
        device); what was listed is dropped after it, as anything may have changed."""
        self._responding()
        return self._lent()

    @contextmanager
    def _lent(self):
        with self._lock:
            try:
                yield self._session
            finally:
                self._folders.clear()
                if self._session.broken and not self.stalled:
                    self._stall(_("Cannot read the device"), ptp.PtpError("out of step"))


# --- the storages open, the devices that stopped responding ---------------------------------
#
# A device is opened once in a process: the storage of a device found again (a probe, then a
# command) is the one already open. Each is closed at exit, so that the camera service goes on
# and the device ends its session.

_open: dict[tuple[int, int], MacStorage] = {}
_open_lock = threading.Lock()
_stalled_at: set[tuple[int, int]] = set()


def _forget_open(storage: MacStorage) -> None:
    with _open_lock:
        for place, open_storage in list(_open.items()):
            if open_storage is storage:
                del _open[place]


def close_all() -> None:
    """Every storage open closed (at exit)."""
    with _open_lock:
        storages = list(_open.values())
    for storage in storages:
        try:
            storage.close()
        except DeviceNotResponding:
            log.info("device: not closed at exit, it stopped responding")  # the others still are
        except Exception as e:  # noqa: BLE001 - at exit: the device goes when the process does
            log.info("device: not closed at exit (%s)", type(e).__name__)


atexit.register(close_all)


def note_stalled(usb: GarminUsb | None) -> None:
    """The device at `usb` stopped responding: left out of what is found while it stays at its
    place on USB (unplugged, or restarted, it gets another one)."""
    place = usb_place(usb)
    if place is not None:
        _stalled_at.add(place)


def _still_stalled(places: set[tuple[int, int]]) -> set[tuple[int, int]]:
    """The places of devices that stopped responding that are still taken; the others are
    forgotten."""
    _stalled_at.intersection_update(places)
    return set(_stalled_at)


# --- finding the devices --------------------------------------------------------------------

def _usb_devices() -> list[mac_usb.UsbDevice]:
    """The Garmin devices on USB but those that stopped responding."""
    devices = mac_usb.garmin_devices()
    stalled = _still_stalled({(d.bus, d.address) for d in devices})
    return [d for d in devices if (d.bus, d.address) not in stalled]


def find_devices() -> list[FoundDevice]:
    """The Garmin devices on USB that offer MTP (a file transfer interface, not in their Garmin
    USB mode). Nothing is opened."""
    return [FoundDevice(device_uri(d.bus, d.address),
                        d.name or pgettext("in a sentence", "Garmin device"), True,
                        usb=d.garmin_usb())
            for d in _usb_devices() if d.mode == PRESENT and d.file_transfer]


def find_ums_devices() -> list[FoundDevice]:
    """Garmin drives: not opened on macOS (yet); usb_state tells them."""
    return []


def find_all_devices() -> list[FoundDevice]:
    return [*find_devices(), *find_ums_devices()]


def mount(dev: FoundDevice) -> None:
    """Nothing to mount: the device is opened over USB as it is."""


def mount_drive(dev: FoundDevice) -> FoundDevice:
    raise MassStorageNotice(not_ready_text(MASS_STORAGE))


def open_ums_storage(dev: FoundDevice) -> UmsStorage:
    raise MassStorageNotice(not_ready_text(MASS_STORAGE))


def usb_state() -> str:
    """As gio_storage.usb_state, from libusb: ABSENT, STARTING (only 091e:0003 besides what
    cannot be used), PRESENT, MASS_STORAGE or UNSUPPORTED. DRIVE_OFF is not told apart here
    (it needs the drive seen before)."""
    modes = [d.mode for d in _usb_devices()]
    if not modes:
        return ABSENT
    others = [m for m in modes if m not in (MASS_STORAGE, UNSUPPORTED)]
    if not others:
        return MASS_STORAGE if MASS_STORAGE in modes else UNSUPPORTED
    return PRESENT if PRESENT in others else STARTING


def garmin_products_on_usb() -> list[str]:
    return [d.product for d in mac_usb.garmin_devices()]


def garmin_usb_summary() -> list[tuple[str, str | None, list[str | None]]]:
    """For a report without a device: (USB ID, the name it gives USB if any, the classes of
    its interfaces) of each Garmin device on USB; never its serial number."""
    return [(d.usb_id, d.name, list(d.classes)) for d in mac_usb.garmin_devices()]


def holders() -> dict[tuple[int, int], str]:
    """The other programs that hold a Garmin device for themselves (the IORegistry), by its
    place on USB: not this process, nor the camera service, which is paused while the device
    is open."""
    return {place: r.holder.name for place, r in mac_usb.registered_devices().items()
            if r.holder is not None and not r.holder.this_process
            and not r.holder.camera_daemon}


def mtp_missing() -> bool:
    """MTP is the program's own here: never missing."""
    return False


def garmin_mode_text() -> str:
    """A Garmin device on USB only as 091e:0003, its Garmin USB mode."""
    # TRANSLATORS: macOS: the only Garmin device on USB is in its Garmin USB mode (USB ID
    # 091e:0003); "Garmin USB mode" as Garmin calls it
    return _("The device is on USB in its Garmin USB mode (091e:0003), which openExpress does "
             "not use. A watch is in it for about 20 seconds after it is plugged in: wait until "
             "it shows its usual screen. If it stays in it, unplug the cable and plug it in "
             "again.")


def not_ready_text(state: str) -> str:
    """What to tell the user when no device could be opened in this USB state."""
    if state == STARTING:
        return garmin_mode_text()
    if state == PRESENT:
        return files_not_offered_text()
    if state == MASS_STORAGE:
        # TRANSLATORS: macOS: a Garmin device connected as a USB drive
        return _("The Garmin device is connected as a USB drive. On macOS openExpress opens "
                 "only devices that connect as a media device (MTP).")
    if state == UNSUPPORTED:
        found = next((d for d in mac_usb.garmin_devices() if d.mode == UNSUPPORTED), None)
        return unsupported_device_text(found.name if found else None,
                                       found.usb_id if found else f"{GARMIN_VID}:?")
    return no_device_text()


# --- opening one --------------------------------------------------------------------------

def open_device_storage(uri: str | None = None, wait: bool = False, notify=None,
                        sleep=time.sleep, clock=time.monotonic) -> MacStorage:
    """The storage of the device that has GARMIN/GarminDevice.xml, as gio_storage opens one
    (found.wait_for_device): raises DeviceError (NotThereYet, SeveralDevices,
    MassStorageNotice, UnsupportedDevice, NoDevice, DeviceInUse) when there is none to open.
    With `wait`, a Garmin device on USB that does not offer MTP yet (its Garmin USB mode) is
    waited for up to WAIT_FOR_DEVICE_S, and `notify` is called once with a line saying so."""
    return wait_for_device(
        lambda: _open_device_storage(uri), usb_state=usb_state, products=garmin_products_on_usb,
        not_ready_text=not_ready_text, starting_text=garmin_mode_text, log=log, over="USB",
        wait=wait, notify=notify, sleep=sleep, clock=clock)


def _open_device_storage(uri: str | None) -> MacStorage:
    found = find_devices()
    if uri is None:
        return open_found(one_device(found))
    place = place_of(uri)
    if place is None:
        # TRANSLATORS: macOS: --device-uri was given an address of another form; {example}
        # is one of the form it takes ("mtp://[usb:008,037]/")
        raise DeviceError(_("On macOS a device is named by its place on USB, as in {example} "
                            "(openexpress status lists them).").format(example=device_uri(8, 37)))
    chosen = next((d for d in found if usb_place(d.usb) == place), None)
    if chosen is None:
        raise NotThereYet(not_ready_text(ABSENT))
    return open_found(chosen)


def open_found(found: FoundDevice) -> MacStorage:
    """The storage of a device find_devices found: the one open already in this process, or
    one opened now (its session open, the storage that has GARMIN/GarminDevice.xml)."""
    place = usb_place(found.usb)
    with _open_lock:
        open_storage = _open.get(place)
    if open_storage is not None and not open_storage.closed and not open_storage.stalled:
        return open_storage
    try:
        transport = mac_usb.open_transport(*place)
    except DeviceInUse:
        raise
    except ptp.PtpError as e:
        # TRANSLATORS: error: the USB device could not be opened ({error}: why)
        raise DeviceError(_("Cannot open the device: {error}").format(error=e)) from e
    session = ptp.Session(transport)
    try:
        session.open()
        log.info("PTP: %s", ptp.operations_line(session))
        st = _storage_with_device_file(session, found)
    except BaseException:
        session.close()  # the transport too: the camera service goes on
        raise
    with _open_lock:
        _open[place] = st
    return st


def close_found(found: FoundDevice) -> None:
    """The storage open of a device find_devices found, closed: the device let go (the engine
    lets it go between requests, so that another program may take it). Nothing when none is
    open."""
    with _open_lock:
        open_storage = _open.get(usb_place(found.usb))
    if open_storage is not None:
        open_storage.close()


def _storage_with_device_file(session: ptp.Session, found: FoundDevice) -> MacStorage:
    try:
        stores = session.storages()
    except ptp.PtpError as e:
        raise DeviceError(_("Cannot open the device: {error}").format(error=e)) from e
    for store in stores:
        try:
            description = session.storage_info(store).description
        except ptp.PtpRefused:
            description = ""
        st = MacStorage(session, store, found.usb, found.uri, description)
        if st.exists("GARMIN/GarminDevice.xml"):
            return st
    raise NotThereYet(_("GARMIN/GarminDevice.xml not found on device {uri}").format(
        uri=found.uri))


# --- a short look at a device found, for a list to choose from -----------------------------

def probe(found: FoundDevice) -> DeviceSummary:
    """Read only GarminDevice.xml of a device from find_all_devices (found.probe). Here the
    device is opened for it (a session of the program's own) and stays open, kept for what
    comes next (`storage`)."""
    return found_probe(found, open_found, log)
