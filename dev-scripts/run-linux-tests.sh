#!/usr/bin/env bash
# run-linux-tests.sh - everything on the Linux test VM (minimal Arch + Plasma Wayland; one-time
# setup: tests/linux/README.md): rolls it back to its "browser" snapshot, copies this working tree
# (uncommitted changes included) to ~tester/alttabsucks, runs the Python unit suites there, then
# tests/linux/e2e.sh: install, real hotkey presses, the extension pairing, a startup manager run,
# then a reboot and the real logon, then uninstall.
# Usage: dev-scripts/run-linux-tests.sh [--no-reset]
#   --no-reset reuses the running VM and runs the unit suites only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VM="$HERE/linux-vm.sh"
export ALTTABSUCKS_TEST_SHOTS="${ALTTABSUCKS_TEST_SHOTS:-${TMPDIR:-/tmp}/alttabsucks-linux-e2e}"
overall=0
reset=1
[ "${1:-}" = "--no-reset" ] && reset=0

if [ "$reset" = 1 ]; then "$VM" reset; else "$VM" start; fi || exit 1
"$VM" sync >/dev/null || exit 1

run() {  # run "<title>" <command...>
    echo; echo "=== $1 ==="
    shift
    if ! "$@"; then
        echo "-> FAILED"
        overall=1
    fi
}
unit() { "$VM" ssh "cd ~/alttabsucks/linux/$1 && python3 -m unittest discover -s tests 2>&1 | tail -3"; }

run "Server unit tests" unit server
run "Toast unit tests" unit toast
run "Startup manager unit tests" unit startup
if [ "$reset" = 1 ]; then
    run "End-to-end (tests/linux/e2e.sh)" bash "$HERE/../tests/linux/e2e.sh" main
    "$VM" reboot || overall=1
    run "Logon and uninstall (tests/linux/e2e.sh logon)" bash "$HERE/../tests/linux/e2e.sh" logon
    echo; echo "Screenshots and logs: $ALTTABSUCKS_TEST_SHOTS"
else
    echo; echo "=== End-to-end: skipped (needs a fresh VM; run without --no-reset) ==="
fi

echo
[ "$overall" = 0 ] && echo "All Linux suites passed." || echo "Some Linux suites FAILED."
exit "$overall"
