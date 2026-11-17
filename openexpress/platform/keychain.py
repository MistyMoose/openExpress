"""macOS Keychain: generic-password items of one service, "openExpress", each keyed by its
own account name (here called `item`) — e.g. "connect_auth" for the Garmin OAuth1 token,
"consumer" for the application key (auth/store.py, which migrates the files of an earlier
version into the Keychain the first time each is read). The same two functions and the same
`item`/`service` shape can hold a Strava token later, under its own `item` name.

Two backends, tried in this order:
  - `_SecurityBackend`: the Security framework's modern item API (SecItemAdd,
    SecItemCopyMatching, SecItemUpdate, SecItemDelete) called through ctypes, with
    CoreFoundation strings and dictionaries built by hand (no PyObjC, which is not one of
    this program's dependencies).
  - `_SecurityCliBackend`: the `security` command line (`man security`), used only where the
    framework cannot be loaded through ctypes (not expected on an ordinary macOS install; a
    hardened or cut-down environment might refuse it). Slower, and the password must be text
    without a NUL byte, which is all this program ever stores here (JSON).

Tests never reach either: they inject a backend of their own (`use_backend`), so that nothing
of a test ever touches the real Keychain.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import subprocess
from abc import ABC, abstractmethod

log = logging.getLogger(__name__)

SERVICE = "openExpress"

# Security framework OSStatus codes this module acts on (SecBase.h); any other non-zero
# status becomes a KeychainError with its number.
_ERR_SUCCESS = 0
_ERR_ITEM_NOT_FOUND = -25300
_ERR_DUPLICATE_ITEM = -25299


class KeychainError(OSError):
    """A Keychain operation failed (an OSStatus that is not "not found", or the `security`
    command line's exit code). A subclass of OSError, as paths.write_private and os.link
    failures are: callers already fall back on OSError for "this cannot be done here"."""


class Backend(ABC):
    """get/set/delete of one generic-password item of SERVICE, keyed by `account`."""

    @abstractmethod
    def get(self, account: str) -> bytes | None:
        """The item's secret data, or None: there is no such item."""

    @abstractmethod
    def set(self, account: str, data: bytes) -> None:
        """The item is created, or its data replaced if it exists already."""

    @abstractmethod
    def delete(self, account: str) -> bool:
        """Whether an item was removed (False: there was none)."""


class _SecurityBackend(Backend):
    """Security.framework through ctypes: SecItemAdd/SecItemCopyMatching/SecItemUpdate/
    SecItemDelete, each called with a CFDictionary query built from CFStrings and, for
    `set`, a CFData of the secret. Raises OSError (not this module's KeychainError) at
    construction when the framework or a symbol it needs cannot be loaded, so that
    `default_backend` falls back to the `security` command line."""

    def __init__(self) -> None:
        try:
            self._cf = ctypes.CDLL(
                "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            self._sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        except OSError:
            raise
        self._bind()

    def _bind(self) -> None:
        cf, sec = self._cf, self._sec
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFDataCreate.restype = ctypes.c_void_p
        cf.CFDataCreate.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long]
        cf.CFDataGetLength.restype = ctypes.c_long
        cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
        cf.CFDataGetBytePtr.restype = ctypes.c_void_p
        cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
        cf.CFDictionaryCreate.restype = ctypes.c_void_p
        cf.CFDictionaryCreate.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        sec.SecItemAdd.restype = ctypes.c_int32
        sec.SecItemAdd.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        sec.SecItemCopyMatching.restype = ctypes.c_int32
        sec.SecItemCopyMatching.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        sec.SecItemUpdate.restype = ctypes.c_int32
        sec.SecItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        sec.SecItemDelete.restype = ctypes.c_int32
        sec.SecItemDelete.argtypes = [ctypes.c_void_p]
        # Dictionary/array callbacks and the typed constants of the Security framework: all
        # exported as plain symbols of the two frameworks. `byref` on the *CallBacks (structs,
        # not pointers) gives CFDictionaryCreate the address it wants, in place of a CFIndex
        # of our own; the *Sec* constants are themselves CFTypeRef values, used by their
        # ctypes object directly (its "value" is the pointer the framework reads).
        self._dict_key_cb = ctypes.c_void_p.in_dll(cf, "kCFTypeDictionaryKeyCallBacks")
        self._dict_value_cb = ctypes.c_void_p.in_dll(cf, "kCFTypeDictionaryValueCallBacks")
        self._k_class = ctypes.c_void_p.in_dll(sec, "kSecClass")
        self._k_class_generic = ctypes.c_void_p.in_dll(sec, "kSecClassGenericPassword")
        self._k_service = ctypes.c_void_p.in_dll(sec, "kSecAttrService")
        self._k_account = ctypes.c_void_p.in_dll(sec, "kSecAttrAccount")
        self._k_value_data = ctypes.c_void_p.in_dll(sec, "kSecValueData")
        self._k_return_data = ctypes.c_void_p.in_dll(sec, "kSecReturnData")
        self._k_match_limit = ctypes.c_void_p.in_dll(sec, "kSecMatchLimit")
        self._k_match_limit_one = ctypes.c_void_p.in_dll(sec, "kSecMatchLimitOne")
        self._k_true = ctypes.c_void_p.in_dll(cf, "kCFBooleanTrue")

    def _cfstr(self, s: str) -> ctypes.c_void_p:
        # kCFStringEncodingUTF8 == 0x08000100. Never released (CFRelease): SERVICE and an
        # account name, created a few times per run; the process ends long before that adds
        # up to anything worth the extra bookkeeping.
        return self._cf.CFStringCreateWithCString(None, s.encode("utf-8"), 0x08000100)

    def _cfdict(self, pairs: list[tuple[ctypes.c_void_p, ctypes.c_void_p]]) -> ctypes.c_void_p:
        keys = (ctypes.c_void_p * len(pairs))(*(k for k, _v in pairs))
        values = (ctypes.c_void_p * len(pairs))(*(v for _k, v in pairs))
        return self._cf.CFDictionaryCreate(
            None, keys, values, len(pairs),
            ctypes.byref(self._dict_key_cb), ctypes.byref(self._dict_value_cb))

    def _query(self, account: str) -> ctypes.c_void_p:
        return self._cfdict([
            (self._k_class, self._k_class_generic),
            (self._k_service, self._cfstr(SERVICE)),
            (self._k_account, self._cfstr(account)),
        ])

    def get(self, account: str) -> bytes | None:
        query = self._cfdict([
            (self._k_class, self._k_class_generic),
            (self._k_service, self._cfstr(SERVICE)),
            (self._k_account, self._cfstr(account)),
            (self._k_return_data, self._k_true),
            (self._k_match_limit, self._k_match_limit_one),
        ])
        result = ctypes.c_void_p()
        status = self._sec.SecItemCopyMatching(query, ctypes.byref(result))
        self._cf.CFRelease(query)
        if status == _ERR_ITEM_NOT_FOUND:
            return None
        if status != _ERR_SUCCESS:
            raise KeychainError(f"SecItemCopyMatching: OSStatus {status}")
        try:
            length = self._cf.CFDataGetLength(result)
            ptr = self._cf.CFDataGetBytePtr(result)
            return ctypes.string_at(ptr, length)
        finally:
            self._cf.CFRelease(result)

    def set(self, account: str, data: bytes) -> None:
        value = self._cf.CFDataCreate(None, data, len(data))
        try:
            add = self._cfdict([
                (self._k_class, self._k_class_generic),
                (self._k_service, self._cfstr(SERVICE)),
                (self._k_account, self._cfstr(account)),
                (self._k_value_data, value),
            ])
            status = self._sec.SecItemAdd(add, None)
            self._cf.CFRelease(add)
            if status == _ERR_DUPLICATE_ITEM:
                query = self._query(account)
                update = self._cfdict([(self._k_value_data, value)])
                status = self._sec.SecItemUpdate(query, update)
                self._cf.CFRelease(query)
                self._cf.CFRelease(update)
            if status != _ERR_SUCCESS:
                raise KeychainError(f"SecItemAdd/SecItemUpdate: OSStatus {status}")
        finally:
            self._cf.CFRelease(value)

    def delete(self, account: str) -> bool:
        query = self._query(account)
        status = self._sec.SecItemDelete(query)
        self._cf.CFRelease(query)
        if status == _ERR_ITEM_NOT_FOUND:
            return False
        if status != _ERR_SUCCESS:
            raise KeychainError(f"SecItemDelete: OSStatus {status}")
        return True


class _SecurityCliBackend(Backend):
    """The `security` command line, for the rare case the framework cannot be loaded through
    ctypes. Limited to text without a NUL byte (`-w` takes the password as one argument);
    this program only ever stores JSON here, which qualifies."""

    program = "/usr/bin/security"

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([self.program, *args], capture_output=True, text=True, check=False)

    def get(self, account: str) -> bytes | None:
        res = self._run("find-generic-password", "-s", SERVICE, "-a", account, "-w")
        if res.returncode != 0:
            return None  # not found, or no Keychain reachable (e.g. no login session)
        return res.stdout.rstrip("\n").encode()

    def set(self, account: str, data: bytes) -> None:
        if b"\x00" in data:
            raise KeychainError("the `security` command line cannot store a NUL byte")
        # -U: update in place if the item exists already, instead of refusing it as a duplicate.
        res = self._run("add-generic-password", "-s", SERVICE, "-a", account, "-w",
                        data.decode(), "-U")
        if res.returncode != 0:
            raise KeychainError(f"security add-generic-password: {res.stderr.strip()}")

    def delete(self, account: str) -> bool:
        res = self._run("delete-generic-password", "-s", SERVICE, "-a", account)
        return res.returncode == 0


_backend: Backend | None = None  # resolved lazily (default_backend), or injected for tests


def use_backend(backend: Backend | None) -> None:
    """Tests inject a fake backend here, so that nothing of a test ever touches the real
    Keychain; None goes back to the real one (resolved again, next time it is needed)."""
    global _backend
    _backend = backend


def default_backend() -> Backend:
    """The Security framework through ctypes, unless it could not be loaded (not expected on
    an ordinary install), when the `security` command line is used instead."""
    try:
        return _SecurityBackend()
    except OSError as e:
        log.info("keychain: Security.framework not usable through ctypes (%s); the `security` "
                "command line is used instead", e)
        return _SecurityCliBackend()


def _current() -> Backend:
    global _backend
    if _backend is None:
        _backend = default_backend()
    return _backend


def get(account: str) -> bytes | None:
    """The data of the item `account` of SERVICE, or None: there is no such item."""
    return _current().get(account)


def set(account: str, data: bytes) -> None:
    """The item `account` of SERVICE created, or its data replaced if it exists already."""
    _current().set(account, data)


def delete(account: str) -> bool:
    """Whether the item `account` of SERVICE was removed (False: there was none)."""
    return _current().delete(account)
