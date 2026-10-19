#!/usr/bin/env bash
# Runs tests/ps/test-*.ps1 — tests for the Windows server's PowerShell (Server/*.ps1) — and exits
# non-zero if any fail.
#
# Uses pwsh from PATH if there is one (Windows with PowerShell 7, or Linux with it installed).
# Otherwise, on Linux, fetches the official portable PowerShell build into
# ~/.local/share/alttabsucks/pwsh (override with $ALTTABSUCKS_PWSH_DIR) on first run — a plain
# tarball, no install step. Same idea as dev-scripts/run-ahk-tests.sh.
#
# Only covers logic that doesn't need Windows itself (text parsing/rewriting); the HTTP listener,
# processes and registry still have to be checked on Windows.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_ROOT/tests/ps"
PWSH_VERSION="7.6.7"

if command -v pwsh >/dev/null; then
    PWSH="pwsh"
else
    case "$(uname -s)" in
        Linux) ;;
        *) echo "pwsh not found — install PowerShell 7 (winget install Microsoft.PowerShell)." >&2; exit 1 ;;
    esac
    PWSH_DIR="${ALTTABSUCKS_PWSH_DIR:-$HOME/.local/share/alttabsucks/pwsh}"
    PWSH="$PWSH_DIR/pwsh"
    if [ ! -x "$PWSH" ]; then
        echo "First run: fetching portable PowerShell $PWSH_VERSION into $PWSH_DIR ..."
        mkdir -p "$PWSH_DIR"
        dl_dir="$(mktemp -d)"
        trap 'rm -rf "$dl_dir"' EXIT
        curl -fsSL --max-time 300 -o "$dl_dir/pwsh.tar.gz" \
            "https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/powershell-$PWSH_VERSION-linux-x64.tar.gz"
        tar -xzf "$dl_dir/pwsh.tar.gz" -C "$PWSH_DIR"
        chmod +x "$PWSH"
    fi
fi

shopt -s nullglob
tests=("$TEST_DIR"/test-*.ps1)
[ ${#tests[@]} -gt 0 ] || { echo "No tests found in $TEST_DIR" >&2; exit 1; }

overall=0
for test in "${tests[@]}"; do
    echo "=== $(basename "$test") ==="
    set +e
    POWERSHELL_TELEMETRY_OPTOUT=1 "$PWSH" -NoLogo -NoProfile -NonInteractive -File "$test"
    code=$?
    set -e
    [ "$code" -eq 0 ] || { echo "-> $(basename "$test"): exit $code"; overall=1; }
    echo
done
exit "$overall"
