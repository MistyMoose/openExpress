"""macOS Keychain storage (openexpress/platform/keychain.py): one get/set/delete of a
generic-password item of SERVICE, by account name, through a backend that tests can swap
(use_backend) so that nothing here ever reaches the real Keychain. The `security` command
line backend is exercised through a made-up subprocess.run that never starts a real process,
and the framework (ctypes) backend only through its fallback: this module does not call its
real Security.framework bindings at all, by design.

tests/conftest.py's `no_real_keychain` (autouse) already keeps every other test from reaching
the real Keychain by accident; the tests here install backends of their own on top of it."""

import pytest

from openexpress.platform import keychain


class FakeBackend(keychain.Backend):
    """An in-memory stand-in for the real Keychain: {account: data}, one SERVICE implied."""

    def __init__(self):
        self.items: dict[str, bytes] = {}

    def get(self, account: str) -> bytes | None:
        return self.items.get(account)

    def set(self, account: str, data: bytes) -> None:
        self.items[account] = data

    def delete(self, account: str) -> bool:
        return self.items.pop(account, None) is not None


@pytest.fixture(autouse=True)
def restore_backend():
    """Every test here installs its own backend; none of it must leak into the next test."""
    yield
    keychain.use_backend(None)


# --- get/set/delete go through whatever backend is installed -----------------------------


def test_get_is_none_for_an_item_that_was_never_set():
    keychain.use_backend(FakeBackend())
    assert keychain.get("connect_auth") is None


def test_set_then_get_returns_the_same_bytes():
    keychain.use_backend(FakeBackend())
    keychain.set("connect_auth", b"token-bytes-made-up")
    assert keychain.get("connect_auth") == b"token-bytes-made-up"


def test_set_on_an_existing_item_replaces_it_not_duplicates_it():
    fake = FakeBackend()
    keychain.use_backend(fake)
    keychain.set("connect_auth", b"first")
    keychain.set("connect_auth", b"second")
    assert keychain.get("connect_auth") == b"second"
    assert fake.items == {"connect_auth": b"second"}


def test_delete_says_whether_something_was_removed():
    keychain.use_backend(FakeBackend())
    assert keychain.delete("connect_auth") is False  # nothing to remove
    keychain.set("connect_auth", b"x")
    assert keychain.delete("connect_auth") is True
    assert keychain.get("connect_auth") is None
    assert keychain.delete("connect_auth") is False  # already gone


def test_each_account_of_the_service_is_independent():
    """connect_auth and consumer (and a Strava token later) never collide."""
    keychain.use_backend(FakeBackend())
    keychain.set("connect_auth", b"a")
    keychain.set("consumer", b"b")
    assert (keychain.get("connect_auth"), keychain.get("consumer")) == (b"a", b"b")
    keychain.delete("connect_auth")
    assert keychain.get("consumer") == b"b"


def test_use_backend_none_resolves_the_default_again_lazily(monkeypatch):
    resolved = []

    def fake_default():
        resolved.append(1)
        return FakeBackend()

    monkeypatch.setattr(keychain, "default_backend", fake_default)
    keychain.use_backend(None)
    keychain.get("x")  # the default is resolved once, the first time it is needed
    keychain.get("x")  # and kept after that, not resolved again
    assert resolved == [1]


# --- the `security` command line backend: a made-up subprocess.run, never a real process ----


class _Completed:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def test_the_cli_backend_asks_security_to_find_the_item(monkeypatch):
    calls = []

    def fake_run(args, **kw):
        calls.append(args)
        return _Completed(0, stdout="the-password\n")

    monkeypatch.setattr(keychain.subprocess, "run", fake_run)
    backend = keychain._SecurityCliBackend()
    assert backend.get("connect_auth") == b"the-password"
    assert calls == [[backend.program, "find-generic-password", "-s", keychain.SERVICE,
                      "-a", "connect_auth", "-w"]]


def test_the_cli_backend_get_is_none_when_security_does_not_find_it(monkeypatch):
    monkeypatch.setattr(keychain.subprocess, "run", lambda *a, **k: _Completed(44))
    backend = keychain._SecurityCliBackend()
    assert backend.get("connect_auth") is None


def test_the_cli_backend_set_adds_with_update_in_place(monkeypatch):
    calls = []
    monkeypatch.setattr(keychain.subprocess, "run",
                        lambda args, **kw: calls.append(args) or _Completed(0))
    backend = keychain._SecurityCliBackend()
    backend.set("connect_auth", b"hello")
    assert calls == [[backend.program, "add-generic-password", "-s", keychain.SERVICE,
                      "-a", "connect_auth", "-w", "hello", "-U"]]


def test_the_cli_backend_delete_asks_security_and_reports_success(monkeypatch):
    calls = []
    monkeypatch.setattr(keychain.subprocess, "run",
                        lambda args, **kw: calls.append(args) or _Completed(0))
    backend = keychain._SecurityCliBackend()
    assert backend.delete("connect_auth") is True
    assert calls == [[backend.program, "delete-generic-password", "-s", keychain.SERVICE,
                      "-a", "connect_auth"]]


def test_the_cli_backend_delete_is_false_when_security_finds_nothing(monkeypatch):
    monkeypatch.setattr(keychain.subprocess, "run", lambda *a, **k: _Completed(44))
    assert keychain._SecurityCliBackend().delete("connect_auth") is False


def test_the_cli_backend_raises_when_security_refuses_to_set(monkeypatch):
    monkeypatch.setattr(keychain.subprocess, "run",
                        lambda *a, **k: _Completed(1, stderr="made up: refused"))
    with pytest.raises(keychain.KeychainError):
        keychain._SecurityCliBackend().set("connect_auth", b"hello")


def test_the_cli_backend_refuses_a_nul_byte_without_calling_security(monkeypatch):
    calls = []
    monkeypatch.setattr(keychain.subprocess, "run", lambda *a, **kw: calls.append(1))
    with pytest.raises(keychain.KeychainError):
        keychain._SecurityCliBackend().set("connect_auth", b"a\x00b")
    assert calls == []  # security was never run: the data is refused first


# --- default_backend: the framework first, the command line only if that fails --------------


def test_default_backend_uses_the_framework_backend_when_it_can_be_loaded(monkeypatch):
    class _AlwaysWorks(keychain.Backend):
        def get(self, account):
            return None

        def set(self, account, data):
            pass

        def delete(self, account):
            return False

    monkeypatch.setattr(keychain, "_SecurityBackend", _AlwaysWorks)
    assert isinstance(keychain.default_backend(), _AlwaysWorks)


def test_default_backend_falls_back_to_the_cli_backend_when_the_framework_cannot_load(
        monkeypatch):
    def refuses(self):
        raise OSError("made up: dlopen of Security.framework failed")

    monkeypatch.setattr(keychain._SecurityBackend, "__init__", refuses)
    assert isinstance(keychain.default_backend(), keychain._SecurityCliBackend)
