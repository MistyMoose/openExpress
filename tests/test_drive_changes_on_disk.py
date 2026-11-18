"""A change on a drive counts only once it is on the disk: a removal and a new folder put the
folder they are in on the disk at once, as a write does with its file and folder. A drive's
file system (FAT) would else keep them in memory for about half a minute, and a drive
unplugged or gone meanwhile would keep the files removed."""
import errno
import os

import pytest

from openexpress.device import storage as storage_module
from openexpress.device.storage import DeviceError, LocalStorage


@pytest.fixture
def synced(monkeypatch):
    """The folders put on the disk, in their order, each with whether its change was already
    made (the file gone, the folder there) when it was synced."""
    seen = []
    real = storage_module._sync_folder

    def record(folder):
        seen.append(folder)
        real(folder)

    monkeypatch.setattr(storage_module, "_sync_folder", record)
    return seen


def _drive(tmp_path):
    root = tmp_path / "GARMIN-drive"
    (root / "GARMIN" / "Debug" / "dump").mkdir(parents=True)
    (root / "GARMIN" / "Debug" / "dump" / "RAM_bak1.zip").write_bytes(b"made-up dump")
    (root / "GARMIN" / "RemoteSW").mkdir()
    (root / "GARMIN" / "RemoteSW" / "MADEUP.GCD").write_bytes(b"made-up update")
    return root, LocalStorage(root)


def test_a_removal_puts_its_folder_on_the_disk(tmp_path, synced):
    root, st = _drive(tmp_path)
    assert st.delete("GARMIN/Debug/dump/RAM_bak1.zip")
    assert st.delete("GARMIN/RemoteSW/MADEUP.GCD")
    assert synced == [root / "GARMIN" / "Debug" / "dump", root / "GARMIN" / "RemoteSW"]
    assert not (root / "GARMIN" / "RemoteSW" / "MADEUP.GCD").exists()


def test_the_folder_is_synced_after_the_file_is_gone(tmp_path, monkeypatch):
    root, st = _drive(tmp_path)
    gone_when_synced = []
    real = storage_module._sync_folder

    def record(folder):
        gone_when_synced.append(not (folder / "MADEUP.GCD").exists())
        real(folder)

    monkeypatch.setattr(storage_module, "_sync_folder", record)
    st.delete("GARMIN/RemoteSW/MADEUP.GCD")
    assert gone_when_synced == [True]


def test_a_new_folder_puts_the_folder_it_is_in_on_the_disk(tmp_path, synced):
    """A write into folders not there yet: each new folder puts its parent on the disk, then
    the write puts its file's folder there."""
    root, st = _drive(tmp_path)
    st.write_checked("GARMIN/NewFiles/Made-up/course.fit", b"made-up course")
    assert synced[:2] == [root / "GARMIN", root / "GARMIN" / "NewFiles"]
    assert synced[-1] == root / "GARMIN" / "NewFiles" / "Made-up"
    assert (root / "GARMIN" / "NewFiles" / "Made-up" / "course.fit").read_bytes() == \
        b"made-up course"


def test_a_removal_that_cannot_reach_the_disk_fails(tmp_path, monkeypatch):
    """The drive went away between the removal and its folder's sync (EIO): the removal is not
    told as done, it may be lost."""
    _root, st = _drive(tmp_path)

    def gone(_fd):
        raise OSError(errno.EIO, os.strerror(errno.EIO))

    monkeypatch.setattr(storage_module.os, "fsync", gone)
    with pytest.raises(DeviceError, match="Cannot delete GARMIN/RemoteSW/MADEUP.GCD"):
        st.delete("GARMIN/RemoteSW/MADEUP.GCD")


def test_a_file_system_that_cannot_sync_a_folder_is_no_error(tmp_path, monkeypatch):
    _root, st = _drive(tmp_path)

    def cannot(_fd):
        raise OSError(errno.EINVAL, os.strerror(errno.EINVAL))

    monkeypatch.setattr(storage_module.os, "fsync", cannot)
    assert st.delete("GARMIN/RemoteSW/MADEUP.GCD")
    assert not st.exists("GARMIN/RemoteSW/MADEUP.GCD")
