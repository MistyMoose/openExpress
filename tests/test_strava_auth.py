"""OAuth2 authorization-code sign-in to Strava (openexpress/strava.py): the client ID/secret
saved once (connect(), save_client()), the consent page's address (authorize_url), the code
exchanged for a token (connect_with_code), status() read back, disconnect, and token refresh.
No network: tests/strava_fakes.py patches requests' HTTP adapter; tests/conftest.py's
`no_real_keychain` (autouse) keeps the client ID/secret and the token in a plain file of this
test's own tmp_path (private_dirs, also autouse) instead of the real Keychain."""

from __future__ import annotations

import time
from urllib.parse import parse_qs, urlsplit

import pytest
from strava_fakes import fake_strava  # noqa: F401 - the fixture

from openexpress import strava


def test_not_configured_until_a_client_is_saved():
    assert strava.status() == strava.Status(configured=False, connected=False)
    with pytest.raises(strava.NotConfigured):
        strava.authorize_url("http://localhost:1/strava")


def test_authorize_url_carries_the_saved_client_id_and_the_redirect_uri():
    strava.save_client(strava.Client("my-client-id", "my-client-secret"))
    assert strava.status() == strava.Status(configured=True, connected=False)
    url = strava.authorize_url("http://localhost:12345/strava")
    parsed = urlsplit(url)
    assert parsed.scheme == "https" and parsed.netloc == "www.strava.com"
    params = parse_qs(parsed.query)
    assert params["client_id"] == ["my-client-id"]
    assert params["redirect_uri"] == ["http://localhost:12345/strava"]
    assert params["response_type"] == ["code"]
    assert params["scope"] == [strava.SCOPE]
    # No secret ever goes into the address shown to the user / opened in the browser.
    assert "my-client-secret" not in url


def test_connect_with_code_exchanges_the_code_and_saves_the_token(fake_strava):
    strava.save_client(strava.Client("cid", "csecret"))
    fake_strava.queue(200, {
        "access_token": "AT1", "refresh_token": "RT1", "expires_at": int(time.time()) + 21600,
        "athlete": {"id": 42, "firstname": "Ada", "lastname": "Lovelace"},
    })
    status = strava.connect_with_code("the-code", "http://localhost:9/strava")
    assert status == strava.Status(configured=True, connected=True, athlete_id=42,
                                   athlete_name="Ada Lovelace", scope=strava.SCOPE,
                                   expires_at=status.expires_at)
    assert strava.status() == status
    req = fake_strava.requests[0]
    assert req.method == "POST" and req.url == strava.TOKEN_URL
    body = fake_strava.body(0)
    assert b"the-code" in body and b"cid" in body and b"csecret" in body
    assert b"grant_type=authorization_code" in body


def test_connect_with_code_needs_a_saved_client():
    with pytest.raises(strava.NotConfigured):
        strava.connect_with_code("code", "http://localhost:9/strava")


def test_connect_with_code_raises_on_a_refusal(fake_strava):
    strava.save_client(strava.Client("cid", "csecret"))
    fake_strava.queue(400, {"message": "Bad Request", "errors": [{"field": "code"}]})
    with pytest.raises(strava.StravaError, match="Bad Request"):
        strava.connect_with_code("bad-code", "http://localhost:9/strava")
    assert strava.status().connected is False


def test_disconnect_removes_the_token_but_keeps_the_client(fake_strava):
    strava.save_client(strava.Client("cid", "csecret"))
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600, athlete_id=1))
    fake_strava.queue(200, {})  # Strava's own deauthorize answer: ignored either way
    assert strava.disconnect() is True
    assert strava.load_token() is None
    assert strava.load_client() is not None  # kept: reconnecting needs it only once
    req = fake_strava.requests[0]
    assert req.method == "POST" and req.url == strava.DEAUTHORIZE_URL


def test_disconnect_without_a_token_does_nothing_and_reaches_no_network(fake_strava):
    assert strava.disconnect() is False
    assert fake_strava.requests == []


