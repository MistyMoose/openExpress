"""A fake HTTP layer for openexpress.strava's tests: strava.py talks to Strava only through
a requests.Session, so patching requests.adapters.HTTPAdapter.send (as test_client_headers.py
does for Garmin) keeps every test off the network. tests/conftest.py's `no_network` fixture
would catch a real attempt anyway; this module lets a test script exact answers and inspect
exactly what was sent, one queued answer consumed per request, in order."""

from __future__ import annotations

import io
import json

import pytest
import requests


class FakeStrava:
    def __init__(self):
        self.requests: list[requests.PreparedRequest] = []
        self._queue: list[tuple[int, dict, dict]] = []

    def queue(self, status: int, body: dict, headers: dict | None = None) -> None:
        self._queue.append((status, body, headers or {}))

    def send(self, _adapter, request, **_kw) -> requests.Response:
        self.requests.append(request)
        if not self._queue:
            raise AssertionError(f"strava: no answer queued for {request.method} {request.url}")
        status, body, headers = self._queue.pop(0)
        resp = requests.Response()
        resp.request, resp.url, resp.status_code = request, request.url, status
        resp.headers["Content-Type"] = "application/json"
        resp.headers.update(headers)
        resp.raw = io.BytesIO(json.dumps(body).encode())
        return resp

    def body(self, index: int = -1) -> bytes:
        """The raw body of one of the requests sent, for a plain substring check (e.g. that
        external_id or a bearer token is in it)."""
        raw = self.requests[index].body
        return raw if isinstance(raw, bytes) else str(raw).encode()


@pytest.fixture
def fake_strava(monkeypatch) -> FakeStrava:
    fake = FakeStrava()
    monkeypatch.setattr(requests.adapters.HTTPAdapter, "send",
                        lambda self, request, **kw: fake.send(self, request, **kw))
    return fake
