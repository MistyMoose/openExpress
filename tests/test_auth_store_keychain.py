"""On macOS, auth.store (the Garmin OAuth1 token) and settings (the application key) keep
their secret in the Keychain instead of a file; a file left by an earlier version (or by a
Keychain write that failed) is migrated in the first time it is read, and removed once the
Keychain write of it succeeds. Linux (and macOS when the Keychain cannot be reached) keeps
the 0600 file, as it always did (test_auth.py).

Every test here installs its own fake Keychain backend (openexpress.platform.keychain,
fakes.FakeKeychain) and forces platform.is_mac() True, so that the macOS path runs and is
checked whatever system this suite itself runs on; tests/conftest.py's `no_real_keychain`
(autouse) means nothing in this file could reach the real Keychain even without that."""

import json

import pytest
from fakes import FakeKeychain

from openexpress import paths, settings
from openexpress.auth import store
from openexpress.auth.store import ConnectAuth
from openexpress.platform import keychain
from openexpress.settings import Consumer


class _Unreachable(keychain.Backend):
    """Every call fails, as a Keychain that cannot be unlocked or reached would."""

    def get(self, account: str) -> bytes | None:
        raise OSError("made up: the Keychain could not be reached")

    def set(self, account: str, data: bytes) -> None:
        raise OSError("made up: the Keychain could not be reached")

    def delete(self, account: str) -> bool:
        raise OSError("made up: the Keychain could not be reached")


@pytest.fixture
def fake_keychain():
    fake = FakeKeychain()
    keychain.use_backend(fake)
    return fake


def login_file():
    return paths.config_dir() / "connect_auth.json"


def consumer_file():
    return settings.consumer_path()


# --- auth.store.ConnectAuth: save / load / delete / stamp through the Keychain -------------


def test_save_then_load_round_trips_through_the_keychain_and_writes_no_file(
        as_mac, fake_keychain):
    auth = ConnectAuth("tok-1", "sec-1", "production", {"username": "someone"})
    store.save(auth)
    assert not login_file().exists()
    assert fake_keychain.items.keys() == {"connect_auth"}
    back = store.load()
    assert (back.token, back.token_secret, back.account) == (auth.token, auth.token_secret,
                                                               auth.account)


def test_a_file_from_an_earlier_version_is_migrated_in_on_first_read_and_then_removed(
        as_mac, fake_keychain):
    auth = ConnectAuth("tok-2", "sec-2", "production", {"username": "migrated"})
    paths.write_private(login_file(), json.dumps(auth.__dict__))
    assert login_file().exists() and not fake_keychain.items
    back = store.load()  # the file is read once, then moved into the Keychain
    assert back.token == "tok-2"
    assert not login_file().exists()
    assert fake_keychain.items.keys() == {"connect_auth"}
    # Read again: now straight from the Keychain, the file gone already.
    assert store.load().token == "tok-2"


def test_migration_leaves_the_file_alone_when_the_keychain_cannot_be_reached(as_mac):
    keychain.use_backend(_Unreachable())
    auth = ConnectAuth("tok-3", "sec-3", "production", {})
    paths.write_private(login_file(), json.dumps(auth.__dict__))
    back = store.load()  # still readable: the file is the fallback
    assert back.token == "tok-3"
    assert login_file().exists()  # not removed: it could not be saved to the Keychain


def test_save_falls_back_to_the_file_when_the_keychain_cannot_be_reached(as_mac):
    keychain.use_backend(_Unreachable())
    auth = ConnectAuth("tok-4", "sec-4", "production", {})
    store.save(auth)
    assert login_file().exists()
    assert store.load().token == "tok-4"


def test_a_leftover_file_is_removed_once_a_later_save_reaches_the_keychain(
        as_mac, fake_keychain):
    keychain.use_backend(_Unreachable())
    store.save(ConnectAuth("tok-5", "sec-5", "production", {}))
    assert login_file().exists()  # saved as a file: the Keychain was unreachable that time
    keychain.use_backend(fake_keychain)
    store.save(ConnectAuth("tok-6", "sec-6", "production", {}))
    assert not login_file().exists()  # this save reached the Keychain: the old file is gone
    assert store.load().token == "tok-6"


def test_delete_removes_the_keychain_item_and_any_file_left_from_a_migration(
        as_mac, fake_keychain):
    fake_keychain.items["connect_auth"] = b'{"token": "x", "token_secret": "y"}'
    paths.write_private(login_file(), "leftover")  # as a half-finished migration might leave
    assert store.delete() is True
    assert not fake_keychain.items and not login_file().exists()
    assert store.delete() is False  # nothing left either way


def test_stamp_is_none_until_something_is_saved_and_changes_when_it_does(
        as_mac, fake_keychain):
    assert store.stamp() is None
    store.save(ConnectAuth("tok-7", "sec-7", "production", {}))
    first = store.stamp()
    assert first is not None
    store.save(ConnectAuth("tok-7", "sec-7", "production", {"username": "changed"}))
    assert store.stamp() != first
    store.delete()
    assert store.stamp() is None


def test_linux_keeps_the_file_alone_the_keychain_never_asked(as_linux, fake_keychain):
    """platform.is_mac() forced False, whatever system this suite runs on: save/load/delete
    use the file alone, as test_auth.py checks in more detail for the ordinary Linux path."""
    store.save(ConnectAuth("tok-8", "sec-8", "production", {}))
    assert login_file().exists()
    assert not fake_keychain.items  # the Keychain was never asked
    assert store.load().token == "tok-8"


# --- settings.Consumer (the application key): the very same mechanism, a different item ----


def test_the_consumer_key_is_saved_to_and_loaded_from_the_keychain(as_mac, fake_keychain):
    settings.save_consumer(Consumer("key-made-up", "secret-made-up", "salt-made-up"))
    assert not consumer_file().exists()
    assert fake_keychain.items.keys() == {"consumer"}
    c = settings.load_consumer()
    assert (c.key, c.secret, c.url_salt) == ("key-made-up", "secret-made-up", "salt-made-up")


def test_an_existing_consumer_file_is_migrated_into_the_keychain(as_mac, fake_keychain):
    paths.write_private(consumer_file(),
                        json.dumps({"key": "k", "secret": "s", "url_salt": None}))
    c = settings.load_consumer()
    assert c.key == "k"
    assert not consumer_file().exists()
    assert fake_keychain.items.keys() == {"consumer"}


def test_connect_auth_and_consumer_are_independent_keychain_items(as_mac, fake_keychain):
    store.save(ConnectAuth("tok-9", "sec-9", "production", {}))
    settings.save_consumer(Consumer("key-9", "secret-9"))
    assert fake_keychain.items.keys() == {"connect_auth", "consumer"}
    store.delete()
    assert fake_keychain.items.keys() == {"consumer"}
    assert settings.has_consumer()
