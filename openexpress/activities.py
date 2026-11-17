"""The activities of a connected device and of its backups: one list, read a few at a time.

The device's activity files (the folders its GarminDevice.xml gives the data type FIT_TYPE_4)
come first, newest first by the time of change the device gives them; then the files that only
the backups of the same device have (backup.backups_of), the newest backup first. A file on the
device and one in a backup with the same name (letter case aside) are one activity, read from
the device, whatever their sizes; of several backups with that name, the newest gives it. What
each file says (fit.summary) is kept by its source, path, size and time of change, so a list
made again reads only what is new or has changed. Nothing is written; the log gets counts,
sizes and times, never a name or a date.
"""

from __future__ import annotations

import json
import logging
import os
import posixpath
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from pathlib import Path

from openexpress import __version__, applog, fit, paths
from openexpress.backup import backups_of
from openexpress.device.storage import Storage
from openexpress.device.xmldevice import GarminDevice
from openexpress.i18n import _, pgettext
from openexpress.progress import Step, say_to
from openexpress.sync import ACTIVITY_TYPE, files_of

log = logging.getLogger(__name__)

# How many activities are read at a time: the newest first, then as many more when asked.
PAGE = 30


class Source(Enum):
    DEVICE = "device"
    BACKUP = "backup"


@dataclass(frozen=True)
class Activity:
    """An activity file listed: where it is (`path`: its real path on the device, or the path
    of the copy in a backup on this computer), its name, size and time of change, and for a
    copy in a backup when that backup was made."""

    source: Source
    path: str
    name: str
    size: int
    mtime: float
    backup: datetime | None = None

    @property
    def key(self) -> tuple:
        """What its summary is kept by: another size or time of change is another file."""
        return self.source, self.path, self.size, self.mtime


@dataclass(frozen=True)
class Read:
    """An activity and what its file says of it (None: no FIT file, or a copy in a backup
    that could not be read)."""

    activity: Activity
    summary: fit.ActivitySummary | None


def keeps_activities(device: GarminDevice) -> bool:
    """Whether the device's GarminDevice.xml gives it activity files to read."""
    return bool(device.sources(ACTIVITY_TYPE))


def sport_name(sport: int | None) -> str:
    """The name of a sport of the FIT profile; "Activity" when it is not known."""
    names = {
        0: pgettext("sport", "Activity"),  # FIT profile: generic
        1: pgettext("sport", "Running"),
        2: pgettext("sport", "Cycling"),
        4: pgettext("sport", "Fitness equipment"),
        5: pgettext("sport", "Swimming"),
        10: pgettext("sport", "Training"),
        11: pgettext("sport", "Walking"),
        12: pgettext("sport", "Cross-country skiing"),
        13: pgettext("sport", "Alpine skiing"),
        14: pgettext("sport", "Snowboarding"),
        15: pgettext("sport", "Rowing"),
        16: pgettext("sport", "Mountaineering"),
        17: pgettext("sport", "Hiking"),
        18: pgettext("sport", "Multisport"),
        19: pgettext("sport", "Paddling"),
        21: pgettext("sport", "E-biking"),
        23: pgettext("sport", "Boating"),
        25: pgettext("sport", "Golf"),
        27: pgettext("sport", "Horseback riding"),
        29: pgettext("sport", "Fishing"),
        30: pgettext("sport", "Inline skating"),
        31: pgettext("sport", "Rock climbing"),
        32: pgettext("sport", "Sailing"),
        33: pgettext("sport", "Ice skating"),
        35: pgettext("sport", "Snowshoeing"),
        37: pgettext("sport", "Stand-up paddleboarding"),
        38: pgettext("sport", "Surfing"),
        39: pgettext("sport", "Wakeboarding"),
        40: pgettext("sport", "Water skiing"),
        41: pgettext("sport", "Kayaking"),
        42: pgettext("sport", "Rafting"),
        43: pgettext("sport", "Windsurfing"),
        44: pgettext("sport", "Kitesurfing"),
        47: pgettext("sport", "Boxing"),
        53: pgettext("sport", "Diving"),
        62: pgettext("sport", "HIIT"),
        67: pgettext("sport", "Meditation"),
    }
    if sport is None:
        return names[0]
    # TRANSLATORS: a sport the program has no name for, by its number in the FIT profile
    return names.get(sport) or pgettext("sport", "Sport {number}").format(number=sport)


def export_name(summary: fit.ActivitySummary, activity: Activity) -> str:
    """The name of an activity's GPX file without its extension, "YYYY-MM-DD HH.MM Sport": its
    start in local time (else when its file was made, else the name of that file)."""
    when = summary.start or summary.created
    day = (time.strftime("%Y-%m-%d %H.%M", time.localtime(when)) if when
           else posixpath.splitext(activity.name)[0])
    return f"{day} {sport_name(summary.sport)}"


