"""The rows of the device page with the readings of the Garmin Connect account
(docs/design/odczyty-z-konta.md): "Account Sensors", in the group of the account, the sensors on
the account and their batteries, low ones first; and "Solar Charging", in the group Storage, the
activity time the sun gained this device today and in the last 7 days. Each is asked off the
window's thread when the device page is made (in_background); the answers are kept a while
(answers.SENSORS, answers.SOLAR), and Refresh, a sync and another sign-in ask them anew.

Has: sensors_row and solar_row, the rows of the device page shown (MainWindow._init_state).
"""

import logging

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, GLib  # noqa: E402 - imports must follow gi.require_version

from openexpress import readings  # noqa: E402
from openexpress.gui.window_tasks import row_label  # noqa: E402
from openexpress.i18n import _, caption, npgettext  # noqa: E402

log = logging.getLogger(__name__)

# The days of the row Solar Charging: today and the six before it.
SOLAR_DAYS = 7


def account_entry(s) -> dict | None:
    """The entry of the open device in the account's list the ownership check read; None when
    the list is not known or the device is not on it."""
    devices = getattr(s, "account_devices", None)
    if not isinstance(devices, list):
        return None
    return next((d for d in devices if isinstance(d, dict)
                 and d.get("unitid") == s.device.unit_id), None)


# --- Account Sensors --------------------------------------------------------------------------

def sensors_row(win, s) -> Adw.ExpanderRow:
    """The row Account Sensors of the group of the account: "Sign in to see" while not signed
    in, "Checking…" while the account is asked, then the sensors (expanded: one row each), or no
    row when the account has none, or "Could not check"."""
    # TRANSLATORS: expander row in the group of the Garmin account on the device page: the
    # sensors on the account (a heart rate strap, a Varia, a power meter…) and their batteries
    row = Adw.ExpanderRow(title=_("Account Sensors"), enable_expansion=False)
    win.sensors_row = row
    if not s.logged_in:
        row.set_subtitle(_("Sign in to see"))
        return row
    row.set_subtitle(_("Checking…"))

    def read_sensors():
        return readings.in_order(s.client.account_sensors())

    def done(sensors):
        if win.sensors_row is row:
            show_sensors(row, sensors)

    def failed(_e):
        if win.sensors_row is row:
            row.set_subtitle(_("Could not check"))

    win.in_background(read_sensors, done, failed)
    return row


def show_sensors(row: Adw.ExpanderRow, sensors: list[dict]) -> None:
    """The sensors under the row, in the order given; how many and how many with a low battery
    in its subtitle; a low or critical battery in the warning colour. No sensor: no row."""
    if not sensors:
        row.set_visible(False)
        return
    low = sum(1 for sensor in sensors if readings.is_low(sensor))
    # TRANSLATORS: subtitle of the row Account Sensors: how many sensors the account has
    parts = [npgettext("account sensors", "{count} sensor", "{count} sensors",
                       len(sensors)).format(count=len(sensors))]
    if low:
        # TRANSLATORS: subtitle of the row Account Sensors, after "3 sensors · "
        parts.append(npgettext("account sensors", "{count} with a low battery",
                               "{count} with a low battery", low).format(count=low))
    row.set_subtitle(GLib.markup_escape_text(caption(*parts)))
    at = readings.now()
    for sensor in sensors:
        # A sensor's name is the account's: text, not markup.
        child = Adw.ActionRow(
            title=GLib.markup_escape_text(readings.sensor_name(sensor)),
            subtitle=GLib.markup_escape_text(caption(readings.battery_text(sensor),
                                                     readings.last_connected_text(sensor, at))))
        if readings.is_low(sensor):
            label = row_label(child, "subtitle")
            if label is not None:
                label.add_css_class("warning")
        row.add_row(child)
    row.set_enable_expansion(True)


# --- Solar Charging ---------------------------------------------------------------------------

def solar_row(win, s) -> Adw.ActionRow | None:
    """The row Solar Charging of the group Storage, for a device that charges from the sun (its
    entry on the account, readings.charges_from_sun; not signed in, or the account's list not
    known, by its model's name); None for any other. "Sign in to see" while not signed in,
    "Checking…" while asked, then today's and the week's activity time gained, or "Could not
    check"."""
    entry = account_entry(s)
    if s.logged_in and entry is not None:
        if not readings.charges_from_sun(entry):
            return None
    elif s.logged_in and isinstance(getattr(s, "account_devices", None), list):
        return None  # a device off the account: nothing of it to ask
    elif "solar" not in (s.device.description or "").casefold():
        return None
    # TRANSLATORS: row of the device page (group Storage): the activity time the sun gained a
    # device that charges from the sun
    row = Adw.ActionRow(title=_("Solar Charging"))
    win.solar_row = row
    device_id = entry.get("deviceid") if entry is not None else None
    if not s.logged_in:
        row.set_subtitle(_("Sign in to see"))
        return row
    if not isinstance(device_id, int) or isinstance(device_id, bool):
        row.set_subtitle(_("Could not check"))
        return row
    row.set_subtitle(_("Checking…"))
    start, end = readings.period(SOLAR_DAYS, readings.now().date())

    def read_solar():
        return readings.solar_days(s.client.solar_gain(device_id, start, end), start, end)

    def done(days):
        if win.solar_row is row:
            row.set_subtitle(GLib.markup_escape_text(solar_text(days)))

    def failed(_e):
        if win.solar_row is row:
            row.set_subtitle(_("Could not check"))

    win.in_background(read_solar, done, failed)
    return row


def solar_text(days: list) -> str:
    """The subtitle of Solar Charging: today's activity time gained, then the week's."""
    week = sum(ms for _day, ms in days)
    today = days[0][1] if days else 0
    return caption(
        # TRANSLATORS: subtitle of the row Solar Charging, before "last 7 days …"
        _("Activity time gained: today {today}").format(today=readings.gained_text(today)),
        # TRANSLATORS: subtitle of the row Solar Charging, after "Activity time gained: today …"
        _("last 7\u00a0days {week}").format(week=readings.gained_text(week)))
