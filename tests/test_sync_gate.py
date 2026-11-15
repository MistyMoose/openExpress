"""A device over MTP whose data Garmin Connect does not take (unit-info: connect support
"Disabled") or whose GarminDevice.xml declares no data that goes from it is not synced, as a
USB drive that is not: the gate, read from a kept answer of unit-info without asking, or once
the window's own request brings one; the account is not asked about such a device. Made-up
devices and answers."""

import types

import pytest
from fakes import device_session

from openexpress import answers, service
from openexpress.connect import NotAccountDevice

UNIT = 3000000001


def _device(uploads=True):
    return types.SimpleNamespace(files=[types.SimpleNamespace(readable=uploads)], unit_id=UNIT,
                                 part_number="006-B0000-00", description="Made-up Drive")


@pytest.mark.parametrize(("uploads", "info", "reason"), [
    (False, None, service.NO_UPLOAD_TYPES),
    (True, {"connectsupport": "Disabled"}, service.CONNECT_DISABLED),
    (True, {"connectsupport": " disabled "}, service.CONNECT_DISABLED),
    (True, {"connectsupport": "Required"}, None),  # a fēnix 8, an Edge 1050
    (True, {}, None),  # Garmin did not refuse it
    (True, None, None),  # no answer: as today, until Garmin says so
])
def test_the_gate_of_a_device_over_mtp(uploads, info, reason):
    assert service.mtp_sync_refusal(_device(uploads), info) == reason


def _session(kept, monkeypatch, **fields):
    asked = []
    monkeypatch.setattr(service, "require_account_device",
                        lambda client, unit_id, part_number=None: asked.append(unit_id) or [])
    client = types.SimpleNamespace(auth=object(), kept_unit_info=lambda unit, part: kept)
    s = device_session(device=_device(), mass_storage=False, logged_in=True, client=client,
                       **fields)
    return s, asked


def test_behind_the_gate_the_account_is_not_asked_of_the_device(monkeypatch):
    s, asked = _session({"connectsupport": "Disabled"}, monkeypatch)
    service.check_session(s)
    assert s.sync_refusal == service.CONNECT_DISABLED
    assert asked == [] and s.ownership_error is None and s.account_devices is None


@pytest.mark.parametrize("kept", [{"connectsupport": "Required"}, None])
def test_without_garmin_s_word_the_device_is_checked_as_today(monkeypatch, kept):
    s, asked = _session(kept, monkeypatch)
    service.check_session(s)
    assert s.sync_refusal is None and asked == [UNIT]


def test_a_drive_keeps_its_own_refusal(monkeypatch):
    s, _asked = _session({"connectsupport": "Disabled"}, monkeypatch)
    s.mass_storage = True
    s.unit_info_answer = {"connectsupport": "Disabled"}
    service.check_session(s)
    assert s.drive_refusal == (service.CONNECT_DISABLED, "") and s.sync_refusal is None


def test_an_answer_that_comes_later_closes_the_gate_once(monkeypatch):
    s, _asked = _session(None, monkeypatch)
    service.check_session(s)
    s.ownership_error, s.account_devices = NotAccountDevice("made-up"), []
    s.unit_info_answer = {"connectsupport": "Disabled"}  # the window's own request
    assert service.note_unit_info(s) is True
    assert s.sync_refusal == service.CONNECT_DISABLED
    # As if the account had not been asked: no "not registered", no primary training device.
    assert s.ownership_error is None and s.account_devices is None
    assert service.note_unit_info(s) is False  # once


def test_a_kept_answer_is_read_without_asking():
    kept = answers.Answers()
    key = ("prod", UNIT, "006-B0000-00")
    assert kept.kept(answers.UNIT_INFO, key) is None
    kept.ask(answers.UNIT_INFO, key, lambda: {"connectsupport": "Disabled"})

    def never():
        raise AssertionError("asked")

    assert kept.kept(answers.UNIT_INFO, key) == {"connectsupport": "Disabled"}
    assert kept.ask(answers.UNIT_INFO, key, never) == {"connectsupport": "Disabled"}


@pytest.mark.parametrize(("reason", "text"), [
    (service.CONNECT_DISABLED,
     ("Garmin's server says that Garmin Connect does not take this device's data (connect "
      "support: Disabled), so it is not synced.")),
    (service.NO_UPLOAD_TYPES,
     ("This device declares no data that goes from it to Garmin Connect, so there is nothing "
      "to sync."))])
def test_the_words_of_the_gate(reason, text):
    assert service.mtp_sync_refusal_text(reason) == text


def test_the_answer_of_unit_info_is_told_to_whoever_listens():
    heard = []
    s = device_session(device=_device(),
                       client=types.SimpleNamespace(unit_info=lambda unit, part: {
                           "connectsupport": "Disabled"}),
                       on_unit_info=lambda: heard.append("answer"))
    assert service.unit_info(s) == {"connectsupport": "Disabled"}
    service.unit_info(s)  # the session's answer again: told once
    assert heard == ["answer"]
