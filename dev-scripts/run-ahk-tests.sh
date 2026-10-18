#!/usr/bin/env bash
# Runs tests/ahk/test-*.ahk — the AutoHotkey v2 side's tests — and exits non-zero if any fail.
#
# On Windows (Git Bash): uses AutoHotkey64.exe from its normal install location, or $AHK_EXE.
# On Linux: runs them under Wine, using a portable AutoHotkey v2 download kept in its own
# dedicated Wine prefix (default ~/.local/share/alttabsucks/ahk-wine, override with
# $ALTTABSUCKS_AHK_WINEPREFIX) — fetched automatically on first run. Deliberately the portable
# zip, not the installer: the installer is itself a compiled AHK script whose UIAccess step
# creates a self-signed certificate through Crypt32\CryptEncodeObject, which Wine doesn't
# implement — confirmed live, it pops an AutoHotkey error dialog on the real desktop mid-install.
# The portable zip needs no install step at all.
#
# A dedicated prefix also means this never touches any other Wine prefix on the machine (it gets
# its own wineserver) — e.g. a game server already running under Wine is left alone.
#
# What this can and can't verify: the tests only exercise pure decision logic (plain data in,
# decision out). Anything that needs a real Windows shell — Shell.Application COM, real Explorer
# windows/tabs, WinActivate — isn't available under Wine and still has to be checked on Windows.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_ROOT/tests/ahk"
AHK_ZIP_URL="https://www.autohotkey.com/download/ahk-v2.zip"
TIMEOUT_SECS=60

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
    *)                    PLATFORM=wine ;;
esac

if [ "$PLATFORM" = wine ]; then
    command -v wine >/dev/null || { echo "wine not found — install it (e.g. 'sudo pacman -S wine') to run AHK tests on Linux." >&2; exit 1; }
    export WINEPREFIX="${ALTTABSUCKS_AHK_WINEPREFIX:-$HOME/.local/share/alttabsucks/ahk-wine}"
    export WINEDEBUG=-all
    AHK_DIR="$WINEPREFIX/ahk-portable"
    AHK_EXE="${AHK_EXE:-$AHK_DIR/AutoHotkey64.exe}"

    if [ ! -f "$AHK_EXE" ]; then
        echo "First run: fetching portable AutoHotkey v2 into $AHK_DIR ..."
        mkdir -p "$AHK_DIR"
        dl_dir="$(mktemp -d)"
        trap 'rm -rf "$dl_dir"' EXIT
        curl -fsSL --max-time 120 -o "$dl_dir/ahk-v2.zip" "$AHK_ZIP_URL"
        # bsdtar (libarchive, on Arch) and unzip both work; prefer whichever exists.
        if command -v unzip >/dev/null; then
            unzip -q -o "$dl_dir/ahk-v2.zip" -d "$AHK_DIR"
        else
            bsdtar -xf "$dl_dir/ahk-v2.zip" -C "$AHK_DIR"
        fi
        [ -f "$AHK_EXE" ] || { echo "AutoHotkey64.exe not found in the downloaded zip." >&2; exit 1; }
        echo "Initializing Wine prefix $WINEPREFIX (one-time) ..."
        wineboot --init >/dev/null 2>&1 || true
    fi
    run_ahk() { timeout "$TIMEOUT_SECS" wine "$AHK_EXE" /ErrorStdOut "$(winepath -w "$1")" "$(winepath -w "$2")" 2>"$3"; }
else
    AHK_EXE="${AHK_EXE:-/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe}"
    [ -f "$AHK_EXE" ] || { echo "AutoHotkey64.exe not found at '$AHK_EXE' — set AHK_EXE." >&2; exit 1; }
    run_ahk() { timeout "$TIMEOUT_SECS" "$AHK_EXE" /ErrorStdOut "$(cygpath -w "$1")" "$(cygpath -w "$2")" 2>"$3"; }
fi

shopt -s nullglob
tests=("$TEST_DIR"/test-*.ahk)
[ ${#tests[@]} -gt 0 ] || { echo "No tests found in $TEST_DIR" >&2; exit 1; }

work_dir="$(mktemp -d)"
overall=0
for test in "${tests[@]}"; do
    name="$(basename "$test")"
    results="$work_dir/${name%.ahk}.results.txt"
    errlog="$work_dir/${name%.ahk}.stderr.txt"
    echo "=== $name ==="
    set +e
    run_ahk "$test" "$results" "$errlog"
    code=$?
    set -e
    if [ -s "$results" ]; then
        cat "$results"
    fi
    # Load-time errors (syntax, missing #Include) go to stderr via /ErrorStdOut and never reach
    # the results file; filter out Wine/Mesa noise so only the real error shows.
    if [ "$code" -ne 0 ] && [ -s "$errlog" ]; then
        grep -vE "MESA|pci id for fd|dri2 screen" "$errlog" || true
    fi
    case "$code" in
        0)   ;;
        1)   echo "-> $name: failing assertions" ;;
        2)   echo "-> $name: runtime error (see ERROR above)" ;;
        124) echo "-> $name: timed out after ${TIMEOUT_SECS}s" ;;
        *)   echo "-> $name: exited $code (likely a load-time error, see above)" ;;
    esac
    [ "$code" -eq 0 ] || overall=1
    echo
done
rm -rf "$work_dir"
exit "$overall"
