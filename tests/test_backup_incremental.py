"""Incremental backups (macOS fork): a file unchanged since the previous backup (same relative
path, size and modification time) is hard-linked into the new one instead of being read from
the device again, so that keeping several snapshots costs little extra space; `keep` still
prunes safely, a file linked from a removed backup staying alive through the one that still
links to it. A destination filesystem that does not support hard links falls back to copying.
All devices and files are made up."""

import datetime
import os

import pytest
from conftest import make_fit

from openexpress import backup
from openexpress.device.storage import LocalStorage
from openexpress.device.xmldevice import parse

# device_root (conftest.py): GarminDevice.xml + 2 activities + 1 monitor file + 1 settings
# file = 5 files a backup writes; "notes.txt" has no FIT extension and is not one of them.
DEVICE_FILES = 5


def _device(root):
    st = LocalStorage(root)
    return st, parse(st.read("GARMIN/GarminDevice.xml"))


@pytest.fixture(autouse=True)
def ticking_clock(monkeypatch):
    """Backups are named by the second (backup.STAMP); a test that makes more than one in a
    row (the wall clock might not tick between two calls) gets a distinct moment each time,
    as test_app_list_copies.py does for the same reason."""
    class Clock(datetime.datetime):
        moments = iter(datetime.datetime(2026, 10, 20, 9, 0, n) for n in range(60))

        @classmethod
        def now(cls, tz=None):
            return next(cls.moments)

    monkeypatch.setattr(backup, "datetime", Clock)
    return Clock


def _names(folder) -> set[str]:
    """The files of a backup, not its summary (backup.SUMMARY)."""
    return {str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file()
            and p != folder / backup.SUMMARY}


def test_the_first_backup_of_a_device_copies_everything_and_links_nothing(device_root, tmp_path):
    st, dev = _device(device_root)
    res = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    assert res.files == DEVICE_FILES
    assert res.copied == DEVICE_FILES and res.linked == 0
    assert res.copied_bytes == res.bytes and res.linked_bytes == 0


def test_a_second_backup_of_an_unchanged_device_hard_links_every_file_but_the_xml(
        device_root, tmp_path):
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    # GarminDevice.xml is always written fresh (it is read from the device every time, not
    # compared against the previous backup); every other file matches and is linked.
    assert second.copied == 1 and second.linked == DEVICE_FILES - 1
    assert second.files == DEVICE_FILES
    assert _names(first.path) == _names(second.path)
    for name in _names(second.path):
        if name == "GarminDevice.xml":
            continue
        a, b = (first.path / name).stat(), (second.path / name).stat()
        assert a.st_ino == b.st_ino  # the very same file on disk, not a copy
        assert a.st_dev == b.st_dev


def test_a_changed_file_is_copied_again_not_linked(device_root, tmp_path):
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    changed = device_root / "GARMIN/Activity/2026-10-01-10-00-00.fit"
    changed.write_bytes(make_fit(1100000001))  # the content changes, the size does not
    # Set well outside MTIME_TOLERANCE: the file was truly rewritten, not just within the
    # same second as the fixture made it and the first backup read it.
    os.utime(changed, (2000000000, 2000000000))
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    assert second.linked == DEVICE_FILES - 2  # one activity changed, the xml never linked
    assert second.copied == 2  # the xml and the changed activity
    name = "FIT_TYPE_4/2026-10-01-10-00-00.fit"
    assert (first.path / name).stat().st_ino != (second.path / name).stat().st_ino
    assert (second.path / name).read_bytes() == changed.read_bytes()


def test_a_file_only_renamed_on_the_device_is_not_mistaken_for_an_unrelated_one(
        device_root, tmp_path):
    """Matching is by the same relative path (data type and name): a file the previous backup
    never had at that path is always copied, whatever else is in the folder."""
    st, dev = _device(device_root)
    (device_root / "GARMIN/Activity/2026-10-03-10-00-00.fit").write_bytes(make_fit(1100172800))
    res = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    assert res.copied == DEVICE_FILES + 1 and res.linked == 0  # no previous backup yet


