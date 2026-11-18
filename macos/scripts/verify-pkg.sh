#!/bin/bash
# Checks an openExpress for Mac .pkg without installing it: its signature, its installer rules, and the
# app taken out of it (pkgutil --expand-full into macos/build/verify/) — its code signature, its
# machine code, and its engine run as the app runs it, with no Homebrew on PATH. Read-only for
# devices and the account (verify_engine.py). GPL-3.0-or-later.
#
#   macos/scripts/verify-pkg.sh [macos/build/openExpress-for-Mac-<version>.pkg]
#
#   VERIFY_ACCOUNT=1  also account.status, which reads the Keychain: macOS may ask whether
#                     this build's Python may read items another build saved (answer Deny or
#                     Allow; the check waits up to 60 s)
#   VERIFY_LAUNCH=1   also start the app taken out of the package for a few seconds and check
#                     that it runs its own engine (needs a logged-in desktop; not in CI)

set -euo pipefail
SCRIPTS=$(cd "$(dirname "$0")" && pwd -P)
MACOS=$(dirname "$SCRIPTS")
ROOT=$(dirname "$MACOS")
VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/openexpress/__init__.py")
APP_NAME="openExpress for Mac"
PKG=${1:-"$MACOS/build/openExpress-for-Mac-$VERSION.pkg"}
OUT="$MACOS/build/verify"

