# The checks of the app's machine code, sourced by build-pkg.sh and verify-pkg.sh.
# GPL-3.0-or-later.

macho_files() {  # every Mach-O file under $1, deepest first (signing goes inside out)
    find "$1" -type f -print0 | while IFS= read -r -d '' f; do
        case "$(head -c 4 "$f" | xxd -p)" in
            cffaedfe|cefaedfe|cafebabe|bebafeca) printf '%s\n' "$f" ;;
        esac
    done | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-
}
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }
# What machine code may refer to: the system's libraries, and the bundle's own (@rpath and the
# like). Anything of the build machine (Homebrew, a venv, a home folder, python-build-standalone's
# /install prefix) would be missing where the app is installed.
FORBIDDEN='/opt/homebrew|/usr/local|/Users/|/\.?venv|/install/|/tmp/|/private/|/Applications/Xcode'
ALLOWED='^(/usr/lib/|/System/Library/|@rpath/|@executable_path/|@loader_path/)'
check_macho() {  # $1: a bundle, $2: the oldest macOS it runs on; fails on any reference
                 # outside ALLOWED, code that is not arm64, or a minos later than $2
    local bad=0 f refs minos
    while IFS= read -r f; do
        # otool -L: the install name (of a dylib) and every library it loads; LC_RPATH entries.
        refs=$( { otool -L "$f" | tail -n +2 | awk '{ print $1 }'
                  otool -l "$f" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'; } )
        if grep -Eq "$FORBIDDEN" <<<"$refs" || grep -Evq "$ALLOWED" <<<"$refs"; then
            echo "outside the bundle or the system, in ${f#"$1"/}:" >&2
            grep -E "$FORBIDDEN" <<<"$refs" >&2 || true
            grep -Ev "$ALLOWED" <<<"$refs" >&2 || true
            bad=1
        fi
        [[ " $(lipo -archs "$f") " == *" arm64 "* ]] || { echo "not arm64: $f" >&2; bad=1; }
        minos=$(vtool -show-build "$f" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')
        if [ -n "$minos" ] && ! version_le "$minos" "$2"; then
            echo "needs macOS $minos (later than $2): $f" >&2; bad=1
        fi
    done < <(macho_files "$1")
    return $bad
}
