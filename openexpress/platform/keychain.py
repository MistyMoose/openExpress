"""macOS Keychain: generic-password items of one service, "openExpress", each keyed by its
own account name (here called `item`) — e.g. "connect_auth" for the Garmin OAuth1 token,
"consumer" for the application key (auth/store.py, which migrates the files of an earlier
version into the Keychain the first time each is read), and the Strava token (strava.py).

The Security framework's item API (SecItemAdd, SecItemCopyMatching, SecItemUpdate,
SecItemDelete) is called through ctypes, with CoreFoundation strings and dictionaries built by
hand (no PyObjC). Where the framework cannot be loaded, each call raises OSError and the
callers keep their file instead, as on Linux. Tests inject a backend of their own
(`use_backend`), so that nothing of a test ever touches the real Keychain.
"""

from __future__ import annotations

import ctypes
from abc import ABC, abstractmethod


SERVICE = "openExpress"

# Security framework OSStatus codes this module acts on (SecBase.h); any other non-zero
# status becomes a KeychainError with its number.
_ERR_SUCCESS = 0
_ERR_ITEM_NOT_FOUND = -25300
_ERR_DUPLICATE_ITEM = -25299


class KeychainError(OSError):
    """A Keychain operation failed (an OSStatus that is not "not found"). A subclass of OSError,
    as paths.write_private and os.link failures are: callers already fall back on OSError for
    "this cannot be done here"."""


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
    `set`, a CFData of the secret. Raises OSError at construction when the framework or a
    symbol it needs cannot be loaded."""

    def __init__(self) -> None:
        self._cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self._sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
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

    def _query(self, account: str, *extra: tuple[ctypes.c_void_p, ctypes.c_void_p]
               ) -> ctypes.c_void_p:
        """The item `account` of SERVICE, with the `extra` (key, value) pairs."""
        return self._cfdict([
            (self._k_class, self._k_class_generic),
            (self._k_service, self._cfstr(SERVICE)),
            (self._k_account, self._cfstr(account)),
            *extra,
        ])

    def get(self, account: str) -> bytes | None:
        query = self._query(account, (self._k_return_data, self._k_true),
                            (self._k_match_limit, self._k_match_limit_one))
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
            add = self._query(account, (self._k_value_data, value))
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


_backend: Backend | None = None  # resolved lazily (default_backend), or injected for tests


def use_backend(backend: Backend | None) -> None:
    """Tests inject a fake backend here, so that nothing of a test ever touches the real
    Keychain; None goes back to the real one (resolved again, next time it is needed)."""
    global _backend
    _backend = backend


def default_backend() -> Backend:
    """The Security framework through ctypes; OSError where it cannot be loaded."""
    return _SecurityBackend()


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