def _in_backup(when: datetime, folder: Path) -> list[Activity]:
    """The activity files of one backup: regular files only, never a symbolic link (nor the
    folders one leads to), each inside the backup's folder."""
    found = []
    try:
        for top, _folders, files in os.walk(folder / ACTIVITY_TYPE):
            for name in files:
                path = Path(top) / name
                if (path.is_symlink() or not name.casefold().endswith(".fit")
                        or not paths.is_inside(path, folder)):
                    continue
                stat = path.stat()
                found.append(Activity(Source.BACKUP, str(path), name, stat.st_size,
                                      stat.st_mtime, when))
    except OSError as e:
        log.info("activities: a backup could not be listed (%s)", type(e).__name__)
    return found


def _summary(data: bytes | None) -> fit.ActivitySummary | None:
    if data is None:
        return None
    try:
        return fit.summary(data)
    except fit.FitError:
        return None


# --- what was read of the files, kept on disk ------------------------------------------------
#
# The summary of each activity file read (fit.summary), by its Activity.key, in a file of the
# cache for each device (summaries_path): the engine (engine.py) and `activities` read only the
# files that are new or changed since. Written whole and atomically; made by another version
# of the program, or of another format, it is not read (and is replaced). Never an error of a
# command: a file that cannot be read is none, one that cannot be written is told in the log.

SUMMARIES_FORMAT = 1
# The most summaries kept for one device (the newest files): about 200 bytes each.
SUMMARIES_MOST = 20_000


def summaries_path(unit_id: int) -> Path:
    return paths.cache_dir() / "activities" / f"{unit_id}.json"


def _summary_json(key: tuple, summary: fit.ActivitySummary) -> dict:
    source, path, size, mtime = key
    return {"source": source.value, "path": path, "size": size, "mtime": mtime,
            "state": summary.state.value, "created": summary.created, "start": summary.start,
            "sport": summary.sport, "timer_time": summary.timer_time,
            "distance": summary.distance, "ascent": summary.ascent,
            "has_positions": summary.has_positions}


def _summary_of(entry: dict) -> tuple[tuple, fit.ActivitySummary]:
    key = (Source(entry["source"]), str(entry["path"]), int(entry["size"]),
           float(entry["mtime"]))
    return key, fit.ActivitySummary(
        fit.FileState(entry["state"]), entry.get("created"), entry.get("start"),
        entry.get("sport"), entry.get("timer_time"), entry.get("distance"),
        entry.get("ascent"), bool(entry.get("has_positions")))


