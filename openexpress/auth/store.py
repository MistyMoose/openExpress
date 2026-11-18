"""Garmin Connect token storage: where platform.secrets() keeps secrets (a file with 0600
permissions; the Keychain on macOS). read_secret, save_secret and delete_secret keep any other
secret the same way, as the application key and the Strava token are.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field

from openexpress import answers, platform
from openexpress.errors import UserFacingError
from openexpress.i18n import _


class NotLoggedIn(UserFacingError):
    pass


def read_secret(item: str) -> str | None:
    """The text saved for `item`; None: none saved."""
    data = platform.secrets().get(item)
    return None if data is None else data.decode("utf-8")


def save_secret(item: str, text: str) -> None:
    platform.secrets().set(item, text.encode("utf-8"))


def delete_secret(item: str) -> bool:
    """Whether a secret saved for `item` was removed."""
    return platform.secrets().delete(item)


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


ITEM = "connect_auth"  # the secret's name (its file: connect_auth.json)


def stamp() -> str | None:
    """The version of the login saved, nothing of what is in it; None: none saved. What was
    read of the account with one login holds only while that login stays saved (tile_facts)."""
    return platform.secrets().stamp(ITEM)


def load() -> ConnectAuth:
    text = read_secret(ITEM)
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
    save_secret(ITEM, json.dumps(asdict(auth), indent=2))
    _forget_the_account()


def delete() -> bool:
    removed = delete_secret(ITEM)
    _forget_the_account()
    return removed


def _forget_the_account() -> None:
    """Another login (or none): nothing kept of the account's answers holds (answers)."""
    answers.ANSWERS.forget(answers.ACCOUNT_KINDS)
