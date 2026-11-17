"""Local backup of watch data.

Copies files of all data types the device exposes for reading
(OutputFromUnit), plus GarminDevice.xml. Media, maps and software are
skipped. The `keep` most recent backups are retained.

Incremental: a file whose relative path, size and modification time match the previous backup
is hard-linked into the new one (os.link) instead of being read from the device again; the
file's modification time on the device is kept on its copy (os.utime) so that the next backup
can compare against it. A destination filesystem that does not support hard links (most FAT
volumes) falls back to an ordinary copy for that file; `keep` still prunes old backups safely,
as a file linked from an older one is simply another name for the same data until the last
backup holding it is removed.
"""

from __future__ import annotations

import logging
import os
import posixpath
import shutil
import stat
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from openexpress import applog, paths
from openexpress.device.storage import DeviceError, Entry, Storage, refresh_to_read_again
from openexpress.device.xmldevice import OUTPUT, GarminDevice
from openexpress.fit import not_whole
from openexpress.i18n import _, ngettext
from openexpress.progress import Step, say_to
from openexpress.sync import files_of

log = logging.getLogger(__name__)

SKIP_PREFIXES = ("MEDIA_", "IQ")
SKIP_TYPES = {"ErrorShutdownReports", "ULFLogs", "ExpressRequest", "WiFiConfiguration"}
STAMP = "%Y-%m-%d (%H.%M.%S)"
PARTIAL_PREFIX = ".partial-"


@dataclass
class BackupResult:
    path: Path
    files: int  # copied + linked
    bytes: int  # copied_bytes + linked_bytes
    removed: list[Path]
    # FIT files the device was still writing when they were read: left out (incomplete_text).
    incomplete: int = 0
    # Of `files`/`bytes`: read from the device and written, and hard-linked from the previous
    # backup instead (unchanged: same relative path, size and modification time).
    copied: int = 0
    copied_bytes: int = 0
    linked: int = 0
    linked_bytes: int = 0


def backup_files(device: GarminDevice) -> list:
    return [
        f for f in device.files
        if f.direction == OUTPUT
        and f.datatype not in SKIP_TYPES
        and not f.datatype.startswith(SKIP_PREFIXES)
    ]


def is_backup_dir(p: Path) -> bool:
    if not p.is_dir():
        return False
    try:
        datetime.strptime(p.name, STAMP)
    except ValueError:
        return False
    return True


def backups_of(root: Path, unit_id: int | None) -> list[tuple[datetime, Path]]:
    """The backups of the device `unit_id` in `root` (the folder of every device's backups),
    newest first, as (when it was made, its folder): only folders named as a backup is named,
    never a symbolic link. None when the folder cannot be listed (one line of the log)."""
    folder = root / str(unit_id) if unit_id else None
    try:
        if folder is None or not folder.is_dir():
            return []
        found = [(datetime.strptime(p.name, STAMP), p) for p in folder.iterdir()
                 if not p.is_symlink() and is_backup_dir(p)]
    except OSError as e:
        log.info("backups: the folder could not be listed (%s)", type(e).__name__)
        return []
    return sorted(found, key=lambda t: t[0], reverse=True)


def keep_newest(folders: list[Path], keep: int, new: Path | None = None,
                remove: Callable[[Path], None] = shutil.rmtree) -> list[Path]:
    """Of `folders` (oldest first) all but the newest `keep` are removed, never `new` (the one
    just made); 0 keeps them all. The one rule for the full backups and the copies of the app
    list. Returns those removed."""
    removed = []
    if keep > 0:
        for p in folders[:-keep]:
            if p == new:
                continue
            remove(p)
            removed.append(p)
    return removed


def _not_a_path(name: str) -> DeviceError:
    return DeviceError(_("Nothing was backed up: the device names a folder or file “{name}” "
                         "that cannot be used as a path on this computer.").format(name=name))