def load_summaries(unit_id: int) -> dict[tuple, fit.ActivitySummary | None]:
    """The summaries kept on disk for this device; none when there is no file, or one that
    cannot be read, is damaged, or was written by another version (one line of the log)."""
    path = summaries_path(unit_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        log.info("activities: the kept summaries not read (%s)", type(e).__name__)
        return {}
    if (not isinstance(data, dict) or data.get("format") != SUMMARIES_FORMAT
            or data.get("openexpress") != __version__):
        log.info("activities: the kept summaries are of another version; read again")
        return {}
    kept = {}
    for entry in data.get("files") or []:
        try:
            key, summary = _summary_of(entry)
        except (KeyError, TypeError, ValueError, AttributeError):
            continue  # one entry damaged: that file is read again
        kept[key] = summary
    log.info("activities: %d summaries kept from before", len(kept))
    return kept


def save_summaries(unit_id: int, found: DeviceActivities) -> bool:
    """What `found` has read, written for its device: only of the files it lists now (a file
    gone from the device and its backups goes from the file too), and not of a file the
    device was still writing or that could not be read (read again next time). Whether it
    was written; a failure is a line of the log, never an error."""
    listed = {a.key for a in found.listing}
    kept = [(key, s) for key, s in found._kept.items() if key in listed and s is not None
            and s.state is not fit.FileState.STILL_BEING_WRITTEN]
    kept.sort(key=lambda item: item[0][3], reverse=True)  # the newest first
    data = {"format": SUMMARIES_FORMAT, "openexpress": __version__,
            "files": [_summary_json(key, s) for key, s in kept[:SUMMARIES_MOST]]}
    try:
        paths.write_private(summaries_path(unit_id), json.dumps(data, separators=(",", ":")))
    except (OSError, ValueError) as e:
        log.warning("activities: the summaries not kept (%s)", type(e).__name__)
        return False
    return True


def forget_summaries(unit_id: int) -> None:
    """The summaries kept for a device, deleted (forget.py)."""
    summaries_path(unit_id).unlink(missing_ok=True)


class DeviceActivities:
    """The activities of one device and of its backups (`backups`: the folder of every
    device's backups; None: none read): listed by list_files, read `PAGE` at a time by
    read_next. `kept`: what was read of the files before, by Activity.key, shared with
    another reading of the same device (the engine keeps one for as long as it runs): a file
    in it is not read again, and each file read is added to it at once."""

    def __init__(self, device: GarminDevice, storage: Storage, backups: Path | None,
                 kept: dict[tuple, fit.ActivitySummary | None] | None = None):
        self.device, self.storage, self.backups = device, storage, backups
        self.listing: list[Activity] = []
        self.read: list[Read] = []  # those of `listing` read so far, in its order
        self._kept: dict[tuple, fit.ActivitySummary | None] = {} if kept is None else kept
        # How many files were read (not found kept) since it was made: save_summaries then.
        self.newly_read = 0

    @property
    def left(self) -> int:
        """How many of the list are not read yet."""
        return len(self.listing) - len(self.read)

    @property
    def only_in_backups(self) -> int:
        """How many of the list only a backup has."""
        return sum(1 for a in self.listing if a.source is Source.BACKUP)

    def list_files(self) -> None:
        """Lists the activity files of the device and of its backups again, no file read; the
        reading starts again from the newest, with what was kept."""
        started = time.monotonic()
        on_device = self._on_device()
        known = {a.name.casefold() for a in on_device}
        only_in_backups = []
        found = backups_of(self.backups, self.device.unit_id) if self.backups else []
        for when, folder in found:
            for a in sorted(_in_backup(when, folder), key=lambda a: a.name.casefold(),
                            reverse=True):
                if a.name.casefold() not in known:
                    known.add(a.name.casefold())
                    only_in_backups.append(a)
        self.listing = on_device + only_in_backups
        self.read = []
        log.info("activities: %d on the device, %d only in backups, backups read: %d "
                 "(listed in %.2f s)", len(on_device), len(only_in_backups), len(found),
                 time.monotonic() - started)

    def _on_device(self) -> list[Activity]:
        found = [Activity(Source.DEVICE, path, posixpath.basename(path), entry.size, entry.mtime)
                 for _src, path, entry in files_of(self.storage,
                                                   self.device.sources(ACTIVITY_TYPE))]
        return sorted(found, key=lambda a: (a.mtime, a.name.casefold()), reverse=True)

    def read_next(self, count: int = PAGE,
                  progress: Callable[[str], None] | None = None,
                  reading: Callable[[int, int, Activity], None] | None = None) -> list[Read]:
        """Reads the next `count` activities of the list and returns them; what is kept is
        not read again. `progress`: a step for each file read ("Reading activities · 2 of 3"),
        never its name. `reading(n, of, activity)`: before each file read, with the activity
        (the engine names it to the app); what it raises stops the reading there, with what
        was read before it kept. An error of the device stops it (DeviceError)."""
        progress = say_to(progress)
        batch = self.listing[len(self.read):len(self.read) + count]
        to_read = [a for a in batch if a.key not in self._kept]
        started, size = time.monotonic(), 0
        # TRANSLATORS: a step of a long task: the activity files read ("… · 2 of 30")
        head = _("Reading activities")
        for n, activity in enumerate(to_read, 1):
            progress(Step(head, n, len(to_read)))
            if reading is not None:
                reading(n, len(to_read), activity)
            data = self.read_file(activity)
            size += len(data or b"")
            self._kept[activity.key] = _summary(data)
            self.newly_read += 1
        found = [Read(a, self._kept[a.key]) for a in batch]
        self.read += found
        if to_read:
            states = [self._kept[a.key] for a in to_read]
            log.info("activities: %d of %d read, %d now in %.1f s (%s); %d still being "
                     "written, %d damaged, %d no FIT file", len(self.read), len(self.listing),
                     len(to_read), time.monotonic() - started, applog.size(size),
                     sum(1 for s in states if s and s.state is fit.FileState.STILL_BEING_WRITTEN),
                     sum(1 for s in states if s and s.state is fit.FileState.DAMAGED),
                     sum(1 for s in states if s is None))
        return found

    def read_file(self, activity: Activity) -> bytes | None:
        """The bytes of an activity's file; None for a copy in a backup that could not be read
        (one line of the log). An error of the device: DeviceError."""
        if activity.source is Source.DEVICE:
            return self.storage.read_at(activity.path)
        try:
            return Path(activity.path).read_bytes()
        except OSError as e:
            log.info("activities: a copy in a backup could not be read (%s)", type(e).__name__)
            return None
