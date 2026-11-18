#!/bin/bash
# Builds macos/build/openExpress-for-Mac-<version>.pkg: "openExpress for Mac.app" with its engine
# inside, for
# /Applications on Apple silicon Macs with macOS 26 or later. Nothing of Homebrew or of a
# virtual environment is needed where it is installed. GPL-3.0-or-later.
#
#   macos/scripts/build-pkg.sh
#
# Two ways of signing, chosen by the environment:
#   - none of the variables below: every piece of code is signed ad hoc (codesign --sign -),
#     the .pkg is not signed. Gatekeeper refuses such a .pkg when it was downloaded; it is for
#     testing on this Mac and for CI artifacts.
#   - DEVELOPER_ID_APP ("Developer ID Application: Name (TEAMID)"), DEVELOPER_ID_INSTALLER
#     ("Developer ID Installer: Name (TEAMID)") and NOTARY_PROFILE (a keychain profile of
#     `xcrun notarytool store-credentials`): code signed with the hardened runtime and a secure
#     timestamp, the .pkg signed, notarized and stapled (docs/macos.md, "Signing").
#
# Other variables:
#   ADHOC_HARDENED=1   ad-hoc signatures with the hardened runtime and the distribution
#                      entitlements, to try them out without a Developer ID
#   LIBUSB_DYLIB=path  the libusb-1.0 to bundle (default: Homebrew's)
#   SKIP_VERIFY=1      do not run verify-pkg.sh at the end
#   KEYCHAIN=path      the keychain codesign and productbuild take the identities from (CI)
#   RELEASE=mac.1      the release of this edition on top of openExpress's version: in the
#                      package's file name (openExpress-for-Mac-0.11.0-mac.1.pkg) and the
#                      release's tag; the app's own version stays openExpress's (macOS takes
#                      only numbers there), its build number tells one build from another
#
# Build-time tools: Xcode 26 or later, xcodegen, GNU gettext (msgfmt), libusb (Homebrew),
# curl, and the network for the downloads below (cached in macos/build/cache).

set -euo pipefail

SCRIPTS=$(cd "$(dirname "$0")" && pwd -P)
MACOS=$(dirname "$SCRIPTS")
ROOT=$(dirname "$MACOS")
PACKAGING="$MACOS/packaging"
BUILD="$MACOS/build"
CACHE="$BUILD/cache"
WORK="$BUILD/pkg"
DERIVED="$BUILD/DerivedData"

# --- pinned downloads ------------------------------------------------------------------------
# CPython from python-build-standalone (https://github.com/astral-sh/python-build-standalone).
PY_MAJOR_MINOR=3.13
PY_VERSION=3.13.18
PY_RELEASE=20261110
PY_ASSET="cpython-${PY_VERSION}+${PY_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/${PY_ASSET//+/%2B}"
PY_SHA256=7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540
# The "full" archive of the same build, only for the licences of the libraries it links in
# (python/licenses), which the install_only archive leaves out.
PY_FULL_ASSET="cpython-${PY_VERSION}+${PY_RELEASE}-aarch64-apple-darwin-pgo+lto-full.tar.zst"
PY_FULL_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/${PY_FULL_ASSET//+/%2B}"
PY_FULL_SHA256=11c316dfa24e1184e91de3c1434ed1d3e986c30b2d7a0273257067efe611a677
# 7-Zip for macOS, Igor Pavlov's own build (linked from https://www.7-zip.org/download.html).
SEVENZIP_VERSION=26.06
SEVENZIP_ASSET=7z2606-mac.tar.xz
SEVENZIP_URL="https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION}/${SEVENZIP_ASSET}"
SEVENZIP_SHA256=b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd

MIN_MACOS=26.0
BUNDLE_ID=io.github.openexpress.mac
SOURCE_REPO=https://github.com/bruring/openExpress-mac
# The name people see, and the app's file name; the bundle identifier above stays.
APP_NAME="openExpress for Mac"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'build-pkg: %s\n' "$*" >&2; exit 1; }

