"""The command line's own Strava commands: `strava connect|disconnect|status|upload FILE…`
and `setup --strava-upload on|off`. No network (tests/strava_fakes.py); no real Keychain or
device (conftest's autouse fixtures)."""

from __future__ import annotations

import time

import pytest
from strava_fakes import fake_strava  # noqa: F401 - the fixture

from openexpress import cli, strava
from openexpress.settings import Settings


def test_strava_status_without_anything_configured(capsys):
    assert cli.main(["strava", "status"]) == 0
    assert "no API application" in capsys.readouterr().out


def test_strava_status_configured_but_not_connected(capsys):
    strava.save_client(strava.Client("cid", "csecret"))
    assert cli.main(["strava"]) == 0  # bare "strava": the same as "strava status"
    assert "not connected" in capsys.readouterr().out.lower()


def test_strava_status_connected(capsys):
    strava.save_client(strava.Client("cid", "csecret"))
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600, athlete_name="Ada"))
    assert cli.main(["strava", "status"]) == 0
    assert "connected as Ada" in capsys.readouterr().out


def test_strava_connect_saves_the_client_and_the_token(capsys, fake_strava, monkeypatch):
    import urllib.request
    from urllib.parse import parse_qs, urlsplit

    fake_strava.queue(200, {"access_token": "AT", "refresh_token": "RT",
                            "expires_at": int(time.time()) + 21600,
                            "athlete": {"id": 1, "firstname": "Ada", "lastname": "L"}})

    def open_browser(url: str) -> bool:
        redirect = parse_qs(urlsplit(url).query)["redirect_uri"][0]
        with urllib.request.urlopen(f"{redirect}?code=abc", timeout=5) as resp:
            resp.read()
        return True

    monkeypatch.setattr(strava.webbrowser, "open", open_browser)
    code = cli.main(["strava", "connect", "--client-id", "cid", "--client-secret", "csecret"])
    assert code == 0
    assert "connected as Ada L" in capsys.readouterr().out
    assert strava.status().connected


def test_strava_connect_without_a_client_is_an_error(capsys):
    code = cli.main(["strava", "connect"])
    assert code == 1
    assert "no strava api application" in capsys.readouterr().err.lower()


def test_strava_disconnect(capsys, fake_strava):
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600))
    fake_strava.queue(200, {})
    assert cli.main(["strava", "disconnect"]) == 0
    assert "Disconnected" in capsys.readouterr().out
    assert cli.main(["strava", "disconnect"]) == 0
    assert "was not connected" in capsys.readouterr().out


def test_strava_upload_is_a_dry_run_by_default(capsys, tmp_path, fake_strava):
    from conftest import make_fit

    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600))
    fit = tmp_path / "act.fit"
    fit.write_bytes(make_fit(1))
    assert cli.main(["strava", "upload", str(fit)]) == 0
    out = capsys.readouterr().out
    assert "Would upload act.fit" in out and "Dry run" in out
    assert fake_strava.requests == []


def test_strava_upload_apply_sends_the_file(capsys, tmp_path, fake_strava):
    from conftest import make_fit

    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600))
    fit = tmp_path / "act.fit"
    fit.write_bytes(make_fit(1))
    fake_strava.queue(201, {"id": 1, "activity_id": 2})
    assert cli.main(["strava", "upload", "--apply", str(fit)]) == 0
    assert "Uploaded act.fit" in capsys.readouterr().out


def test_strava_upload_apply_without_a_connection_is_an_error(capsys, tmp_path):
    from conftest import make_fit

    fit = tmp_path / "act.fit"
    fit.write_bytes(make_fit(1))
    assert cli.main(["strava", "upload", "--apply", str(fit)]) == 1
    assert "Not connected to Strava" in capsys.readouterr().err


def test_setup_strava_upload_on_off_persists_the_setting(capsys):
    assert Settings.load().strava_upload is False
    assert cli.main(["setup", "--strava-upload", "on"]) == 0
    assert "Strava upload after each sync: on" in capsys.readouterr().out
    assert Settings.load().strava_upload is True
    assert cli.main(["setup", "--strava-upload", "off"]) == 0
    assert Settings.load().strava_upload is False


def test_setup_without_the_option_leaves_the_setting_untouched():
    cli.main(["setup", "--strava-upload", "on"])
    cli.main(["setup", "--locale", "fr_FR"])
    assert Settings.load().strava_upload is True


def test_setup_strava_upload_rejects_anything_else_than_on_or_off():
    with pytest.raises(SystemExit) as stopped:
        cli.main(["setup", "--strava-upload", "weird"])
    assert stopped.value.code == 2
