"""Keeps this computer from sleeping, and its session from idling into sleep, while openExpress
writes to a device what must not be cut short (a map's files, a software update): through the
desktop portal (the Flatpak and the version from source alike), else through logind (the version
from source). Optional: when neither can be asked, the work goes on and says so.

Has: nothing kept in the window; a block lasts for one `kept_awake`."""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Iterator
from contextlib import contextmanager

from openexpress.i18n import _

log = logging.getLogger(__name__)

_SUSPEND, _IDLE = 4, 8  # the portal's flags
_ANSWER_MS = 5000  # how long the portal or logind may take to answer


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
    """Asks the desktop portal, else logind, to keep the computer awake: what releases it."""
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
    from gi.repository import Gio

    bus.call_sync("org.freedesktop.portal.Desktop", handle, "org.freedesktop.portal.Request",
                  "Close", None, None, Gio.DBusCallFlags.NONE, _ANSWER_MS, None)
