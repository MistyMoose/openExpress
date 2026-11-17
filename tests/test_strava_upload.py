"""Uploading FIT files to Strava (openexpress.strava.upload_files): the multipart POST and the
poll until Strava has matched it to an activity, a duplicate (Strava's own message, or the
local record of what this installation already sent), a 429 that stops the rest of the list,
and files that are skipped rather than sent (not a FIT file, unreadable). No network
(tests/strava_fakes.py); conftest's `private_dirs`/`no_real_keychain` (both autouse) keep the
token and the local record in this test's own tmp_path."""

from __future__ import annotations

import time
from pathlib import Path

import pytest
from strava_fakes import fake_strava  # noqa: F401 - the fixture

from openexpress import strava


@pytest.fixture(autouse=True)
def connected():
    """Every test here starts connected: a fresh, non-expiring token."""
    strava.save_client(strava.Client("cid", "csecret"))
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600, athlete_id=1))


@pytest.fixture
def fit_file(tmp_path) -> Path:
    from conftest import make_fit

    path = tmp_path / "2026-10-01-10-00-00.fit"
    path.write_bytes(make_fit(1100000000))
    return path


def test_upload_sends_the_file_and_marks_it_done_once_strava_confirms_it(fake_strava, fit_file):
    fake_strava.queue(201, {"id": 555, "external_id": "x", "activity_id": 999})
    report = strava.upload_files([fit_file], apply=True)
    assert report.uploaded == [fit_file.name]
    assert report.duplicates == report.failed == []
    req = fake_strava.requests[0]
    assert req.method == "POST" and req.url == strava.UPLOAD_URL
    assert req.headers["Authorization"] == "Bearer AT"
    body = fake_strava.body(0)
    assert b'name="data_type"' in body and b"fit" in body
    assert b'name="external_id"' in body and fit_file.name.encode() in body
    assert strava.uploaded_activity(strava.external_id(fit_file.name, fit_file.read_bytes())) \
        == 999


def test_a_file_already_in_the_local_record_is_not_read_or_sent_again(fake_strava, fit_file):
    fake_strava.queue(201, {"id": 1, "activity_id": 2})
    strava.upload_files([fit_file], apply=True)
    assert len(fake_strava.requests) == 1
    fit_file.write_bytes(b"replaced: reading this would be a bug if it is not skipped")
    report = strava.upload_files([fit_file], apply=True)
    assert report.duplicates == [fit_file.name] and report.uploaded == []
    assert len(fake_strava.requests) == 1  # no second request


def test_strava_s_own_duplicate_message_is_not_an_error(fake_strava, fit_file):
    fake_strava.queue(201, {"id": 1, "error": "duplicate of activity 777"})
    report = strava.upload_files([fit_file], apply=True)
    assert report.duplicates == [fit_file.name] and report.failed == []
    assert strava.uploaded_activity(
        strava.external_id(fit_file.name, fit_file.read_bytes())) == 777


def test_an_upload_still_processing_is_polled_until_it_is_done(fake_strava, fit_file, monkeypatch):
    monkeypatch.setattr(strava.time, "sleep", lambda seconds: None)
    fake_strava.queue(201, {"id": 1})  # accepted, not matched to an activity yet
    fake_strava.queue(200, {"id": 1, "activity_id": 42})  # the poll: now it is
    report = strava.upload_files([fit_file], apply=True)
    assert report.uploaded == [fit_file.name]
    assert len(fake_strava.requests) == 2
    assert fake_strava.requests[1].method == "GET"
    assert fake_strava.requests[1].url == f"{strava.UPLOAD_URL}/1"


def test_an_error_strava_gives_that_is_not_a_duplicate_is_reported_and_does_not_raise(
        fake_strava, fit_file):
    fake_strava.queue(201, {"id": 1, "error": "FIT activities require a start time"})
    report = strava.upload_files([fit_file], apply=True)
    assert report.failed == [
        (fit_file.name, "Strava rejected the file: FIT activities require a start time")]
    assert report.uploaded == report.duplicates == []
    assert strava.uploaded_activity(
        strava.external_id(fit_file.name, fit_file.read_bytes())) is None


def test_a_429_stops_the_rest_of_the_list_for_this_call(fake_strava, tmp_path):
    from conftest import make_fit

    one = tmp_path / "a.fit"
    one.write_bytes(make_fit(1))
    two = tmp_path / "b.fit"
    two.write_bytes(make_fit(2))
    fake_strava.queue(429, {"message": "Rate Limit Exceeded"},
                      headers={"X-RateLimit-Usage": "100,1000"})
    report = strava.upload_files([one, two], apply=True)
    assert report.rate_limited is True
    assert report.uploaded == report.duplicates == []
    assert len(report.failed) == 1 and report.failed[0][0] == one.name
    assert len(fake_strava.requests) == 1  # "two" was never tried


def test_a_file_that_is_not_fit_is_skipped_without_a_network_call(fake_strava, tmp_path):
    other = tmp_path / "notes.txt"
    other.write_text("not FIT")
    report = strava.upload_files([other], apply=True)
    assert report.skipped == [(other.name, "not a FIT file")]
    assert fake_strava.requests == []


def test_a_file_that_cannot_be_read_is_skipped(fake_strava, tmp_path):
    report = strava.upload_files([tmp_path / "missing.fit"], apply=True)
    assert len(report.skipped) == 1 and report.skipped[0][0] == "missing.fit"
    assert fake_strava.requests == []


def test_a_dry_run_reaches_no_network_and_needs_no_token(fake_strava, fit_file):
    strava.delete_token()
    report = strava.upload_files([fit_file], apply=False)
    assert report.uploaded == [fit_file.name]
    assert fake_strava.requests == []


def test_a_dry_run_still_says_what_is_already_on_record(fake_strava, fit_file):
    fake_strava.queue(201, {"id": 1, "activity_id": 2})
    strava.upload_files([fit_file], apply=True)
    report = strava.upload_files([fit_file], apply=False)
    assert report.duplicates == [fit_file.name] and report.uploaded == []


def test_apply_without_a_connection_raises_not_connected(fake_strava, fit_file):
    strava.delete_token()
    with pytest.raises(strava.NotConnected):
        strava.upload_files([fit_file], apply=True)


def test_progress_is_told_a_step_per_file(fake_strava, fit_file, tmp_path):
    from conftest import make_fit

    two = tmp_path / "2026-10-02-10-00-00.fit"
    two.write_bytes(make_fit(2))
    fake_strava.queue(201, {"id": 1, "activity_id": 2})
    fake_strava.queue(201, {"id": 2, "activity_id": 3})
    seen = []
    strava.upload_files([fit_file, two], apply=True, progress=seen.append)
    assert len(seen) == 2
    assert all("Strava" in str(step) for step in seen)