def test_hard_linking_falls_back_to_copying_when_the_filesystem_refuses_it(
        device_root, tmp_path, monkeypatch):
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=3)

    def no_links(_src, _dst):
        raise OSError("made up: this filesystem has no hard links")

    monkeypatch.setattr(os, "link", no_links)
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    assert second.linked == 0
    assert second.copied == DEVICE_FILES  # every file read and copied again, none left out
    name = "FIT_TYPE_32/M1.FIT"
    assert (first.path / name).stat().st_ino != (second.path / name).stat().st_ino
    assert (first.path / name).read_bytes() == (second.path / name).read_bytes()


def test_pruning_removes_only_the_oldest_backup_and_a_file_it_shares_with_a_newer_one_survives(
        device_root, tmp_path):
    """keep=2 after a third backup: the first is removed, but a file hard-linked from it into
    the second (still kept) is not affected, as it is really the second backup's own name for
    that data, not a reference into the first."""
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=2)
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=2)
    name = "FIT_TYPE_2/Settings.fit"
    data_before = (second.path / name).read_bytes()
    third = backup.run_backup(dev, st, tmp_path / "bk", keep=2)
    assert first.path in third.removed and not first.path.exists()
    assert second.path.exists() and third.path.exists()
    assert (second.path / name).read_bytes() == data_before  # unharmed by removing `first`
    assert third.linked == DEVICE_FILES - 1  # linked from `second`, not from the removed `first`


def test_a_fit_file_still_being_written_is_left_out_and_not_linked_either(device_root, tmp_path):
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    # A FIT file the device is still writing: its header declares more than can be read, as
    # fit.not_whole checks it; refresh_to_read_again has nothing to remount here, so it stays
    # left out, same as a first backup would leave it out.
    path = device_root / "GARMIN/Monitor/M1.FIT"
    path.write_bytes(path.read_bytes()[:-5])
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    assert second.incomplete == 1
    assert not (second.path / "FIT_TYPE_32/M1.FIT").exists()
    assert (first.path / "FIT_TYPE_32/M1.FIT").exists()  # the earlier, whole copy is untouched


@pytest.mark.parametrize("keep", [0, 1])
def test_linking_works_the_same_whatever_keep_is(device_root, tmp_path, keep):
    st, dev = _device(device_root)
    backup.run_backup(dev, st, tmp_path / "bk", keep=keep)
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=keep)
    assert second.linked == DEVICE_FILES - 1


def test_each_backup_says_how_many_files_it_has_and_their_size_in_its_summary(
        device_root, tmp_path, monkeypatch):
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    walked = [backup.backup_sizes([p])[0] for p in (second.path, first.path)]
    assert walked == [(DEVICE_FILES, second.bytes), (DEVICE_FILES, first.bytes)]
    looked = []
    monkeypatch.setattr(backup.os, "scandir", lambda p: looked.append(p) or os.scandir(p))
    assert backup.backup_sizes([second.path, first.path]) == walked
    assert looked == []  # the summaries told it, no file was looked at


def test_a_backup_without_a_summary_is_counted_each_file_shared_with_another_looked_at_once(
        device_root, tmp_path):
    st, dev = _device(device_root)
    first = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    second = backup.run_backup(dev, st, tmp_path / "bk", keep=3)
    (first.path / backup.SUMMARY).unlink()  # as a backup of an earlier version
    (second.path / backup.SUMMARY).write_text("damaged")
    (second.path / "link").symlink_to(device_root / "notes.txt")  # never counted
    sizes = backup.backup_sizes([second.path, first.path])
    assert sizes == [(DEVICE_FILES, second.bytes), (DEVICE_FILES, first.bytes)]
    counted: dict = {}
    backup._count_files(second.path, counted)
    looked = dict(counted)
    backup._count_files(first.path, counted)
    # The first backup adds only its own GarminDevice.xml: the others are the same inodes.
    assert len(counted) == len(looked) + 1
