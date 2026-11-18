#!/bin/sh
# openExpress's engine inside "openExpress for Mac.app": Contents/Resources/engine/bin/openexpress.
# Installed by macos/scripts/build-pkg.sh. GPL-3.0-or-later.
#
# Runs the Python bundled next to it with `-m openexpress`, isolated from the user's
# environment: -I (no PYTHON* variables, no user site-packages, no current folder on the
# path), -B (never writes .pyc files into the signed app), -u (unbuffered: the app reads the
# engine line by line), -X utf8 (UTF-8 on the pipes whatever the locale; LANG still chooses the
# language). Every path is found from this script's own place, so the app may be anywhere.

self=$(/bin/realpath "$0") || exit 127
engine=$(cd "$(dirname "$self")/.." && pwd -P) || exit 127
contents=$(cd "$engine/../.." && pwd -P) || exit 127

# The libusb the app carries (Contents/Frameworks), never one installed elsewhere.
if [ -f "$contents/Frameworks/libusb-1.0.dylib" ]; then
    OPENEXPRESS_LIBUSB="$contents/Frameworks/libusb-1.0.dylib"
    export OPENEXPRESS_LIBUSB
fi

# The 7-Zip the app carries (7zz, for `setup --from-installer`), never one installed elsewhere.
if [ -x "$engine/bin/7zz" ]; then
    OPENEXPRESS_7Z="$engine/bin/7zz"
    export OPENEXPRESS_7Z
fi

# Nothing from outside decides which libraries the bundled programs load.
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH \
      DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_VERSIONED_LIBRARY_PATH \
      PYTHONHOME PYTHONPATH PYTHONSTARTUP

exec "$engine/bin/python3.13" -I -B -u -X utf8 -m openexpress "$@"
