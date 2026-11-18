"""Keeping the computer awake on macOS: `caffeinate -i -w <pid>` while the work runs, ended
after it (platform.keep_awake). This file overrides conftest's no_sleep_blocked, which stubs
_inhibit/_release for every other test; no caffeinate is started here."""

import logging
import os

import pytest

from openexpress import awake
from openexpress.platform import macos

pytestmark = pytest.mark.usefixtures("as_mac")


@pytest.fixture(autouse=True)
def no_sleep_blocked():
    """Overrides conftest's: this file is about the real _inhibit/_release of macOS."""
    return


class Caffeinate:
    """subprocess.Popen of caffeinate: what it was started with, and whether it was ended."""

    def __init__(self, cmd, **kwargs):
        self.cmd, self.kwargs = cmd, kwargs
        self.terminated, self.waited = False, None

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        self.waited = timeout


@pytest.fixture
def caffeinate(monkeypatch):
    processes = []

    def popen(cmd, **kwargs):
        processes.append(Caffeinate(cmd, **kwargs))
        return processes[-1]

    monkeypatch.setattr(macos.subprocess, "Popen", popen)
    return processes


def test_kept_awake_runs_caffeinate_and_ends_it_after(caffeinate, caplog):
    with caplog.at_level(logging.INFO, logger="openexpress.awake"), \
            awake.kept_awake("a map is written") as blocked:
        assert blocked
        [process] = caffeinate
        assert not process.terminated
    assert process.terminated and process.waited == macos.RELEASE_TIMEOUT_S
    assert process.cmd == ["caffeinate", "-i", "-w", str(os.getpid())]
    assert process.kwargs["stdout"] is process.kwargs["stderr"] is macos.subprocess.DEVNULL
    lines = [r.getMessage() for r in caplog.records if r.name == "openexpress.awake"]
    assert lines == ["awake: sleep and idle blocked while a map is written",
                     "awake: sleep allowed again"]


def test_without_caffeinate_the_work_goes_on_with_a_warning(monkeypatch):
    def missing(cmd, **kwargs):
        raise FileNotFoundError("caffeinate")

    monkeypatch.setattr(macos.subprocess, "Popen", missing)
    told = []
    with awake.kept_awake("a map is written", say=told.append) as blocked:
        assert not blocked
    assert told == [awake.not_blocked_text()]
