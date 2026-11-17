#!/bin/bash
# Writes THIRD_PARTY_NOTICES.txt of openExpress.app to stdout: what is bundled besides
# openExpress itself, under which licence, where its source is, and each licence's text, taken
# from the very files that are bundled. Called by build-pkg.sh. GPL-3.0-or-later.
#
#   third-party-notices.sh ENGINE PY_LICENSES SEVENZIP_DIR LIBUSB_PREFIX LIBUSB_VERSION \
#                          PY_VERSION PY_RELEASE SEVENZIP_VERSION
#
# PY_LICENSES: python/licenses of python-build-standalone's "full" archive of the same build.

set -euo pipefail
ENGINE=$1 PY_LICENSES=$2 SEVENZIP_DIR=$3 LIBUSB_PREFIX=$4 LIBUSB_VERSION=$5 PY_VERSION=$6 \
    PY_RELEASE=$7 SEVENZIP_VERSION=$8
# The libraries python-build-standalone links into the parts of Python the app keeps (its
# PYTHON.json); Tcl/Tk and Berkeley DB went with tkinter and _dbm, and zlib, ncurses and
# libedit are macOS's own (/usr/lib).
PY_LIBRARIES="openssl-3 sqlite libffi bzip2 liblzma mpdecimal expat libuuid"
PY="$ENGINE/bin/python${PY_VERSION%.*}"
SITE="$ENGINE/lib/python${PY_VERSION%.*}/site-packages"

rule() { printf '\n%s\n%s\n\n' "================================================================================" "$1"; }
licence_files() {  # the licence files of an installed distribution (its .dist-info)
    local info
    info=$(find "$SITE" -maxdepth 1 -iname "$(tr - _ <<<"$1")-*.dist-info" | head -1)
    [ -n "$info" ] || { echo "no $1 in site-packages" >&2; exit 1; }
    find "$info" -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) | sort
}
dist_version() { find "$SITE" -maxdepth 1 -iname "$(tr - _ <<<"$1")-*.dist-info" | head -1 | sed 's/.*-\([^-]*\)\.dist-info$/\1/'; }

VERSIONS=$("$PY" -I -B -c '
import ssl, sqlite3, decimal
print(ssl.OPENSSL_VERSION.split()[1], sqlite3.sqlite_version, decimal.__libmpdec_version__)')
read -r OPENSSL_VERSION SQLITE_VERSION MPDEC_VERSION <<<"$VERSIONS"

cat <<EOF
openExpress for macOS: third-party software
==========================================

openExpress itself is under the GNU General Public License v3.0 or later (LICENSE.txt); where
its source is: SOURCE.txt. openExpress.app also contains the programs and libraries below, each
under its own licence, whose full text follows its entry. None of them was modified, except
that the machine code was re-signed (and libusb's install name set) for this app.

Inside Contents/Resources/engine (the engine):

- CPython $PY_VERSION: PSF License Version 2. https://www.python.org/
  The build of python-build-standalone release $PY_RELEASE
  (https://github.com/astral-sh/python-build-standalone), which has these libraries linked in:
  OpenSSL $OPENSSL_VERSION (Apache License 2.0), SQLite $SQLITE_VERSION (public domain),
  libffi (MIT), bzip2 (bzip2 licence), liblzma of XZ Utils (0BSD), mpdecimal $MPDEC_VERSION
  (BSD 2-Clause), Expat (MIT), libuuid (BSD 3-Clause).
  Source: https://www.python.org/downloads/source/ and the release above.
- requests $(dist_version requests): Apache License 2.0. https://github.com/psf/requests
- urllib3 $(dist_version urllib3): MIT License. https://github.com/urllib3/urllib3
- certifi $(dist_version certifi): Mozilla Public License 2.0. https://github.com/certifi/python-certifi
- idna $(dist_version idna): BSD 3-Clause. https://github.com/kjd/idna
- charset-normalizer $(dist_version charset-normalizer): MIT License. https://github.com/jawah/charset_normalizer
- mutagen $(dist_version mutagen): GPL-2.0-or-later. https://github.com/quodlibet/mutagen
- 7-Zip $SEVENZIP_VERSION (bin/7zz): GNU LGPL 2.1 or later, with the unRAR licence restriction;
  BSD 3-Clause and 2-Clause for some code. https://www.7-zip.org/
  Source: https://github.com/ip7z/7zip/releases/tag/$SEVENZIP_VERSION
  The unRAR restriction: the unRAR code may not be used to re-create the RAR compression
  algorithm, which is proprietary (its full wording is in 7-Zip's licence below).

Inside Contents/Frameworks:

- libusb ${LIBUSB_VERSION:-1.0}: GNU LGPL 2.1 or later. https://libusb.info/
  Source: https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2
  A separate library the engine loads at run time (Contents/Frameworks/libusb-1.0.dylib):
  you may replace it with a version of your own (the app's signature then has to be renewed,
  e.g. codesign --force --deep --sign - openExpress.app). The written offer in SOURCE.txt
  covers its source too.
EOF

rule "CPython $PY_VERSION: LICENSE"
cat "$PY_LICENSES/LICENSE.cpython.txt"
for lib in $PY_LIBRARIES; do
    rule "$lib (in CPython's build): LICENSE.$lib.txt"
    cat "$PY_LICENSES/LICENSE.$lib.txt"
done
for dist in requests urllib3 certifi idna charset-normalizer mutagen; do
    while IFS= read -r f; do
        rule "$dist $(dist_version "$dist"): $(basename "$f")"
        cat "$f"
    done < <(licence_files "$dist")
done
rule "7-Zip $SEVENZIP_VERSION: License.txt"
cat "$SEVENZIP_DIR/License.txt"
rule "libusb ${LIBUSB_VERSION}: COPYING (GNU Lesser General Public License 2.1)"
cat "$LIBUSB_PREFIX/COPYING"
