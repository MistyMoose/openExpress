"""The Updates page after openExpress copied an update: the file it wrote is not read back from
the device a second time to be recognised (its size, the server's MD5 and its time on the device
are kept from the copy, also for the next window or command), and a file that must be read says
so with how far the read is. A made-up watch over a folder; all files are made up."""

import hashlib

import pytest

from openexpress import download, updates
from openexpress.connect import lower_keys
from openexpress.device.storage import LocalStorage

SOFTWARE = b"made-up watch software, of the size the server offers"


def server_answer():
    return {"updates": [{
        "partNumber": "006-B0000-00", "productName": "Made-up Watch", "dataType": "Firmware",
        "displayVersion": "2.18", "severity": "Recommended", "isPrimaryFirmware": True,
        "locale": None, "releaseState": "live", "releaseNotes": [], "eulaUrl": None,
        "deliverable": {"downloadUrl": "https://example.org/GUPDATE.GSP",
                        "md5": hashlib.md5(SOFTWARE).hexdigest().upper(),
                        "sizeInBytes": len(SOFTWARE)},
        "installation": {"path": "Garmin", "fileName": "GUPDATE.GSP", "isReinstall": False,
                         "isProductInstalled": True, "isRestartRequired": False, "order": 0}}]}


class _Counting(LocalStorage):
    """The made-up watch, counting the whole reads of a file."""

    def __init__(self, root):
        super().__init__(root)
        self.reads = []

    def _read(self, real_path):
        if real_path.upper().endswith("GUPDATE.GSP"):
            self.reads.append(real_path)
        return super()._read(real_path)


@pytest.fixture
def watch(device_root, monkeypatch, tmp_path):
    def fetch(urls, dest, size, md5, session=None, progress=None):
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(SOFTWARE)
        return dest

    monkeypatch.setattr(updates, "cache_path", lambda u: tmp_path / "cache" / u.filename)
    monkeypatch.setattr(download, "fetch", fetch)
    return _Counting(device_root)


def _offered(storage, progress=None):
    from openexpress import service

    device = service.read_device(storage, found_now=False)
    return updates.offered(storage, lower_keys(server_answer()), device, forget_installed=False,
                           progress=progress)


def test_the_file_it_copied_is_not_read_again(watch, xdg):
    (u,) = _offered(watch)
    updates.install([u], watch)
    watch.reads.clear()
    (again,) = _offered(watch)
    assert again.on_device and watch.reads == []


def test_nor_by_the_next_window_or_command(watch, xdg, monkeypatch):
    (u,) = _offered(watch)
    updates.install([u], watch)
    monkeypatch.setattr(updates, "_md5_read", {})  # another process: nothing in its memory
    watch.reads.clear()
    (again,) = _offered(watch)
    assert again.on_device and watch.reads == []


def test_a_file_changed_since_is_read(watch, xdg, device_root):
    import os

    (u,) = _offered(watch)
    updates.install([u], watch)
    written = next(device_root.rglob("GUPDATE.GSP"))
    os.utime(written, (1_700_000_000, 1_700_000_000))  # another time on the device
    watch.reads.clear()
    (again,) = _offered(watch)
    assert again.on_device and len(watch.reads) == 1


def test_a_file_it_did_not_copy_is_read_once_with_how_far(watch, xdg, device_root):
    (device_root / "GARMIN" / "GUPDATE.GSP").write_bytes(SOFTWARE)  # copied by someone else
    told = []
    (u,) = _offered(watch, progress=told.append)
    assert u.on_device and len(watch.reads) == 1
    n = len(SOFTWARE)
    assert told[-1].replace("\u00a0", " ") == (
        f"Checking the update file · {n} B of {n} B")
    watch.reads.clear()
    (again,) = _offered(watch)
    assert again.on_device and watch.reads == []  # its MD5 kept