# --- mode --------------------------------------------------------------------------------------
DISTRIBUTION=0
if [ -n "${DEVELOPER_ID_APP:-}${DEVELOPER_ID_INSTALLER:-}${NOTARY_PROFILE:-}" ]; then
    [ -n "${DEVELOPER_ID_APP:-}" ] && [ -n "${DEVELOPER_ID_INSTALLER:-}" ] && [ -n "${NOTARY_PROFILE:-}" ] \
        || die "distribution signing needs all of DEVELOPER_ID_APP, DEVELOPER_ID_INSTALLER and NOTARY_PROFILE"
    DISTRIBUTION=1
fi
KEYCHAIN_ARGS=()
[ -n "${KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")

# --- preflight ---------------------------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "builds only on macOS"
[ "$(uname -m)" = arm64 ] || die "builds only on Apple silicon (the engine's Python is arm64)"
for tool in xcodegen xcodebuild msgfmt curl shasum pkgbuild productbuild codesign otool \
            install_name_tool lipo vtool plutil git; do
    command -v "$tool" >/dev/null || die "$tool is missing"
done
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
if [ "${SDK_VERSION%%.*}" -lt 26 ]; then
    die "the macOS SDK is $SDK_VERSION; the app needs the macOS 26 SDK or later (Xcode 26+)"
fi
if [ -z "${LIBUSB_DYLIB:-}" ]; then
    command -v brew >/dev/null || die "set LIBUSB_DYLIB, or install libusb with Homebrew"
    LIBUSB_DYLIB="$(brew --prefix libusb)/lib/libusb-1.0.0.dylib"
fi
[ -f "$LIBUSB_DYLIB" ] || die "no libusb at $LIBUSB_DYLIB (brew install libusb)"
LIBUSB_DIR=$(cd "$(dirname "$LIBUSB_DYLIB")/.." && pwd -P)
LIBUSB_VERSION=$(sed -n 's/^Version: *//p' "$LIBUSB_DIR/lib/pkgconfig/libusb-1.0.pc" 2>/dev/null || true)

VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/openexpress/__init__.py")
[ -n "$VERSION" ] || die "no __version__ in openexpress/__init__.py"
grep -q "^version = \"$VERSION\"" "$ROOT/pyproject.toml" \
    || die "pyproject.toml's version differs from openexpress/__init__.py ($VERSION)"
BUILD_NUMBER=$(git -C "$ROOT" rev-list --count HEAD)
GIT_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
GIT_DESCRIBE=$(git -C "$ROOT" describe --tags --always --dirty)
PKG="$BUILD/openExpress-for-Mac-$VERSION${RELEASE:+-$RELEASE}.pkg"

say "$APP_NAME $VERSION (build $BUILD_NUMBER, $GIT_DESCRIBE), $([ $DISTRIBUTION = 1 ] && echo "Developer ID" || echo "ad-hoc") signing"
[[ "$GIT_DESCRIBE" == *-dirty ]] && echo "warning: the working tree has uncommitted changes; they are built in"

rm -rf "$WORK"
mkdir -p "$CACHE" "$WORK"

# --- downloads ---------------------------------------------------------------------------------
fetch() {  # url file sha256 → the file in the cache, its checksum checked
    local url=$1 file="$CACHE/$2" sha=$3
    if [ ! -f "$file" ]; then
        echo "downloading $url"
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    local got
    got=$(shasum -a 256 "$file" | cut -d' ' -f1)
    if [ "$got" != "$sha" ]; then
        rm -f "$file"
        die "$2: SHA-256 $got, expected $sha (removed from the cache)"
    fi
}
say "Downloads"
fetch "$PY_URL" "$PY_ASSET" "$PY_SHA256"
fetch "$PY_FULL_URL" "$PY_FULL_ASSET" "$PY_FULL_SHA256"
fetch "$SEVENZIP_URL" "$SEVENZIP_ASSET" "$SEVENZIP_SHA256"

# --- the app -----------------------------------------------------------------------------------
say "$APP_NAME.app (Release, arm64)"
(cd "$MACOS" && xcodegen generate --quiet)
xcodebuild -project "$MACOS/openExpress.xcodeproj" -scheme openExpress -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    -quiet build
STAGE="$WORK/root"
APP="$STAGE/$APP_NAME.app"
mkdir -p "$STAGE"
ditto "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP"
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
[ "$APP_VERSION" = "$VERSION" ] || die "the app's version is $APP_VERSION, the engine's $VERSION"

