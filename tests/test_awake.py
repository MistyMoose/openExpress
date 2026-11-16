"""Keeping the computer awake while a device is written: blocked and released around the work,
said in the log; when it cannot be blocked, the work goes on with a warning. No desktop or logind
is asked here (conftest.no_sleep_blocked)."""

import logging

import pytest

from openexpress import awake


def test_sleep_is_blocked_while_the_work_runs_and_released_after(no_sleep_blocked, caplog):
    with caplog.at_level(logging.INFO, logger="openexpress.awake"), \
            awake.kept_awake("a map is written") as blocked:
        assert blocked and no_sleep_blocked == [("block", "a map is written")]
    assert no_sleep_blocked[-1][0] == "release"
    lines = [r.getMessage() for r in caplog.records if r.name == "openexpress.awake"]
    assert lines == ["awake: sleep and idle blocked while a map is written",
                     "awake: sleep allowed again"]


def test_released_also_when_the_work_fails(no_sleep_blocked):
    with pytest.raises(RuntimeError), awake.kept_awake("a map is written"):
        raise RuntimeError("stopped")
    assert [kind for kind, _token in no_sleep_blocked] == ["block", "release"]


def test_when_sleep_cannot_be_blocked_the_work_goes_on_with_a_warning(monkeypatch, caplog):
    def refused(why):
        raise OSError("no desktop portal, no logind")

    monkeypatch.setattr(awake, "_inhibit", refused)
    released = []
    monkeypatch.setattr(awake, "_release", released.append)
    told = []
    with caplog.at_level(logging.INFO, logger="openexpress.awake"), \
            awake.kept_awake("a map is written", say=told.append) as blocked:
        assert not blocked
    assert told == [awake.not_blocked_text()] and released == []
    assert any(r.getMessage() == "awake: sleep not blocked (OSError): a map is written goes on"
               for r in caplog.records)


def test_a_release_that_fails_is_only_logged(monkeypatch, no_sleep_blocked, caplog):
    def broken(token):
        raise OSError("the portal went away")

    monkeypatch.setattr(awake, "_release", broken)
    with caplog.at_level(logging.INFO, logger="openexpress.awake"), \
            awake.kept_awake("a map is written"):
        pass
    assert any("awake: sleep not released (OSError)" in r.getMessage() for r in caplog.records)


@pytest.mark.parametrize("language", ["en", "pl"])
def test_the_warning_in_both_languages(language):
    from openexpress import i18n

    words = {"en": "openExpress could not keep the computer from sleeping: keep it awake until "
                   "the copy has ended.",
             "pl": "openExpress nie mógł zablokować uśpienia komputera: nie usypiaj go do końca "
                   "kopiowania."}
    try:
        i18n.setup(language)
        assert awake.not_blocked_text() == words[language]
    finally:
        i18n.setup("en")
