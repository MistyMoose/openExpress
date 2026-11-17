"""Garmin Connect token storage: on Linux a file with 0600 permissions; on macOS the
Keychain (platform/keychain.py), where a file of an earlier version (or one a failed Keychain
write left behind) is migrated in on first read and removed once that succeeds. read_secret,
save_secret and delete_secret are generic (an `item` name and a fallback `path`): a Strava
token can be kept the same way later, under an item of its own.
"""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import asdict, dataclass, field
from pathlib import Path

from openexpress import answers, paths
from openexpress.errors import UserFacingError
from openexpress.i18n import _

log = logging.getLogger(__name__)


class NotLoggedIn(UserFacingError):
    pass


def read_secret(item: str, path: Path) -> str | None:
    """The text saved for `item`: on macOS, from the Keychain, migrating `path` into it the
    first time it is read there and removing the file once that succeeds (the file is kept,
    and read from, if the Keychain cannot be reached); on Linux, `path` alone. None:
    saved nowhere."""
    from openexpress import platform

    if platform.is_mac():
        from openexpress.platform import keychain

        try:
            data = keychain.get(item)
        except OSError as e:
            log.info("keychain: %s not reachable (%s); the file is used instead", item, e)
            data = None
        if data is not None:
            return data.decode("utf-8")
        if path.exists():
            text = path.read_text()
            _migrate_to_keychain(item, path, text)
            return text
        return None
    return path.read_text() if path.exists() else None


def _migrate_to_keychain(item: str, path: Path, text: str) -> None:
    """`text` (just read from `path`, an earlier version's file) saved into the Keychain;
    `path` removed only once that succeeds, so a Keychain that cannot be reached yet leaves
    the file as the next read's fallback too."""
    from openexpress.platform import keychain

    try:
        keychain.set(item, text.encode("utf-8"))
    except OSError as e:
        log.info("keychain: %s could not be moved there yet (%s); its file is kept", item, e)
        return
    path.unlink(missing_ok=True)
    log.info("keychain: %s moved from its file into the Keychain", item)


def save_secret(item: str, text: str, path: Path) -> None:
    """`text` saved for `item`: on macOS in the Keychain, removing `path` if a file is still
    there from before (an earlier version, or a Keychain write that failed last time); on
    Linux, or on macOS too if the Keychain cannot be reached, the 0600 file `path`."""
    from openexpress import platform

    if platform.is_mac():
        from openexpress.platform import keychain

        try:
            keychain.set(item, text.encode("utf-8"))
        except OSError as e:
            log.warning("keychain: %s could not be saved (%s); kept as a file instead", item, e)
            paths.write_private(path, text)
            return
        if path.exists():
            path.unlink()
        return
    paths.write_private(path, text)


def delete_secret(item: str, path: Path) -> bool:
    """Whether `item` (the Keychain, on macOS) or its file was removed (either, or both, as
    a migration half done might leave one of each)."""
    removed = False
    from openexpress import platform

    if platform.is_mac():
        from openexpress.platform import keychain

        try:
            removed = keychain.delete(item)
        except OSError as e:
            log.warning("keychain: %s could not be removed (%s)", item, e)
    if path.exists():
        path.unlink()
        removed = True
    return removed


@dataclass
class ConnectAuth:
    # Out of repr(): an object that ends up in a log line or an error shows no secret.
    token: str = field(repr=False)
    token_secret: str = field(repr=False)
    environment: str = "production"
    account: dict = field(default_factory=dict)

    @property
    def display(self) -> str:
        """The account's name as the window shows it: its user name, else its e-mail
        address, whole."""
        return self._name(lambda name: name)

    @property
    def masked_display(self) -> str:
        """The account's name as the command line shows it, masked (masked()): its output is
        pasted into reports."""
        return self._name(masked)

    def _name(self, shown) -> str:
        """shown(the account's user name, else its e-mail address); a word of its own when it
        has neither."""
        a = self.account
        name = a.get("username") or a.get("emailaddress")
        # TRANSLATORS: shown in place of the signed-in Garmin account's name when it has no user
        # name and no e-mail address
        return shown(name) if name else _("(unknown account)")


def masked(name: str) -> str:
    """An account's name for what is pasted into reports (the command line's output): a user
    name as its first and last letters, "t…b" (only the first of two letters or fewer); an
    e-mail address as the first letters of its two halves, "t…@e…"."""
    local, at, domain = name.partition("@")
    if at:
        return f"{local[:1]}…@{domain[:1]}…"
    return f"{name[:1]}…{name[-1:]}" if len(name) > 2 else f"{name[:1]}…"


ITEM = "connect_auth"  # the Keychain item's name on macOS; the file's name everywhere


def _path():
    return paths.config_dir() / f"{ITEM}.json"


def stamp() -> str | None:
    """The version of the login saved, nothing of what is in it; None: none saved. On Linux,
    when its file was written and its size; on macOS, once it is in the Keychain (nothing
    there says when it was written), a hash of it instead, which changes just the same when
    the login does. What was read of the account with one login holds only while that login
    stays saved (tile_facts)."""
    from openexpress import platform

    if platform.is_mac():
        from openexpress.platform import keychain

        try:
            data = keychain.get(ITEM)
        except OSError:
            data = None
        if data is not None:
            return f"keychain-{len(data)}-{hashlib.sha256(data).hexdigest()[:16]}"
    try:
        st = _path().stat()
    except OSError:
        return None
    return f"{st.st_mtime_ns}-{st.st_size}"


def load() -> ConnectAuth:
    text = read_secret(ITEM, _path())
    if text is None:
        raise NotLoggedIn(_("Not signed in. Run: openexpress login"))
    try:
        data = json.loads(text)
        auth = ConnectAuth(**data)
    except (ValueError, TypeError) as e:
        raise NotLoggedIn(_("The saved sign-in is damaged; sign in again.")) from e
    if not (isinstance(auth.token, str) and isinstance(auth.token_secret, str)
            and isinstance(auth.account, dict)):
        raise NotLoggedIn(_("The saved sign-in is damaged; sign in again."))
    return auth


def save(auth: ConnectAuth) -> None:
    save_secret(ITEM, json.dumps(asdict(auth), indent=2), _path())
    _forget_the_account()


def delete() -> bool:
    removed = delete_secret(ITEM, _path())
    _forget_the_account()
    return removed


def _forget_the_account() -> None:
    """Another login (or none): nothing kept of the account's answers holds (answers)."""
    answers.ANSWERS.forget(answers.ACCOUNT_KINDS)