# --- the engine: Python ------------------------------------------------------------------------
say "Engine: CPython $PY_VERSION"
ENGINE="$APP/Contents/Resources/engine"
PY="$ENGINE/bin/python$PY_MAJOR_MINOR"
SITE="$ENGINE/lib/python$PY_MAJOR_MINOR/site-packages"
mkdir -p "$WORK/python" "$ENGINE"
tar -xzf "$CACHE/$PY_ASSET" -C "$WORK/python"
ditto "$WORK/python/python" "$ENGINE"
"$PY" -I -c 'import sys, ssl, ctypes; assert sys.version_info[:2] == (3, 13)'

# --- the engine: openexpress and its dependencies ----------------------------------------------
say "Engine: openexpress and its dependencies"
SRC="$WORK/src"
mkdir -p "$SRC"
# The files git knows (also changes not yet committed), never build output or local files.
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- \
        pyproject.toml README.md LICENSE openexpress po \
    | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -xf - -C "$SRC"
# The translations (.mo), made from po/ as for every build of openExpress.
(cd "$SRC" && env -u PYTHONPATH "$PY" -B -m openexpress.catalogs)
LANGUAGES=$(grep -cv '^[[:space:]]*\(#.*\)\{0,1\}$' "$SRC/po/LINGUAS")
MO_COUNT=$(find "$SRC/openexpress/locale" -name '*.mo' | wc -l | tr -d ' ')
[ "$MO_COUNT" -eq "$LANGUAGES" ] || die "$MO_COUNT catalogs made, $LANGUAGES languages in po/LINGUAS"

PIP=("$PY" -I -m pip --disable-pip-version-check --no-cache-dir --no-input)
"${PIP[@]}" download --quiet --require-hashes --only-binary=:all: --no-deps \
    -d "$CACHE/wheels" -r "$PACKAGING/engine-requirements.txt" -r "$PACKAGING/build-requirements.txt"
"${PIP[@]}" install --quiet --no-index --find-links "$CACHE/wheels" --require-hashes \
    --only-binary=:all: --no-deps --target "$WORK/buildtools" -r "$PACKAGING/build-requirements.txt"
PYTHONPATH="$WORK/buildtools" "$PY" -s -m pip --disable-pip-version-check --no-cache-dir wheel \
    --quiet --no-deps --no-build-isolation --no-index -w "$WORK/wheels" "$SRC"
"${PIP[@]}" install --quiet --no-index --find-links "$CACHE/wheels" --require-hashes \
    --only-binary=:all: --no-deps --no-compile -r "$PACKAGING/engine-requirements.txt"
"${PIP[@]}" install --quiet --no-index --no-deps --no-compile "$WORK"/wheels/openexpress-"$VERSION"-*.whl
"${PIP[@]}" uninstall --quiet --yes pip

# --- the engine: what it does not need ---------------------------------------------------------
say "Engine: trimming"
STDLIB="$ENGINE/lib/python$PY_MAJOR_MINOR"
# Only the Python itself stays in bin/ (pip's scripts have this machine's paths in them).
find "$ENGINE/bin" -mindepth 1 ! -name "python$PY_MAJOR_MINOR" -exec rm -rf {} +
rm -rf "$ENGINE/include" "$ENGINE/share" "$ENGINE/lib/pkgconfig" \
    "$ENGINE"/lib/libpython*.dylib "$ENGINE"/lib/libtcl* "$ENGINE"/lib/libtk* \
    "$ENGINE"/lib/tcl* "$ENGINE"/lib/tk* "$ENGINE"/lib/itcl* "$ENGINE"/lib/thread* \
    "$STDLIB"/{idlelib,tkinter,turtledemo,turtle.py,ensurepip,pydoc_data,test} \
    "$STDLIB"/lib-dynload/_tkinter.* "$STDLIB"/lib-dynload/_dbm.*
find "$SITE" -maxdepth 1 -name 'pip*' -exec rm -rf {} +
find "$ENGINE" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$SITE" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} +
find "$SITE" -name direct_url.json -delete  # the path of the wheel on this machine
# The python binary must not need the libpython we removed.
if [[ "$(otool -L "$PY")" == *libpython* ]]; then die "python$PY_MAJOR_MINOR links libpython"; fi
FOUND_MO=$(find "$SITE/openexpress/locale" -name '*.mo' | wc -l | tr -d ' ')
[ "$FOUND_MO" -eq "$LANGUAGES" ] || die "the installed package has $FOUND_MO catalogs, not $LANGUAGES"
[ -n "$(find "$SITE/openexpress/data" -name '*.svg' -print -quit)" ] || die "openexpress/data is missing"

