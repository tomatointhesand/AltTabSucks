#!/usr/bin/env bash
# e2e.sh - end-to-end tests on the Linux test VM (dev-scripts/run-linux-tests.sh runs it on a VM
# fresh from its "browser" snapshot, with the working tree synced to ~tester/alttabsucks). Runs on
# the host: commands go over SSH (into the Plasma session where they need it), and hotkeys are
# real key presses on the VM's keyboard (QEMU sendkey), so they go the whole way: kglobalaccel,
# the KWin script, the bridge server.
#   phase "main"   - install (browser picker), the startup manager switched on/off through
#                    POST /settings with an autostart takeover, starter hotkeys pressed for
#                    real, the extension pairing by itself, a startup manager --run, then a
#                    reinstall that leaves things ready for the logon check
#   phase "logon"  - after a reboot: the startup manager ran at logon, started the taken-over apps
#                    once (not again by Plasma), and closed itself; then uninstall gives the
#                    autostart entries back
set -uo pipefail
PHASE="${1:-main}"
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/../../dev-scripts/linux-vm.sh"
SHOTS="${ALTTABSUCKS_TEST_SHOTS:-/tmp/alttabsucks-linux-e2e}"
mkdir -p "$SHOTS"
passed=0 failed=0

check() {  # check "<description>" <command...>: passes when the command succeeds
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS  $what"; passed=$((passed + 1))
    else
        echo "FAIL  $what"; failed=$((failed + 1))
    fi
}
vm() { "$V" ssh "$@"; }
desk() { "$V" desktop "$@"; }
wait_for() {  # wait_for <seconds> <command...>
    local secs="$1"; shift
    for _ in $(seq 1 $((secs * 2))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done
    return 1
}
running() { vm "pgrep -x '$1'"; }
count() { vm "pgrep -c -x '$1'" 2>/dev/null || echo 0; }
history_rows() { vm "cat ~/.local/state/alttabsucks/startup-history.jsonl 2>/dev/null | wc -l"; }
more_rows_than() { [ "$(history_rows)" -gt "$1" ]; }
last_item() {  # last_item <name> <field>: a field of an item in the last history row
    vm "tail -1 ~/.local/state/alttabsucks/startup-history.jsonl" | python3 -c "
import json, sys
row = json.loads(sys.stdin.read())
it = next((i for i in row['items'] if i['name'] == sys.argv[1]), {})
print(row[sys.argv[2]] if sys.argv[2] in row else it.get(sys.argv[2], ''))" "$1" "$2"
}
manager_running() { vm "pgrep -f 'startup_manager.py'"; }
manager_gone() { ! manager_running; }
both_hidden() { hidden org.kde.kcalc && hidden e2e-tray; }
no_errors() { ! vm 'test -s ~/.local/state/alttabsucks/startup-errors.log'; }
hidden() { vm "grep -qx 'Hidden=true' ~/.config/autostart/$1.desktop"; }

if [ "$PHASE" = main ]; then
    # ---- autostart entries to take over -------------------------------------------------------
    # KCalc shows a window; e2e-tray is a tray-style app (--tray: ready when its process runs).
    vm 'mkdir -p ~/.config/autostart ~/bin
        printf "#!/bin/sh\nsleep 900\n" > ~/bin/e2e-tray && chmod +x ~/bin/e2e-tray
        printf "[Desktop Entry]\nType=Application\nName=KCalc\nExec=kcalc\n" > ~/.config/autostart/org.kde.kcalc.desktop
        printf "[Desktop Entry]\nType=Application\nName=E2E Tray\nExec=/home/tester/bin/e2e-tray --tray\n" > ~/.config/autostart/e2e-tray.desktop'

    # ---- install ---------------------------------------------------------------------------------
    # Chromium open, so the browser picker confirms its real window class.
    # --load-extension is ignored by recent Chromium unless that switch is enabled again.
    # --password-store=basic: with autologin the KWallet stays locked, and Chromium holds every
    # request that needs cookies until it gets its key from there (a wallet dialog nobody answers).
    desk '(chromium --no-first-run --no-default-browser-check --password-store=basic --disable-features=DisableLoadExtensionCommandLineSwitch --load-extension=$HOME/alttabsucks/BrowserExtension about:blank >/dev/null 2>&1 &)'
    wait_for 30 running chromium
    sleep 3
    # In the Plasma session, like from a terminal there: the installer talks to KWin over its D-Bus.
    desk 'cd ~/alttabsucks && printf "1\n" | ./installer.sh install' > "$SHOTS/install.log" 2>&1
    check "installer.sh install finishes" grep -q "Browser extension:" "$SHOTS/install.log"
    check "  ...the browser picker chose Chromium and confirmed its window class" grep -q "Confirmed via a real open window" "$SHOTS/install.log"
    check "  ...the server answers" wait_for 15 vm "curl -sf -o /dev/null http://127.0.0.1:9876/hotkeys-ui"
    check "  ...the server and toast services are running" vm "systemctl --user is-active alttabsucks-server alttabsucks-toast"
    check "  ...the KWin script is loaded" desk "qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded alttabsucks | grep -qx true"
    check "  ...hotkeys.js has the starter set" vm "grep -q 'Downloads folder' ~/alttabsucks/linux/kwin/alttabsucks/contents/code/hotkeys.js && grep -q 'Search browser tabs' ~/alttabsucks/linux/kwin/alttabsucks/contents/code/hotkeys.js"
    check "  ...the Downloads hotkey points at ~/Downloads" vm "grep -q 'focusOrOpenFolder(\"~/Downloads\")' ~/alttabsucks/linux/kwin/alttabsucks/contents/code/hotkeys.js"

    # ---- the startup manager: off after install, switched on through the Hotkeys page's API ------
    TOKEN="$(vm 'cat ~/alttabsucks/Server/token.txt')"
    api() {  # api METHOD PATH [JSON]: a server call with the token, from inside the VM
        vm "curl -sf -X $1 -H 'X-AltTabSucks-Token: $TOKEN' -H 'Content-Type: application/json' ${3:+-d '$3'} http://127.0.0.1:9876$2"
    }
    startup_enabled() { vm "systemctl --user is-enabled -q alttabsucks-startup.service"; }
    not_hidden() { ! hidden org.kde.kcalc && ! hidden e2e-tray; }
    check "the startup manager is off after install" eval '! startup_enabled'
    check "  ...and Plasma keeps its autostart apps" not_hidden
    check "  ...and GET /settings says so" eval "api GET /settings | grep -q '\"enabled\": false'"
    check "POST /settings switches it on" eval "api POST /settings '{\"startupManager\": true}' | grep -q '\"enabled\": true'"
    check "  ...it runs at logon" startup_enabled
    check "  ...and is in the app menu" vm "test -f ~/.local/share/applications/org.alttabsucks.Startup.desktop"
    check "  ...with nobody to ask, the autostart apps are left for its notice" not_hidden
    vm 'cd ~/alttabsucks && ./installer.sh startup-import' > "$SHOTS/startup-import.log" 2>&1
    check "taking them over puts them in startup.json" vm "python3 -c \"import json,os; c=json.load(open(os.path.expanduser('~/.config/alttabsucks/startup.json'))); n=[i['name'] for i in c['items']]; assert n[0]=='AltTabSucks' and 'KCalc' in n and 'E2E Tray' in n, n\""
    check "  ...and switches them off in Plasma's autostart" both_hidden
    check "  ...the tray app is ready by process, KCalc by window" vm "python3 -c \"import json,os; c=json.load(open(os.path.expanduser('~/.config/alttabsucks/startup.json'))); r={i['name']:i['ready'] for i in c['items']}; assert r['E2E Tray']=='process' and r['KCalc']=='window', r\""
    check "switched off, it no longer runs at logon" eval "api POST /settings '{\"startupManager\": false}' | grep -q '\"enabled\": false' && ! startup_enabled"
    check "  ...and Plasma gets its autostart apps back" not_hidden
    check "switched on again, it takes them over again" eval "api POST /settings '{\"startupManager\": true}' >/dev/null && startup_enabled && both_hidden"
    check "POST /startup-manager/open opens its window" eval "api POST /startup-manager/open >/dev/null && wait_for 20 manager_running"
    vm "pkill -f '[l]inux/startup/startup_manager.py'; true"

    # ---- the extension pairs by itself ---------------------------------------------------------
    check "the extension in Chromium fetches the token and reports its tabs" wait_for 30 vm "curl -sf -H 'X-AltTabSucks-Token: $TOKEN' http://127.0.0.1:9876/debugtabs | grep -q '==='"

    # ---- starter hotkeys, pressed on the VM's keyboard -------------------------------------------
    "$V" key ctrl-alt-shift-n
    check "Ctrl+Alt+Shift+N (starter: Text editor) opens Kate" wait_for 20 running kate
    "$V" key ctrl-alt-shift-down
    check "Ctrl+Alt+Shift+Down (starter: Downloads folder) opens Dolphin" wait_for 20 running dolphin
    check "  ...showing ~/Downloads" wait_for 10 desk "for s in \$(qdbus6 | grep -o 'org.kde.dolphin-[0-9]*'); do for w in \$(qdbus6 \$s | grep -o '^/dolphin/Dolphin_[0-9]*$'); do qdbus6 \$s \$w org.kde.dolphin.MainWindow.isUrlOpen file://\$HOME/Downloads; done; done | grep -qx true"
    "$V" key ctrl-alt-shift-down
    sleep 3
    check "  ...and pressing it again doesn't open a second window" test "$(count dolphin)" = 1
    "$V" screenshot "$SHOTS/hotkeys.png"
    vm 'pkill -x kate; pkill -x dolphin; true'

    # ---- startup manager: a run like the one at logon --------------------------------------------
    rows="$(history_rows)"
    desk '(python3 ~/alttabsucks/linux/startup/startup_manager.py --run >/dev/null 2>&1 &)'
    sleep 4
    "$V" screenshot "$SHOTS/startup-run.png"
    check "the startup manager runs the startup items and records the run" wait_for 60 more_rows_than "$rows"
    check "  ...AltTabSucks: already up, ready" test "$(last_item AltTabSucks status)" = ready
    check "  ...KCalc: its window seen" test "$(last_item KCalc status)" = ready
    check "  ...E2E Tray: its process seen" test "$(last_item 'E2E Tray' status)" = ready
    check "  ...recorded as a manual run" test "$(last_item x trigger)" = manual
    check "  ...and it closes itself once everything is up" wait_for 20 manager_gone
    check "  ...without errors" no_errors
    vm 'pkill -x kcalc; pkill -f bin/e2e-tray; rm -f ~/.local/state/alttabsucks/startup-history.jsonl; true'

elif [ "$PHASE" = logon ]; then
    # ---- after a reboot -----------------------------------------------------------------------
    check "at logon, the startup manager runs and records the run" wait_for 120 vm "test -s ~/.local/state/alttabsucks/startup-history.jsonl"
    "$V" screenshot "$SHOTS/logon.png"
    check "  ...as a logon run, with its time since logon and boot" vm "tail -1 ~/.local/state/alttabsucks/startup-history.jsonl | python3 -c \"import json,sys; r=json.load(sys.stdin); assert r['trigger']=='logon' and isinstance(r['logonToStartMs'], int) and r['bootToStartMs'] > r['logonToStartMs'] >= 0, r\""
    check "  ...AltTabSucks ready" test "$(last_item AltTabSucks status)" = ready
    check "  ...KCalc started and showed its window" test "$(last_item KCalc status)" = ready
    check "  ...E2E Tray started" test "$(last_item 'E2E Tray' status)" = ready
    check "  ...each started once (not again by Plasma's autostart)" test "$(count kcalc)" = 1
    check "  ...and the manager closed itself" wait_for 30 manager_gone
    check "  ...without errors" no_errors

    # ---- uninstall ------------------------------------------------------------------------------
    vm 'cd ~/alttabsucks && ./installer.sh uninstall' > "$SHOTS/uninstall.log" 2>&1
    check "uninstall gives the autostart entries back" vm '! grep -q Hidden ~/.config/autostart/org.kde.kcalc.desktop ~/.config/autostart/e2e-tray.desktop'
    check "  ...removes the startup manager" vm '! test -f ~/.config/systemd/user/alttabsucks-startup.service && ! test -f ~/.local/share/applications/org.alttabsucks.Startup.desktop'
    check "  ...and stops the server" vm '! curl -sf -o /dev/null http://127.0.0.1:9876/hotkeys-ui' 
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
