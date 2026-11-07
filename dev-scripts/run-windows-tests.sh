#!/usr/bin/env bash
# Runs the test suites on real Windows, in the Windows 11 test VM, from Linux:
#   1. tests/ahk (dev-scripts/run-ahk-tests.sh, natively)
#   2. tests/ps under PowerShell 7 (what the server runs on)
#   3. tests/windows/e2e.ps1 - a fresh install with its first-run dialogs, starter hotkeys, the
#      Hotkeys UI (API and the page itself in Edge) with save -> reload and broken edit -> no
#      reload, the hotkeys.json fold-in, tab focus / profile cycling / split / merge through the
#      extension in Edge, launching Edge when it's closed, folder hotkeys vs real Explorer, the
#      startup manager, uninstall
#   4. tests/windows/logon.ps1 - install, switch UAC on, reboot, and check the startup manager at
#      the real logon (AltTabSucks elevated without a prompt, the apps it starts not elevated)
#
# Usage: dev-scripts/run-windows-tests.sh [--no-reset] [--keep-vm]
#   By default the VM is rolled back to its "browser" snapshot first, so the e2e tests always see
#   a fresh install; --no-reset reuses the running VM and skips e2e (unit suites only).
#   The VM is shut down when the run ends; --keep-vm leaves it running (for debugging a failure).
#
# Needs the test VM (one-time setup: tests/windows/README.md), driven by dev-scripts/windows-vm.sh
# (override with $ALTTABSUCKS_WIN_VM). The working tree (tracked + untracked, minus gitignored
# files) is copied to C:\alttabsucks in the VM, so uncommitted changes are tested.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${ALTTABSUCKS_WIN_VM:-$REPO_ROOT/dev-scripts/windows-vm.sh}"
[ -x "$VM" ] || { echo "VM helper not found at $VM (set ALTTABSUCKS_WIN_VM)." >&2; exit 1; }

reset=1 keep=0
for arg in "$@"; do
    case "$arg" in
        --no-reset) reset=0 ;;
        --keep-vm) keep=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
# The VM stays off when nothing is being tested: shut it down however the run ends.
[ "$keep" = 1 ] || trap '"$VM" stop >/dev/null 2>&1 || true' EXIT

if [ "$reset" = 1 ]; then "$VM" reset; else "$VM" start; fi
# The guest's resolution follows the QEMU window on the host, which can come up small; some tests
# (two Edge windows side by side) need a wide screen.
"$VM" resolution >/dev/null
"$VM" sync "$REPO_ROOT"

overall=0
run() {  # run <label> <powershell command line in the VM>
    echo
    echo "=== $1 ==="
    if ! "$VM" ssh "cd C:\\alttabsucks; $2; exit \$LASTEXITCODE"; then
        echo "-> $1: FAILED"
        overall=1
    fi
}

run "AHK tests" '& "C:\Program Files\Git\bin\bash.exe" dev-scripts/run-ahk-tests.sh 2>&1 | Select-String -NotMatch "^PASS"'
run "PowerShell tests (PowerShell 7)" 'Get-ChildItem tests\ps\test-*.ps1 | % { pwsh -NoProfile -ExecutionPolicy Bypass -File $_.FullName | Select-String -NotMatch "^PASS"; if ($LASTEXITCODE) { $global:LASTEXITCODE = 1 } }'
if [ "$reset" = 1 ]; then
    run "End-to-end (tests/windows/e2e.ps1)" 'pwsh -NoProfile -ExecutionPolicy Bypass -File tests\windows\e2e.ps1'
    run "Logon, before the reboot (tests/windows/logon.ps1)" 'pwsh -NoProfile -ExecutionPolicy Bypass -File tests\windows\logon.ps1 -Phase prepare'
    "$VM" reboot
    "$VM" resolution >/dev/null
    run "Logon (tests/windows/logon.ps1)" 'pwsh -NoProfile -ExecutionPolicy Bypass -File tests\windows\logon.ps1 -Phase check'
else
    echo; echo "=== End-to-end and logon: skipped (need a fresh VM; run without --no-reset) ==="
fi

echo
[ "$overall" = 0 ] && echo "All Windows suites passed." || echo "Some Windows suites FAILED."
exit "$overall"
