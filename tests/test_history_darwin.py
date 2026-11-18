"""Telling one connection of a device from the next one, on macOS (history._boot, _mount_id):
the start of the computer from `sysctl kern.boottime` (there is no /proc there), and the mount
of a mass-storage drive from the device number of its filesystem (there is no mountinfo
either)."""

import ctypes
import sys

import pytest

from openexpress import history


@pytest.fixture(autouse=True)
def darwin(monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")


def test_boot_dispatches_to_the_darwin_implementation(monkeypatch):
    monkeypatch.setattr(history, "_boot_darwin", lambda: "made-up-boot-time")
    assert history._boot() == "made-up-boot-time"


@pytest.mark.skipif(sys.platform != "darwin", reason="kern.boottime is macOS's")
def test_boot_darwin_reads_the_real_boot_time():
    """A real call into sysctlbyname (no mock): kern.boottime answers with a plausible, stable
    number of seconds."""
    value = history._boot_darwin()
    assert value.isdigit()
    assert value == history._boot_darwin()  # the same while the computer stays up


def test_boot_darwin_fails_soft_without_libc(monkeypatch):
    def broken(*args, **kwargs):
        raise OSError("no libc here")

    monkeypatch.setattr(ctypes, "CDLL", broken)
    assert history._boot_darwin() == ""


def test_mount_id_darwin_is_the_device_number_of_the_filesystem(tmp_path):
    import os

    assert history._mount_id(tmp_path) == str(os.stat(tmp_path).st_dev)


def test_mount_id_darwin_is_none_without_a_root():
    assert history._mount_id(None) is None


def test_mount_id_darwin_is_none_for_a_path_that_cannot_be_read(tmp_path):
    assert history._mount_id(tmp_path / "does-not-exist") is None