say() { printf '\n--> %s\n' "$*"; }
die() { printf 'verify-pkg: FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$PKG" ] || die "no package at $PKG"

say "Package signature"
if pkgutil --check-signature "$PKG"; then :; else
    echo "(not signed: an ad-hoc build; Gatekeeper refuses it when it was downloaded)"
fi

say "Expanding into ${OUT#"$ROOT"/}"
rm -rf "$OUT"
mkdir -p "$OUT"
pkgutil --expand-full "$PKG" "$OUT/expanded"
APP="$OUT/expanded/openExpress-component.pkg/Payload/$APP_NAME.app"
[ -d "$APP" ] || die "no $APP_NAME.app in the package"
PLIST_NAME=$(plutil -extract CFBundleName raw "$APP/Contents/Info.plist")
[ "$PLIST_NAME" = "$APP_NAME" ] || die "the app is called $PLIST_NAME, not $APP_NAME"
[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = io.github.openexpress.mac ] \
    || die "the bundle identifier changed (settings and Keychain items would not carry over)"
DIST="$OUT/expanded/Distribution"
grep -q 'hostArchitectures="arm64"' "$DIST" || die "the installer is not arm64-only"
grep -q "compareVersions(system.version.ProductVersion, '26.0')" "$DIST" || die "no macOS 26 check"
grep -q 'enable_anywhere="false"' "$DIST" || die "the installer may install elsewhere"
PKGINFO="$OUT/expanded/openExpress-component.pkg/PackageInfo"
grep -q "<title>$APP_NAME</title>" "$DIST" || die "the installer's title is not $APP_NAME"
grep -q 'install-location="/Applications"' "$PKGINFO" || die "not installed into /Applications"
grep -q 'relocatable="false"' "$PKGINFO" || die "the component is relocatable"
for f in welcome.html LICENSE.txt; do
    [ -f "$OUT/expanded/Resources/$f" ] || die "the installer lacks $f"
done
echo "Distribution: arm64 only, macOS 26 check, /Applications, not relocatable, welcome and licence"

say "The app"
codesign --verify --deep --strict --verbose=2 "$APP"
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
ENGINE="$APP/Contents/Resources/engine"
for f in "$ENGINE/bin/openexpress" "$ENGINE/bin/python3.13" "$ENGINE/bin/7zz" \
         "$APP/Contents/Frameworks/libusb-1.0.dylib" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" \
         "$APP/Contents/Resources/LICENSE.txt" "$APP/Contents/Resources/SOURCE.txt"; do
    [ -e "$f" ] || die "missing: ${f#"$APP"/}"
done
echo "$APP_NAME.app $APP_VERSION, macOS $MIN_OS or later, $(du -sh "$APP" | cut -f1)"

say "Machine code: only the system's and the app's own libraries, arm64, macOS $MIN_OS"
. "$SCRIPTS/macho.sh"
check_macho "$APP" "$MIN_OS" || die "machine code refers to paths outside the app and the system, or needs a newer macOS"
COUNT=0
while IFS= read -r f; do
    COUNT=$((COUNT + 1))
    printf '  %-58s %s\n' "${f#"$APP"/}" "$(codesign -dv "$f" 2>&1 | sed -n 's/^Signature=//p;s/^CodeDirectory.*flags=\([^ ]*\).*/flags=\1/p' | tr '\n' ' ')"
done < <(macho_files "$APP")
echo "$COUNT Mach-O files, all clean"

say "The engine with a scrubbed environment (no Homebrew on PATH)"
SCRUB=(env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8)
ENGINE_VERSION=$("${SCRUB[@]}" "$ENGINE/bin/openexpress" --version)
echo "$ENGINE_VERSION"
[ "$ENGINE_VERSION" = "openexpress $APP_VERSION" ] || die "engine $ENGINE_VERSION, app $APP_VERSION"
ACCOUNT=()
[ "${VERIFY_ACCOUNT:-}" = 1 ] && ACCOUNT=(--account)
"${SCRUB[@]}" "$ENGINE/bin/python3.13" -I -B "$SCRIPTS/verify_engine.py" "$APP" ${ACCOUNT[@]+"${ACCOUNT[@]}"}

say "libusb as loaded, without OPENEXPRESS_LIBUSB (the lookup in Contents/Frameworks)"
# The image dyld mapped libusb_init from (dladdr), and, where the runtime lets DYLD_* through
# (not hardened), dyld's own list. Python directly: macOS drops DYLD_* on the way through
# /bin/sh (the launcher).
LIBUSB="$APP/Contents/Frameworks/libusb-1.0.dylib"
FROM=$("${SCRUB[@]}" "$ENGINE/bin/python3.13" -I -B -c '
import ctypes
from openexpress.device import ptp
lib = ptp.load_libusb()
class DlInfo(ctypes.Structure):
    _fields_ = [("fname", ctypes.c_char_p), ("fbase", ctypes.c_void_p),
                ("sname", ctypes.c_char_p), ("saddr", ctypes.c_void_p)]
info = DlInfo()
ctypes.CDLL(None).dladdr(ctypes.cast(lib.libusb_init, ctypes.c_void_p), ctypes.byref(info))
print(info.fname.decode())')
echo "libusb_init is in $FROM"
[ "$FROM" = "$LIBUSB" ] || die "libusb was loaded from $FROM"
if [[ "$(codesign -dv "$ENGINE/bin/python3.13" 2>&1)" != *runtime* ]]; then
    LOADED=$("${SCRUB[@]}" DYLD_PRINT_LIBRARIES=1 "$ENGINE/bin/python3.13" -I -B -c \
        'from openexpress.device import ptp; ptp.load_libusb()' 2>&1 | grep -E 'libusb|homebrew' || true)
    echo "$LOADED"
    [ "$(sed 's/^dyld\[[0-9]*\]: <[^>]*> //' <<<"$LOADED")" = "$LIBUSB" ] \
        || die "dyld did not load the bundled libusb (only)"
fi

say "7-Zip: the bundled 7zz is the one used, even with Homebrew's 7z on PATH"
mkdir -p "$OUT/7z"
"${SCRUB[@]}" PATH="$ENGINE/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    "$ENGINE/bin/python3.13" -I -B - "$OUT/7z" "$ENGINE/bin/7zz" <<'EOF'
import sys, zipfile
from pathlib import Path
from openexpress import installer
out, expected = Path(sys.argv[1]), sys.argv[2]
found = installer._seven_zip()
assert found == expected, f"7z tool found: {found}, expected {expected}"
with zipfile.ZipFile(out / "test.zip", "w") as z:
    z.writestr("hello.txt", "openExpress")
installer._run_7z(out / "test.zip", out / "x")
assert (out / "x" / "hello.txt").read_text() == "openExpress"
print(f"{found}: found first and unpacks an archive")
EOF

if [ "${VERIFY_LAUNCH:-}" = 1 ]; then
    say "The app, started for a few seconds with its own engine"
    pgrep -fl "$APP_NAME.app/Contents/MacOS/openExpress" && die "another $APP_NAME is running; quit it first"
    LOG="$OUT/app-launch.log"
    log stream --level info --style compact \
        --predicate 'subsystem == "io.github.openexpress.mac" AND category == "engine"' > "$LOG" 2>&1 &
    LOGGER=$!
    sleep 2
    # Its own engine (no OPENEXPRESS_ENGINE), and no automatic backup and sync for this run
    # (the argument domain: the setting itself is not changed).
    env -u OPENEXPRESS_ENGINE "$APP/Contents/MacOS/openExpress" -automaticBackupAndSync NO \
        > "$OUT/app-stdout.log" 2> "$OUT/app-stderr.log" &
    APP_PID=$!
    sleep 10
    CHILD=$(pgrep -P "$APP_PID" || true)
    CHILD_CMD=$([ -n "$CHILD" ] && ps -ww -o command= -p "$CHILD" || true)
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$APP_PID" 2>/dev/null || true
    sleep 1
    kill "$LOGGER" 2>/dev/null || true
    grep 'engine started' "$LOG" || true
    echo "engine process: ${CHILD_CMD:-none}"
    grep -q "engine started: $ENGINE/bin/openexpress" "$LOG" || die "the app did not log starting its own engine"
    [[ "$CHILD_CMD" == "$ENGINE/bin/python3.13 "* ]] || die "the app's engine process is not the bundled Python"
    # The app was stopped with SIGTERM, not quit (no shutdown request): the engine ends at the
    # end of its stdin once its running requests are done. One still waiting (e.g. for a
    # Keychain prompt: VERIFY_ACCOUNT) keeps it; it is stopped here.
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$ENGINE/bin/python3.13" >/dev/null || break; sleep 0.5; done
    if pgrep -f "$ENGINE/bin/python3.13" >/dev/null; then
        echo "warning: the engine was still waiting for a request 5 s after the app; stopped"
        pkill -f "$ENGINE/bin/python3.13" || true
    fi
    echo "the app ran its own engine and both have quit"
fi

say "All checks passed: $PKG ($(du -sh "$PKG" | cut -f1))"