def _out_path(target: Path, datatype: str, rel: str) -> Path:
    """Where a file of the device goes in the backup: target/<data type>/<path below its
    folder>. The data type's name (from GarminDevice.xml) and each part of the file's path
    (as the device lists it) must be plain names, and the result must lie within target;
    anything else refuses the backup (a crafted XML or listing must not write elsewhere)."""
    parts = rel.split("/")
    if not paths.is_safe_component(datatype):
        raise _not_a_path(datatype)
    if not all(paths.is_safe_component(p) for p in parts):
        raise _not_a_path(rel)
    out = target.joinpath(datatype, *parts)
    if not paths.is_inside(out, target):
        raise _not_a_path(rel)
    return out


def incomplete_text(count: int) -> str:
    """After a backup, in the window and on the command line: FIT files left out of it, cut
    short as the device was still writing them."""
    return ngettext(
        # TRANSLATORS: after a backup (a message of the window and a line of the command line)
        "{count} file was still being written by the device and is not in the backup. "
        "Unplug the device and plug it in again, then make the backup again.",
        "{count} files were still being written by the device and are not in the backup. "
        "Unplug the device and plug it in again, then make the backup again.",
        count).format(count=count)


def _fit_check(path: str, data: bytes) -> tuple[bool, str] | None:
    """How a FIT file is not whole (fit.not_whole); None for one that is, or another file."""
    return not_whole(data) if path.casefold().endswith(".fit") else None


# A destination filesystem's modification time may have coarser resolution than the device's
# (most FAT volumes: 2 s); a file kept unchanged is still a match within that.
MTIME_TOLERANCE = 2.0


def _unchanged(prev_path: Path, entry: Entry) -> bool:
    """Whether `prev_path` (the same relative path in the previous backup) is the device's
    `entry` already: a plain file of the same size, and the same modification time as the
    device reports now, which a copied file keeps (os.utime, below; the previous backup made
    it the same way). False for anything that stops this from being certain, never raised."""
    try:
        st = prev_path.stat()
    except OSError:
        return False
    return (not stat.S_ISDIR(st.st_mode) and st.st_size == entry.size
            and abs(st.st_mtime - entry.mtime) <= MTIME_TOLERANCE)


@dataclass
class _CopyTally:
    copied: int = 0
    copied_bytes: int = 0
    linked: int = 0
    linked_bytes: int = 0
    incomplete: int = 0


