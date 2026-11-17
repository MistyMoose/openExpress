"""Keeps this computer from sleeping, and its session from idling into sleep, while openExpress
writes to a device what must not be cut short (a map's files, a software update): through the
desktop portal (the Flatpak and the version from source alike), else through logind (the version
from source). On macOS: an IOKit assertion against idle sleep, else `caffeinate` (_inhibit_darwin).
Optional: when neither can be asked, the work goes on and says so.

Has: nothing kept in the window; a block lasts for one `kept_awake`."""

from __future__ import annotations

import logging
import os
import subprocess
import sys
from collections.abc import Callable, Iterator
from contextlib import contextmanager

from openexpress.i18n import _

log = logging.getLogger(__name__)

_SUSPEND, _IDLE = 4, 8  # the portal's flags
_ANSWER_MS = 5000  # how long the portal or logind may take to answer

_IOPM_PREVENT_IDLE_SLEEP = "PreventUserIdleSystemSleep"  # kIOPMAssertionTypePreventUserIdleSystemSleep
_IOPM_ASSERTION_LEVEL_ON = 255  # kIOPMAssertionLevelOn
_CF_STRING_ENCODING_UTF8 = 0x08000100


def not_blocked_text() -> str:
    # TRANSLATORS: said when the system could not be asked to keep the computer awake while
    # openExpress copies to the device
    return _("openExpress could not keep the computer from sleeping: keep it awake until the "
             "copy has ended.")


@contextmanager
def kept_awake(why: str, say: Callable[[str], None] | None = None) -> Iterator[bool]:
    """The computer kept from sleeping and idling while the block runs; whether it is. `why`:
    for the log and the desktop (what is written). When it cannot be kept awake, `say` is told
    not_blocked_text and the work goes on."""
    try:
        token = _inhibit(why)
    except Exception as e:  # noqa: BLE001 - optional: the work goes on, and says so
        log.warning("awake: sleep not blocked (%s): %s goes on", type(e).__name__, why)
        if say is not None:
            say(not_blocked_text())
        yield False
        return
    log.info("awake: sleep and idle blocked while %s", why)
    try:
        yield True
    finally:
        try:
            _release(token)
        except Exception as e:  # noqa: BLE001 - only logged: it goes with the process anyway
            log.warning("awake: sleep not released (%s)", type(e).__name__)
        else:
            log.info("awake: sleep allowed again")


def _inhibit(why: str):
    """Asks the desktop portal, else logind, to keep the computer awake: what releases it.
    On macOS: IOKit, else caffeinate (_inhibit_darwin); neither needs D-Bus."""
    if sys.platform == "darwin":
        return _inhibit_darwin(why)
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib

    reason = f"openExpress: {why}"
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        handle = bus.call_sync(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Inhibit", "Inhibit",
            GLib.Variant("(sua{sv})", ("", _SUSPEND | _IDLE,
                                       {"reason": GLib.Variant("s", reason)})),
            GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, _ANSWER_MS, None).unpack()[0]
        return ("portal", bus, handle)
    except GLib.Error as e:
        log.info("awake: the desktop portal did not keep it awake (%s); logind asked", e.message)
    system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    answer, fds = system.call_with_unix_fd_list_sync(
        "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
        "Inhibit", GLib.Variant("(ssss)", ("sleep:idle", "openExpress", reason, "block")),
        GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, _ANSWER_MS, None, None)
    return ("logind", None, fds.get(answer.unpack()[0]))


def _release(token) -> None:
    kind, bus, handle = token
    if kind == "logind":
        os.close(handle)  # logind lets the computer sleep once its descriptor is closed
        return
    if kind in ("iokit", "caffeinate"):
        _release_darwin(kind, handle)
        return
    from gi.repository import Gio

    bus.call_sync("org.freedesktop.portal.Desktop", handle, "org.freedesktop.portal.Request",
                  "Close", None, None, Gio.DBusCallFlags.NONE, _ANSWER_MS, None)


def _inhibit_darwin(why: str):
    """IOKit's assertion against idle sleep, else (IOKit not reachable) a `caffeinate` child
    process kept running for the same reason: what _release_darwin ends."""
    reason = f"openExpress: {why}"
    try:
        return ("iokit", None, _iopm_assertion_create(reason))
    except OSError as e:
        log.info("awake: IOKit did not keep it awake (%s); caffeinate asked", e)
    return ("caffeinate", None, _caffeinate_fallback())


def _iopm_assertion_create(reason: str) -> int:
    """IOPMAssertionCreateWithName via ctypes (no PyObjC needed): the new assertion's ID,
    ended by _iopm_assertion_release. OSError when IOKit cannot be loaded or the call fails."""
    import ctypes

    try:
        iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
        corefoundation = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError as e:
        raise OSError(f"IOKit not available: {e}") from e
    corefoundation.CFStringCreateWithCString.restype = ctypes.c_void_p
    corefoundation.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                                          ctypes.c_uint32]
    assertion_type = corefoundation.CFStringCreateWithCString(
        None, _IOPM_PREVENT_IDLE_SLEEP.encode(), _CF_STRING_ENCODING_UTF8)
    cf_reason = corefoundation.CFStringCreateWithCString(
        None, reason.encode(), _CF_STRING_ENCODING_UTF8)
    if not assertion_type or not cf_reason:
        raise OSError("CFStringCreateWithCString failed")
    iokit.IOPMAssertionCreateWithName.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                                  ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    iokit.IOPMAssertionCreateWithName.restype = ctypes.c_int32
    assertion_id = ctypes.c_uint32(0)
    try:
        status = iokit.IOPMAssertionCreateWithName(assertion_type, _IOPM_ASSERTION_LEVEL_ON,
                                                   cf_reason, ctypes.byref(assertion_id))
    finally:
        # IOKit keeps its own copies: the two strings are ours to release
        corefoundation.CFRelease.argtypes = [ctypes.c_void_p]
        corefoundation.CFRelease(assertion_type)
        corefoundation.CFRelease(cf_reason)
    if status != 0:
        raise OSError(f"IOPMAssertionCreateWithName failed: {status}")
    return assertion_id.value


def _iopm_assertion_release(assertion_id: int) -> None:
    """IOPMAssertionRelease via ctypes, the release of _iopm_assertion_create's ID."""
    import ctypes

    iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    iokit.IOPMAssertionRelease.argtypes = [ctypes.c_uint32]
    iokit.IOPMAssertionRelease.restype = ctypes.c_int32
    status = iokit.IOPMAssertionRelease(assertion_id)
    if status != 0:
        raise OSError(f"IOPMAssertionRelease failed: {status}")


def _caffeinate_fallback() -> subprocess.Popen:
    """`caffeinate -i -w <pid>` kept running for as long as this process does: a fallback with
    no IOKit of its own, ended by _release_darwin. "-w" is also a safety net: should this
    process die without releasing it, caffeinate ends by itself with it, instead of keeping
    the computer awake forever."""
    return subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _release_darwin(kind: str, handle) -> None:
    if kind == "iokit":
        _iopm_assertion_release(handle)
        return
    handle.terminate()  # the caffeinate process; "-w" would end it anyway once we do
    handle.wait(timeout=_ANSWER_MS / 1000)