# Bytecode, checked against nothing at run time: the sealed app cannot change under it, and the
# launcher's -B keeps Python from writing any into the app.
"$PY" -I -m compileall -q -j0 --invalidation-mode unchecked-hash -s "$ENGINE" -p "/Applications/$APP_NAME.app/Contents/Resources/engine" \
    -x '/(lib2to3|test)/' "$STDLIB" >/dev/null

# --- the engine: launcher and 7-Zip ------------------------------------------------------------
say "Engine: launcher, 7-Zip $SEVENZIP_VERSION"
install -m 0755 "$PACKAGING/openexpress-launcher.sh" "$ENGINE/bin/openexpress"
mkdir -p "$WORK/7zip"
tar -xJf "$CACHE/$SEVENZIP_ASSET" -C "$WORK/7zip"
if [ "$(lipo -archs "$WORK/7zip/7zz")" = arm64 ]; then
    install -m 0755 "$WORK/7zip/7zz" "$ENGINE/bin/7zz"
else
    lipo -thin arm64 "$WORK/7zip/7zz" -output "$ENGINE/bin/7zz"
    chmod 0755 "$ENGINE/bin/7zz"
fi
"$ENGINE/bin/7zz" i >/dev/null || die "7zz does not run"

# --- libusb ------------------------------------------------------------------------------------
say "libusb ${LIBUSB_VERSION:-?} into Contents/Frameworks"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
install -m 0644 "$LIBUSB_DYLIB" "$FRAMEWORKS/libusb-1.0.dylib"
chmod u+w "$FRAMEWORKS/libusb-1.0.dylib"
install_name_tool -id @rpath/libusb-1.0.dylib "$FRAMEWORKS/libusb-1.0.dylib" 2>&1 \
    | grep -v 'invalidate the code signature' >&2 || true

# --- licences ----------------------------------------------------------------------------------
say "Licences and the source offer"
RES="$APP/Contents/Resources"
install -m 0644 "$ROOT/LICENSE" "$RES/LICENSE.txt"
cat > "$RES/SOURCE.txt" <<EOF
openExpress for Mac $VERSION, the macOS edition of openExpress

openExpress for Mac is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of
the License, or (at your option) any later version (LICENSE.txt).

The complete corresponding source code of this build is at
    $SOURCE_REPO
    commit $GIT_COMMIT ($GIT_DESCRIBE), tag v$VERSION when released
The upstream project it is based on: https://github.com/TomaszBojanowski/openExpress

Written offer: for at least three years after you received this program, and for as long as
spare parts or support for it are offered, anyone who has received it may get the complete
corresponding source code, including that of the libraries listed in THIRD_PARTY_NOTICES.txt
(libusb and 7-Zip under the GNU LGPL), on a medium customarily used for software interchange,
for no more than the cost of physically performing the distribution, by opening an issue at
$SOURCE_REPO/issues
EOF
mkdir -p "$WORK/python-full"
tar -xf "$CACHE/$PY_FULL_ASSET" -C "$WORK/python-full" python/licenses
"$SCRIPTS/third-party-notices.sh" "$ENGINE" "$WORK/python-full/python/licenses" "$WORK/7zip" \
    "$LIBUSB_DIR" "${LIBUSB_VERSION:-}" "$PY_VERSION" "$PY_RELEASE" "$SEVENZIP_VERSION" \
    > "$RES/THIRD_PARTY_NOTICES.txt"

# --- every piece of machine code ---------------------------------------------------------------
. "$SCRIPTS/macho.sh"
say "Checking the machine code"
check_macho "$APP" "$MIN_MACOS" || die "machine code refers to the build machine or needs a newer macOS"
macho_files "$APP" | sed "s|^$APP/|  |"