def test_disconnect_removes_the_token_even_if_strava_cannot_be_reached(fake_strava, monkeypatch):
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600))

    def failing_request(method, url, **kw):
        raise strava.StravaError("made up: unreachable")

    monkeypatch.setattr(strava, "_request", failing_request)
    assert strava.disconnect() is True
    assert strava.load_token() is None


def test_a_token_due_soon_is_refreshed_before_it_is_used(fake_strava):
    strava.save_client(strava.Client("cid", "csecret"))
    strava.save_token(strava.Token("OLD-AT", "RT1", int(time.time()) + 10,  # due within the margin
                                   athlete_id=7, athlete_name="Ada"))
    fake_strava.queue(200, {"access_token": "NEW-AT", "refresh_token": "RT2",
                            "expires_at": int(time.time()) + 21600})
    token = strava._require_token()
    assert token.access_token == "NEW-AT"
    assert strava.load_token().access_token == "NEW-AT"
    # The athlete known from the sign-in is kept across a refresh (Strava's refresh answer
    # does not repeat it).
    assert strava.load_token().athlete_id == 7 and strava.load_token().athlete_name == "Ada"
    req = fake_strava.requests[0]
    assert req.method == "POST" and req.url == strava.TOKEN_URL
    assert b"grant_type=refresh_token" in fake_strava.body(0)
    assert b"RT1" in fake_strava.body(0)


def test_a_fresh_token_is_not_refreshed(fake_strava):
    strava.save_client(strava.Client("cid", "csecret"))
    strava.save_token(strava.Token("AT", "RT", int(time.time()) + 3600))
    token = strava._require_token()
    assert token.access_token == "AT"
    assert fake_strava.requests == []  # no network: nothing was due


def test_require_token_without_one_raises_not_connected():
    with pytest.raises(strava.NotConnected):
        strava._require_token()


def test_connect_runs_the_browser_and_the_local_callback_server(fake_strava):
    """connect(): a one-shot local HTTP server, the browser opened at its consent page (here
    `open_browser` makes the loopback request a real browser would, instead of opening one),
    and the code it receives exchanged for a token."""
    import urllib.request

    fake_strava.queue(200, {
        "access_token": "AT", "refresh_token": "RT", "expires_at": int(time.time()) + 21600,
        "athlete": {"id": 1, "firstname": "Grace", "lastname": "Hopper"},
    })
    opened = []

    def open_browser(url: str) -> bool:
        opened.append(url)
        redirect = parse_qs(urlsplit(url).query)["redirect_uri"][0]
        with urllib.request.urlopen(f"{redirect}?code=abc123", timeout=5) as resp:
            resp.read()
        return True

    status = strava.connect("cid", "csecret", open_browser=open_browser)
    assert status.connected and status.athlete_name == "Grace Hopper"
    assert len(opened) == 1 and "localhost%3A" in opened[0]
    assert strava.load_client() == strava.Client("cid", "csecret")


def test_connect_reuses_a_client_saved_before(fake_strava):
    import urllib.request

    strava.save_client(strava.Client("saved-id", "saved-secret"))
    fake_strava.queue(200, {"access_token": "AT", "refresh_token": "RT",
                           "expires_at": int(time.time()) + 21600})

    def open_browser(url: str) -> bool:
        redirect = parse_qs(urlsplit(url).query)["redirect_uri"][0]
        with urllib.request.urlopen(f"{redirect}?code=xyz", timeout=5) as resp:
            resp.read()
        return True

    strava.connect(open_browser=open_browser)
    assert b"saved-id" in fake_strava.body(0) and b"saved-secret" in fake_strava.body(0)


def test_connect_without_a_saved_or_given_client_raises():
    with pytest.raises(strava.NotConfigured):
        strava.connect(open_browser=lambda url: None)


def test_connect_reports_when_strava_does_not_redirect_back_in_time():
    with pytest.raises(strava.StravaError, match="did not answer in time"):
        strava.connect("cid", "csecret", open_browser=lambda url: None, timeout=0.2)
