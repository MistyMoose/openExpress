"""Telling one connection of a device from the next one, on macOS (history._boot, _mount_id):
the start of the computer from `sysctl kern.boottime` (there is no /proc there), and the mount
of a mass-storage drive from the device number of its filesystem (there is no mountinfo
either): platform.boot_id and platform.mount_id."""

import ctypes
import os

import pytest

from openexpress import history, platform
from openexpress.platform import macos

pytestmark = pytest.mark.usefixtures("as_mac")


def test_the_boot_is_the_one_of_the_platform(monkeypatch):
    monkeypatch.setattr(macos, "boot_id", lambda: "made-up-boot-time")
    assert history._boot() == "made-up-boot-time"


@pytest.mark.skipif(not platform.is_mac(), reason="kern.boottime is macOS's")
def test_the_boot_is_the_real_boot_time():
    """A real call into sysctlbyname (no mock): kern.boottime answers with a plausible, stable
    number of seconds."""
    value = macos.boot_id()
    assert value.isdigit()
    assert value == macos.boot_id()  # the same while the computer stays up


def test_the_boot_is_empty_without_libc(monkeypatch):
    def broken(*args, **kwargs):
        raise OSError("no libc here")

    monkeypatch.setattr(ctypes, "CDLL", broken)
    assert history._boot() == ""


def test_the_mount_is_the_device_number_of_the_filesystem(tmp_path):
    assert history._mount_id(tmp_path) == str(os.stat(tmp_path).st_dev)


def test_the_mount_is_none_without_a_root():
    assert history._mount_id(None) is None


def test_the_mount_is_none_for_a_path_that_cannot_be_read(tmp_path):
    assert history._mount_id(tmp_path / "does-not-exist") is None