# --- signing -----------------------------------------------------------------------------------
xattr -cr "$APP"
APP_ENTITLEMENTS="$MACOS/openExpress/openExpress.entitlements"
ENGINE_ENTITLEMENTS="$PACKAGING/engine.entitlements"
if [ $DISTRIBUTION = 1 ]; then
    IDENTITY=$DEVELOPER_ID_APP
    SIGN_OPTS=(--options runtime --timestamp)
elif [ "${ADHOC_HARDENED:-}" = 1 ]; then
    IDENTITY=-
    SIGN_OPTS=(--options runtime --timestamp=none)
else
    IDENTITY=-
    SIGN_OPTS=(--timestamp=none)
fi
say "Signing ($IDENTITY${SIGN_OPTS[*]/#/ })"
sign() { codesign --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "${SIGN_OPTS[@]}" "$@"; }
MAIN_EXE="$APP/Contents/MacOS/openExpress"
while IFS= read -r f; do
    case "$f" in
        "$MAIN_EXE") continue ;;  # signed with the app below
        "$PY") sign --identifier "$BUNDLE_ID.engine.python" --entitlements "$ENGINE_ENTITLEMENTS" "$f" ;;
        "$ENGINE/bin/7zz") sign --identifier "$BUNDLE_ID.engine.7zz" "$f" ;;
        *) sign "$f" ;;
    esac
done < <(macho_files "$APP")
sign --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ $DISTRIBUTION = 1 ] || [ "${ADHOC_HARDENED:-}" = 1 ]; then
    for f in "$APP" "$PY" "$ENGINE/bin/7zz" "$FRAMEWORKS/libusb-1.0.dylib"; do
        info=$(codesign -dv "$f" 2>&1)
        [[ "$info" == *"flags="*"runtime"* ]] || die "no hardened runtime: $f"
    done
    signed=$(codesign -d --entitlements - --xml "$PY" 2>/dev/null | plutil -convert xml1 -o - -)
    [ "$signed" = "$(plutil -convert xml1 -o - "$ENGINE_ENTITLEMENTS")" ] \
        || die "the engine's Python lacks its entitlements"
    echo "hardened runtime on every piece of code; the engine's Python has its entitlements"
fi

# --- the package -------------------------------------------------------------------------------
say "Package"
COMPONENT_PLIST="$WORK/component.plist"
pkgbuild --analyze --root "$STAGE" "$COMPONENT_PLIST" >/dev/null
# Never "relocated" onto a copy of the app elsewhere (a development build): always /Applications.
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"
plutil -replace 0.BundleOverwriteAction -string upgrade "$COMPONENT_PLIST"
mkdir -p "$WORK/packages" "$WORK/resources"
COMPONENT=openExpress-component.pkg
pkgbuild --root "$STAGE" --component-plist "$COMPONENT_PLIST" --identifier "$BUNDLE_ID" \
    --version "$VERSION" --install-location /Applications --min-os-version "$MIN_MACOS" \
    --ownership recommended --quiet "$WORK/packages/$COMPONENT"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMPONENT@/$COMPONENT/g" \
    "$PACKAGING/distribution.xml.in" > "$WORK/distribution.xml"
install -m 0644 "$PACKAGING/welcome.html" "$WORK/resources/welcome.html"
install -m 0644 "$ROOT/LICENSE" "$WORK/resources/LICENSE.txt"
PRODUCT_SIGN=()
[ $DISTRIBUTION = 1 ] && PRODUCT_SIGN=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"})
rm -f "$PKG"
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
    --package-path "$WORK/packages" --version "$VERSION" ${PRODUCT_SIGN[@]+"${PRODUCT_SIGN[@]}"} --quiet "$PKG"

if [ $DISTRIBUTION = 1 ]; then
    say "Notarization"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait \
        ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --output-format plain | tee "$WORK/notary.txt"
    grep -q 'status: Accepted' "$WORK/notary.txt" \
        || die "notarization was not accepted (xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
    spctl --assess -vv --type install "$PKG"
fi

say "Done"
printf '%s  %s\n' "$(du -sh "$PKG" | cut -f1)" "$PKG"
printf '%s  %s\n' "$(du -sh "$APP" | cut -f1)" "$APP_NAME.app (installed size)"

if [ "${SKIP_VERIFY:-}" != 1 ]; then
    "$SCRIPTS/verify-pkg.sh" "$PKG"
fi
