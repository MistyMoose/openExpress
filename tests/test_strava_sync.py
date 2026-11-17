"""The sync integration (Settings.strava_upload, cli._strava_dry_run_line /
_strava_sync_upload): after a sync's own upload to Garmin Connect, the device's activity FIT
files are staged (sync.run_drop_folder, into strava.pending_dir) and sent to Strava
(strava.upload_files). Off by default; the dry run shows what would be staged; a Strava
failure (not connected, rate limited) is reported but never fails the sync itself. Garmin
Connect is a fake (tests/fakes.py's SyncAccount, as test_sync_without_omt.py uses); Strava is
the fake HTTP layer of tests/strava_fakes.py. No real device, network or Keychain."""

from __future__ import annotations

import time

import pytest
from fakes import SyncAccount
from strava_fakes import fake_strava  # noqa: F401 - the fixture

from openexpress import applog, cli, strava
from openexpress.settings import Settings

UNIT = SyncAccount.UNIT  # the test device's unit ID (tests/conftest.py's DEVICE_XML)
ACTIVITIES = ["2026-10-01-10-00-00.fit", "2026-10-02-10-00-00.fit"]  # device_root's own


@pytest.fixture(autouse=True)
def _close_log():
    yield
    applog.close()


def _connect_strava():
    strava.save_client(strava.Client("cid", "csecret"))
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600))


def test_off_by_default_nothing_is_staged_or_sent(device_root, monkeypatch, fake_strava):
    monkeypatch.setattr(cli, "make_client", lambda settings, need_auth: SyncAccount())
    assert Settings.load().strava_upload is False
    code = cli.main(["--path", str(device_root), "sync", "--apply", "--all"])
    assert code == 0
    assert fake_strava.requests == []
    assert not strava.pending_dir(UNIT).exists()


def test_dry_run_counts_the_activities_without_any_network(device_root, monkeypatch, fake_strava,
                                                            capsys):
    monkeypatch.setattr(cli, "make_client", lambda settings, need_auth: SyncAccount())
    cli.main(["setup", "--strava-upload", "on"])
    code = cli.main(["--path", str(device_root), "sync"])
    assert code == 0
    out = capsys.readouterr().out
    assert "To Strava: 2 new activity files" in out
    assert fake_strava.requests == []  # a dry run never reaches Strava


def test_apply_stages_and_uploads_the_activities(device_root, monkeypatch, fake_strava, capsys):
    monkeypatch.setattr(cli, "make_client", lambda settings, need_auth: SyncAccount())
    cli.main(["setup", "--strava-upload", "on"])
    _connect_strava()
    fake_strava.queue(201, {"id": 1, "activity_id": 101})
    fake_strava.queue(201, {"id": 2, "activity_id": 102})
    code = cli.main(["--path", str(device_root), "sync", "--apply", "--all"])
    assert code == 0
    out = capsys.readouterr().out
    assert "Uploaded to Strava: 2 activities" in out
    staged = sorted(p.name for p in strava.pending_dir(UNIT).glob("*.fit"))
    assert staged == sorted(ACTIVITIES)
    for name in ACTIVITIES:
        data = (strava.pending_dir(UNIT) / name).read_bytes()
        assert strava.uploaded_activity(strava.external_id(name, data)) is not None


def test_a_second_sync_does_not_stage_or_send_the_same_activities_again(
        device_root, monkeypatch, fake_strava):
    monkeypatch.setattr(cli, "make_client", lambda settings, need_auth: SyncAccount())
    cli.main(["setup", "--strava-upload", "on"])
    _connect_strava()
    fake_strava.queue(201, {"id": 1, "activity_id": 101})
    fake_strava.queue(201, {"id": 2, "activity_id": 102})
    assert cli.main(["--path", str(device_root), "sync", "--apply", "--all"]) == 0
    assert len(fake_strava.requests) == 2
    assert cli.main(["--path", str(device_root), "sync", "--apply", "--all"]) == 0
    assert len(fake_strava.requests) == 2  # nothing new: no further request


def test_not_being_connected_is_reported_but_does_not_fail_the_sync(
        device_root, monkeypatch, fake_strava, capsys):
    monkeypatch.setattr(cli, "make_client", lambda settings, need_auth: SyncAccount())
    cli.main(["setup", "--strava-upload", "on"])
    # strava_upload is on, but `strava connect` was never run.
    code = cli.main(["--path", str(device_root), "sync", "--apply", "--all"])
    assert code == 0  # the Garmin Connect sync itself is unaffected
    err = capsys.readouterr().err
    assert "Not connected to Strava" in err
    # Staged for the next, successful attempt: not read from the device again meanwhile.
    assert {p.name for p in strava.pending_dir(UNIT).glob("*.fit")} == set(ACTIVITIES)


def test_rate_limited_is_reported_and_the_rest_waits_for_the_next_sync(
        device_root, monkeypatch, fake_strava, capsys):
    monkeypatch.setattr(cli, "make_client", lambda settings, need_auth: SyncAccount())
    cli.main(["setup", "--strava-upload", "on"])
    _connect_strava()
    fake_strava.queue(429, {"message": "Rate Limit Exceeded"})
    code = cli.main(["--path", str(device_root), "sync", "--apply", "--all"])
    assert code == 0
    assert "too many uploads" in capsys.readouterr().err.lower()
    assert len(fake_strava.requests) == 1  # the second activity was not tried this time
