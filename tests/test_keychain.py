"""macOS Keychain storage (openexpress/platform/keychain.py): one get/set/delete of a
generic-password item of SERVICE, by account name, through a backend that tests can swap
(use_backend) so that nothing here ever reaches the real Keychain; the framework (ctypes)
backend only when it cannot be loaded.

tests/conftest.py's `no_real_keychain` (autouse) already keeps every other test from reaching
the real Keychain by accident; the tests here install backends of their own on top of it."""

import pytest
from fakes import FakeKeychain

from openexpress.platform import keychain

# --- get/set/delete go through whatever backend is installed -----------------------------


def test_get_is_none_for_an_item_that_was_never_set():
    keychain.use_backend(FakeKeychain())
    assert keychain.get("connect_auth") is None


def test_set_then_get_returns_the_same_bytes():
    keychain.use_backend(FakeKeychain())
    keychain.set("connect_auth", b"token-bytes-made-up")
    assert keychain.get("connect_auth") == b"token-bytes-made-up"


def test_set_on_an_existing_item_replaces_it_not_duplicates_it():
    fake = FakeKeychain()
    keychain.use_backend(fake)
    keychain.set("connect_auth", b"first")
    keychain.set("connect_auth", b"second")
    assert keychain.get("connect_auth") == b"second"
    assert fake.items == {"connect_auth": b"second"}


def test_delete_says_whether_something_was_removed():
    keychain.use_backend(FakeKeychain())
    assert keychain.delete("connect_auth") is False  # nothing to remove
    keychain.set("connect_auth", b"x")
    assert keychain.delete("connect_auth") is True
    assert keychain.get("connect_auth") is None
    assert keychain.delete("connect_auth") is False  # already gone


def test_each_account_of_the_service_is_independent():
    """connect_auth and consumer (and a Strava token later) never collide."""
    keychain.use_backend(FakeKeychain())
    keychain.set("connect_auth", b"a")
    keychain.set("consumer", b"b")
    assert (keychain.get("connect_auth"), keychain.get("consumer")) == (b"a", b"b")
    keychain.delete("connect_auth")
    assert keychain.get("consumer") == b"b"


def test_use_backend_none_resolves_the_default_again_lazily(monkeypatch):
    resolved = []

    def fake_default():
        resolved.append(1)
        return FakeKeychain()

    monkeypatch.setattr(keychain, "default_backend", fake_default)
    keychain.use_backend(None)
    keychain.get("x")  # the default is resolved once, the first time it is needed
    keychain.get("x")  # and kept after that, not resolved again
    assert resolved == [1]


# --- default_backend: the framework, or OSError -----------------------------------------------


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


def test_without_the_framework_each_call_raises_oserror_for_the_caller_s_file(monkeypatch):
    def refuses(self):
        raise OSError("made up: dlopen of Security.framework failed")

    monkeypatch.setattr(keychain._SecurityBackend, "__init__", refuses)
    keychain.use_backend(None)
    with pytest.raises(OSError):
        keychain.get("connect_auth")