def _copy_files(device: GarminDevice, storage: Storage, target: Path, previous: Path | None,
                progress: Callable[[str], None]) -> _CopyTally:
    """`progress`: which file of how many ("Copying to the backup · 120 of 1530"), never its
    name. A FIT file is checked as a sync checks it (fit.not_whole): one the device wrote while
    it was connected is read cut short (gvfs keeps the size it had when it was first looked
    at), so it is read once more after the device is mounted again (at most once a backup);
    still cut short, it is left out. One not whole otherwise is copied as it is, the backup
    faithful. `previous`: the most recent earlier backup of this device (None: there is none,
    or the file is new or changed there): a file matching there (_unchanged) is hard-linked
    instead of being read from the device again; a filesystem that does not support that
    (OSError) falls back to reading and copying it, as if there were no previous backup for
    that one file."""
    # Every data type checked before anything is written.
    for src in backup_files(device):
        if not paths.is_safe_component(src.datatype):
            raise _not_a_path(src.datatype)
    # All the files first, for how many there are; each path is checked before any is read.
    files = []
    for src, path, entry in files_of(storage, backup_files(device)):
        rel = posixpath.relpath(path, storage.resolve(src.path) or src.path)
        files.append((path, entry, src.datatype, _out_path(target, src.datatype, rel)))
    # TRANSLATORS: a step of a backup ("… · 120 of 1530")
    head = _("Copying to the backup")
    # Every file of the backup counted, GarminDevice.xml (read already) the first.
    count = len(files) + 1
    progress(Step(head, 1, count))
    (target / "GarminDevice.xml").write_bytes(device.raw)
    tally = _CopyTally(copied=1, copied_bytes=len(device.raw))  # GarminDevice.xml: never linked
    refreshed: bool | None = None  # at most once a backup; None: not asked yet
    for n, (path, entry, datatype, out) in enumerate(files, 2):
        progress(Step(head, n, count))
        out.parent.mkdir(parents=True, exist_ok=True)
        if previous is not None:
            prev_path = previous / out.relative_to(target)
            if _unchanged(prev_path, entry):
                try:
                    os.link(prev_path, out)
                except OSError as e:
                    log.info("backup: a %s file could not be hard-linked (%s); copied instead",
                             datatype, type(e).__name__)
                else:
                    log.debug("backup: file %d of %d linked from the previous backup (%s)",
                              n, count, datatype)
                    tally.linked += 1
                    tally.linked_bytes += entry.size
                    continue
        log.debug("backup: copying file %d of %d (%s)", n, count, datatype)
        data = storage.read(path)
        found = _fit_check(path, data)
        # The type and the sizes: never the name of the file.
        if found and found[0]:
            # Read cut short: once the device is mounted again gvfs gives fresh sizes.
            if refreshed is None:
                refreshed = refresh_to_read_again(storage, progress)
                if not refreshed:
                    log.info("backup: the device was not mounted again; files read cut short "
                             "are left out")
            if refreshed:
                data = storage.read(path)
                found = _fit_check(path, data)
                log.info("backup: a %s file read again after the device was mounted again: %s",
                         datatype, found[1] if found else "whole")
        if found and found[0]:
            log.warning("backup: a %s file still being written by the device (%s); not in "
                        "the backup", datatype, found[1])
            tally.incomplete += 1
            continue
        if found:
            log.info("backup: a %s file is not a whole FIT file (%s); copied as it is",
                     datatype, found[1])
        out.write_bytes(data)
        # Kept as the device has it, not as it was just written, so that the next backup can
        # compare against it (_unchanged) without reading the file again.
        os.utime(out, (entry.mtime, entry.mtime))
        tally.copied += 1
        tally.copied_bytes += len(data)  # what was read: a listing before a refresh may give less
    return tally


def run_backup(
    device: GarminDevice,
    storage: Storage,
    dest_root: Path,
    keep: int = 3,
    progress: Callable[[str], None] | None = None,
) -> BackupResult:
    progress = say_to(progress)
    unit_dir = dest_root / str(device.unit_id)
    stamp = datetime.now().strftime(STAMP)
    target = unit_dir / stamp
    if target.exists():
        raise FileExistsError(target)
    unit_dir.mkdir(parents=True, exist_ok=True)
    # Leftovers of interrupted backups.
    for p in unit_dir.glob(PARTIAL_PREFIX + "*"):
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
    # A link named like a backup is the user's own, as backups_of has it: never removed, and
    # never taken as the previous backup to link from either.
    existing = sorted((p for p in unit_dir.iterdir() if not p.is_symlink() and is_backup_dir(p)),
                      key=lambda p: datetime.strptime(p.name, STAMP))
    # The most recent earlier backup of this device: its unchanged files are hard-linked
    # instead of read again from the device (_copy_files); None: this is the first.
    previous = existing[-1] if existing else None
    partial = unit_dir / (PARTIAL_PREFIX + stamp)
    partial.mkdir()
    try:
        tally = _copy_files(device, storage, partial, previous, progress)
        partial.rename(target)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    removed = keep_newest([*existing, target], keep, new=target)
    log.info("backup: %d files copied (%s), %d linked from the previous backup (%s), "
             "%d still being written left out, %d old backups removed",
             tally.copied, applog.size(tally.copied_bytes), tally.linked,
             applog.size(tally.linked_bytes), tally.incomplete, len(removed))
    return BackupResult(
        target, tally.copied + tally.linked, tally.copied_bytes + tally.linked_bytes,
        removed, tally.incomplete, tally.copied, tally.copied_bytes, tally.linked,
        tally.linked_bytes)
