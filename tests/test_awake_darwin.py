"""Keeping the computer awake on macOS (awake._inhibit_darwin): an IOKit assertion against idle
sleep, released the same way; `caffeinate -i -w <pid>` instead when IOKit cannot be asked. This
file overrides conftest's no_sleep_blocked (which stubs _inhibit/_release for every other test)
so that kept_awake exercises the real darwin implementation."""

import logging
import os
import sys
import types

import pytest

from openexpress import awake


@pytest.fixture(autouse=True)
def no_sleep_blocked():
    """Overrides conftest's: this file is about the real darwin _inhibit/_release, not a
    stand-in for them."""
    return None


@pytest.fixture(autouse=True)
def darwin(monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")


def test_kept_awake_asks_iokit_and_releases_its_assertion(monkeypatch, caplog):
    created, released = [], []
    monkeypatch.setattr(awake, "_iopm_assertion_create",
                        lambda reason: created.append(reason) or 7)
    monkeypatch.setattr(awake, "_iopm_assertion_release", released.append)
    with caplog.at_level(logging.INFO, logger="openexpress.awake"), \
            awake.kept_awake("a map is written") as blocked:
        assert blocked
    assert created == ["openExpress: a map is written"]
    assert released == [7]
    lines = [r.getMessage() for r in caplog.records if r.name == "openexpress.awake"]
    assert lines == ["awake: sleep and idle blocked while a map is written",
                     "awake: sleep allowed again"]


def test_kept_awake_falls_back_to_caffeinate_when_iokit_cannot_be_asked(monkeypatch):
    def refused(reason):
        raise OSError("no IOKit here")

    process = types.SimpleNamespace(terminated=False, waited=False)
    process.terminate = lambda: setattr(process, "terminated", True)
    process.wait = lambda timeout=None: setattr(process, "waited", True)
    monkeypatch.setattr(awake, "_iopm_assertion_create", refused)
    monkeypatch.setattr(awake, "_caffeinate_fallback", lambda: process)
    with awake.kept_awake("a map is written") as blocked:
        assert blocked
    assert process.terminated and process.waited


def test_inhibit_darwin_returns_an_iokit_token_on_success(monkeypatch):
    monkeypatch.setattr(awake, "_iopm_assertion_create", lambda reason: 3)
    assert awake._inhibit_darwin("a map is written") == ("iokit", None, 3)


def test_inhibit_darwin_logs_and_falls_back_when_iokit_assertion_fails(monkeypatch, caplog):
    def refused(reason):
        raise OSError("no IOKit here")

    monkeypatch.setattr(awake, "_iopm_assertion_create", refused)
    monkeypatch.setattr(awake, "_caffeinate_fallback", lambda: "a-process")
    with caplog.at_level(logging.INFO, logger="openexpress.awake"):
        assert awake._inhibit_darwin("a map is written") == ("caffeinate", None, "a-process")
    assert any("IOKit did not keep it awake" in r.getMessage() for r in caplog.records)


def test_caffeinate_fallback_runs_the_expected_command(monkeypatch):
    calls = []

    class FakeProcess:
        pass

    def fake_popen(cmd, **kwargs):
        calls.append((cmd, kwargs))
        return FakeProcess()

    monkeypatch.setattr(awake.subprocess, "Popen", fake_popen)
    process = awake._caffeinate_fallback()
    assert isinstance(process, FakeProcess)
    [(cmd, kwargs)] = calls
    assert cmd == ["caffeinate", "-i", "-w", str(os.getpid())]
    assert kwargs["stdout"] is awake.subprocess.DEVNULL
    assert kwargs["stderr"] is awake.subprocess.DEVNULL


def test_release_darwin_releases_the_iokit_assertion(monkeypatch):
    released = []
    monkeypatch.setattr(awake, "_iopm_assertion_release", released.append)
    awake._release_darwin("iokit", 9)
    assert released == [9]


def test_release_darwin_terminates_and_waits_for_the_caffeinate_process():
    process = types.SimpleNamespace(terminated=False, waited_timeout=None)
    process.terminate = lambda: setattr(process, "terminated", True)
    process.wait = lambda timeout=None: setattr(process, "waited_timeout", timeout)
    awake._release_darwin("caffeinate", process)
    assert process.terminated
    assert process.waited_timeout == pytest.approx(awake._ANSWER_MS / 1000)


def test_iopm_assertion_create_and_release_round_trip_for_real():
    """A real call into IOKit (no mock): the two functions this module's darwin branch is
    built on actually work on this machine."""
    assertion_id = awake._iopm_assertion_create("openExpress: a test")
    assert isinstance(assertion_id, int) and assertion_id > 0
    awake._iopm_assertion_release(assertion_id)  # raises OSError on failure
