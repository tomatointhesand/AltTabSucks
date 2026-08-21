#!/usr/bin/env bash
# installer.sh — install/manage AltTabSucks on Linux/KDE. Mirrors installer.ps1's contract
# (install|uninstall|status|start|stop) for muscle-memory parity across platforms, but is much
# simpler: systemd --user and kpackagetool6 are standard per-user mechanisms, so unlike Windows
# there's no scheduled-task API to wrangle and — importantly — no elevation/UAC step at all;
# everything here runs at the normal user session level. See
# alttabsucks_linux_porting_checklist.md's "KDE/KWin Specifics" section for why the KWin script
# is the hotkey layer here (no separate "launch AHK at login" step exists on this side either —
# the KWin script runs inside the always-running compositor once installed).
#
# Usage: ./installer.sh [install|uninstall|status|start|stop|configure|reload-hotkeys]  (default: install)
# `configure` re-runs just the interactive browser wizard (choose_browser) to regenerate
# linux/server/config.py without touching the service or KWin script — install runs it
# automatically too, but only the first time (an existing config.py is left alone otherwise).
# `reload-hotkeys` re-runs just install_kwin_script (rebuild + force-reload, no deps/config/
# service touched) — this is what the D-Bus bridge's ReloadHotkeys method shells out to, wired to
# Ctrl+Alt+Shift+' in main.js, the Linux side of AltTabSucks.ahk's own built-in `^!+'::Reload`.
# Picks up hotkeys.json edits saved via the hotkeys-ui page without a manual terminal step.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="$REPO_ROOT/linux/systemd/alttabsucks-server.service"
SERVICE_NAME="alttabsucks-server.service"
SERVICE_DEST="$HOME/.config/systemd/user/$SERVICE_NAME"
KWIN_SCRIPT_DIR="$REPO_ROOT/linux/kwin/alttabsucks"
KWIN_PLUGIN_ID="alttabsucks"
CONFIG_PATH="$REPO_ROOT/linux/server/config.py"
CONFIG_TEMPLATE="$REPO_ROOT/linux/server/config.template.py"
HOTKEYS_PATH="$KWIN_SCRIPT_DIR/contents/code/hotkeys.js"
HOTKEYS_TEMPLATE="$KWIN_SCRIPT_DIR/contents/code/hotkeys.template.js"
TOKEN_PATH="$REPO_ROOT/Server/token.txt"

ACTION="${1:-install}"

# ---- dependency checks ----------------------------------------------------------------------

check_deps() {
    local missing=()
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v kpackagetool6 >/dev/null 2>&1 || missing+=("kpackagetool6 (part of a KDE Plasma install)")
    command -v kwriteconfig6 >/dev/null 2>&1 || missing+=("kwriteconfig6 (part of a KDE Plasma install)")
    command -v qdbus6 >/dev/null 2>&1 || missing+=("qdbus6 (part of a KDE Plasma install)")
    command -v systemctl >/dev/null 2>&1 || missing+=("systemctl")
    python3 -c "import dbus" >/dev/null 2>&1 || missing+=("python-dbus")
    python3 -c "from gi.repository import GLib" >/dev/null 2>&1 || missing+=("python-gobject")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing dependencies:"
        printf '  - %s\n' "${missing[@]}"
        if command -v pacman >/dev/null 2>&1; then
            echo
            echo "Install the Python ones on Arch with:"
            echo "  sudo pacman -S python-dbus python-gobject"
            echo "(the kwin/qt6 tools come with a KDE Plasma install already — if any of those"
            echo "are missing, something's unusual about this setup and is worth a closer look)"
        fi
        exit 1
    fi
}

# ---- browser config bootstrap ----------------------------------------------------------------
# Known Linux Chromium-family user-data dirs (confirmed by a "Local State" file, so a stale
# leftover config dir from an uninstalled browser doesn't count as a hit) alongside their KWin
# resourceClass — the value manageAppWindows/cycleChromiumProfile/focusTab match windows by, and
# exactly the kind of thing that silently breaks every hotkey if wrong with no error anywhere
# (see the porting checklist's troubleshooting notes). Only brave-browser is empirically confirmed
# on this port; the rest are the standard Linux packaging convention, so choose_browser verifies
# against a real open window when it can rather than trusting this table blindly.
BROWSER_DIRS=("BraveSoftware/Brave-Browser" "google-chrome" "microsoft-edge" "vivaldi" "chromium")
BROWSER_NAMES=("Brave" "Chrome" "Edge" "Vivaldi" "Chromium")
BROWSER_RESOURCE_CLASSES=("brave-browser" "google-chrome" "microsoft-edge" "vivaldi-stable" "chromium-browser")
# Space-separated launch-command candidates per browser, checked in order via `command -v` —
# package naming varies by distro (this port's dev machine installs Brave's binary as plain
# "brave", not "brave-browser", even though its *resourceClass* is "brave-browser" — confirmed
# empirically, not assumed; see config.template.py's CHROMIUM_EXE comment). Used for the
# launch-a-browser-profile escape hatch, not window matching.
BROWSER_EXE_CANDIDATES=(
    "brave brave-browser"
    "google-chrome-stable google-chrome"
    "microsoft-edge-stable microsoft-edge"
    "vivaldi-stable vivaldi"
    "chromium chromium-browser"
)

# Set by choose_browser on success; consumed by ensure_hotkeys to pre-fill hotkeys.js when it
# seeds a fresh copy from the template. Left unset if choose_browser wasn't run this invocation
# (config.py already existed) or the user picked manual entry without giving a resourceClass.
CHOSEN_RESOURCE_CLASS=""

# Returns the first candidate (space-separated in $1) actually found on PATH, or empty.
find_on_path() {
    local candidate
    for candidate in $1; do
        command -v "$candidate" >/dev/null 2>&1 && { echo "$candidate"; return; }
    done
}

# If a window matching "<caption> - <browser_name>" is open right now (the title-suffix
# convention every Chromium-based browser uses), reports its *real* resourceClass on stdout —
# ground truth instead of the guessed table above. Prints nothing if no such window is open.
verify_resource_class() {
    local browser_name="$1" probe plugin result
    probe="$(mktemp --suffix=.js)"
    cat > "$probe" <<PROBE_EOF
var order = workspace.stackingOrder;
for (var i = 0; i < order.length; i++) {
    var w = order[i];
    if (w.caption && w.caption.indexOf(" - ${browser_name}") !== -1) {
        print("ATS_INSTALLER_PROBE:" + w.resourceClass);
        break;
    }
}
PROBE_EOF
    plugin="atsinstallerprobe$$"
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$probe" "$plugin" >/dev/null 2>&1
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1
    sleep 0.5
    result="$(journalctl --user --since '-3 seconds' --no-pager 2>/dev/null | grep -o 'ATS_INSTALLER_PROBE:.*' | tail -1 | cut -d: -f2)"
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$plugin" >/dev/null 2>&1
    rm -f "$probe"
    echo "$result"
}

choose_browser() {
    local detected=() i
    for i in "${!BROWSER_DIRS[@]}"; do
        [ -f "$HOME/.config/${BROWSER_DIRS[$i]}/Local State" ] && detected+=("$i")
    done

    local menu=()
    for i in "${detected[@]}"; do
        menu+=("${BROWSER_NAMES[$i]} (detected at ~/.config/${BROWSER_DIRS[$i]})")
    done
    menu+=("Other / not detected — enter paths manually")

    echo "Which browser should AltTabSucks manage?"
    local pick chosen_idx="" manual=false
    select pick in "${menu[@]}"; do
        if [ -n "${pick:-}" ]; then
            if [ "$((REPLY - 1))" -lt "${#detected[@]}" ]; then
                chosen_idx="${detected[$((REPLY - 1))]}"
            else
                manual=true
            fi
            break
        fi
    done

    local userdata resource_class exe="" name
    if [ "$manual" = true ]; then
        read -rp "Browser user-data directory (e.g. ~/.config/YourBrowser): " userdata
        userdata="${userdata/#\~/$HOME}"
        read -rp "Browser window resourceClass (see the checklist's KDE/KWin Specifics section for how to find this): " resource_class
        read -rp "Browser launch command (e.g. what you'd type in a terminal to start it): " exe
    else
        userdata="$HOME/.config/${BROWSER_DIRS[$chosen_idx]}"
        resource_class="${BROWSER_RESOURCE_CLASSES[$chosen_idx]}"
        name="${BROWSER_NAMES[$chosen_idx]}"
        echo "Checking whether $name is running right now, to confirm the resourceClass..."
        local verified
        verified="$(verify_resource_class "$name")"
        if [ -n "$verified" ] && [ "$verified" != "$resource_class" ]; then
            echo "Confirmed via a real open window: resourceClass is actually '$verified' (guessed '$resource_class')."
            resource_class="$verified"
        elif [ -n "$verified" ]; then
            echo "Confirmed via a real open window: resourceClass is '$resource_class'."
        else
            echo "$name doesn't appear to be running right now, so this is the standard Linux"
            echo "packaging guess ('$resource_class'), not empirically confirmed — worth double"
            echo "checking once you've tried a hotkey (see the checklist's KDE/KWin Specifics section)."
        fi

        exe="$(find_on_path "${BROWSER_EXE_CANDIDATES[$chosen_idx]}")"
        if [ -n "$exe" ]; then
            echo "Found launch command on PATH: '$exe'."
        else
            echo "Couldn't find $name on PATH under any known name — the launch-a-browser-profile"
            echo "escape hatch won't work until CHROMIUM_EXE is set by hand in linux/server/config.py."
        fi
    fi

    {
        echo "import os"
        echo "CHROMIUM_USERDATA = \"$userdata\""
        echo "CHROMIUM_EXE = \"$exe\""
        echo "CHROMIUM_EXTRA_FLAGS = []"
    } > "$CONFIG_PATH"
    echo "Wrote linux/server/config.py (CHROMIUM_USERDATA=$userdata, CHROMIUM_EXE=$exe)."
    CHOSEN_RESOURCE_CLASS="$resource_class"
}

ensure_config() {
    if [ -f "$CONFIG_PATH" ]; then
        echo "linux/server/config.py already exists — leaving it as-is (run './installer.sh configure' to redo the browser wizard)."
        return
    fi
    choose_browser
}

# ---- systemd service --------------------------------------------------------------------------

install_service() {
    mkdir -p "$(dirname "$SERVICE_DEST")"
    cp "$SERVICE_SRC" "$SERVICE_DEST"
    systemctl --user daemon-reload
    if systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        # enable --now on an already-running service is a no-op re: the running process — it
        # won't pick up code changes on disk without an explicit restart (found this the hard
        # way: re-ran install after a server fix and kept serving the 90-minute-old process).
        systemctl --user enable "$SERVICE_NAME"
        systemctl --user restart "$SERVICE_NAME"
        echo "Service already running — restarted to pick up any changes: $SERVICE_NAME"
    else
        systemctl --user enable --now "$SERVICE_NAME"
        echo "Service installed and started: $SERVICE_NAME"
    fi
}

uninstall_service() {
    if systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || [ -f "$SERVICE_DEST" ]; then
        systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$SERVICE_DEST"
        systemctl --user daemon-reload
        echo "Service removed: $SERVICE_NAME"
    else
        echo "$SERVICE_NAME is not installed."
    fi
    # stop also mirrors installer.ps1's habit of cleaning up anything orphaned holding the port
    pkill -f "python3 .*alttabsucks_server\.py" 2>/dev/null || true
}

# ---- KWin script -----------------------------------------------------------------------------
# kpackagetool6 --upgrade on an already-*loaded* script does NOT make KWin reload its JS (learned
# the hard way — see the checklist's Phase 2 notes); loadScript unload + reconfigure is what
# actually forces a fresh load, so that's what's used here rather than relying on --upgrade alone.

ensure_hotkeys() {
    if [ -f "$HOTKEYS_PATH" ]; then
        return
    fi
    cp "$HOTKEYS_TEMPLATE" "$HOTKEYS_PATH"
    if [ -n "$CHOSEN_RESOURCE_CLASS" ]; then
        sed -i "s/YOUR_BROWSER_RESOURCE_CLASS/$CHOSEN_RESOURCE_CLASS/g" "$HOTKEYS_PATH"
        echo "Created linux/kwin/alttabsucks/contents/code/hotkeys.js from the template, with your"
        echo "browser's resourceClass ('$CHOSEN_RESOURCE_CLASS') already filled in — still edit in"
        echo "your real profile name(s) and URLs before the examples do anything."
    else
        echo "Created linux/kwin/alttabsucks/contents/code/hotkeys.js from the template — edit it to add your hotkeys."
    fi
}

# Builds a staging copy of the KWin script package whose contents/code/main.js is the tracked
# library code (main.js) concatenated with hotkeys.js (gitignored, your real bindings) — the two
# can't be combined at *run* time the way AHK's #Include does, since the KWin scripting sandbox
# has no file-read primitive (see main.js's header comment for why). Echoes the staging dir path;
# caller is responsible for rm -rf'ing it once kpackagetool6 is done with it.
build_staged_kwin_package() {
    local staging
    staging="$(mktemp -d)"
    cp -r "$KWIN_SCRIPT_DIR"/. "$staging/"
    {
        cat "$KWIN_SCRIPT_DIR/contents/code/main.js"
        echo
        echo "// --- hotkeys.js (concatenated in by installer.sh) ---------------------------------------"
        cat "$HOTKEYS_PATH"
    } > "$staging/contents/code/main.js"
    # hotkeys.js/hotkeys.template.js are source material only, not part of the shipped script —
    # drop them from the staged copy so there's exactly one script file KWin could ever load.
    rm -f "$staging/contents/code/hotkeys.js" "$staging/contents/code/hotkeys.template.js"
    echo "$staging"
}

install_kwin_script() {
    ensure_hotkeys
    local staged
    staged="$(build_staged_kwin_package)"
    if qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded "$KWIN_PLUGIN_ID" 2>/dev/null | grep -q true; then
        kpackagetool6 --type=KWin/Script --upgrade "$staged"
        qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$KWIN_PLUGIN_ID" >/dev/null
    else
        kpackagetool6 --type=KWin/Script -i "$staged" 2>/dev/null \
            || kpackagetool6 --type=KWin/Script --upgrade "$staged"
    fi
    rm -rf "$staged"
    kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_PLUGIN_ID}Enabled" true
    qdbus6 org.kde.KWin /KWin reconfigure
    echo "KWin script installed and enabled: $KWIN_PLUGIN_ID"
}

uninstall_kwin_script() {
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$KWIN_PLUGIN_ID" >/dev/null 2>&1 || true
    kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_PLUGIN_ID}Enabled" false 2>/dev/null || true
    kpackagetool6 --type=KWin/Script -r "$KWIN_PLUGIN_ID" 2>/dev/null || true
    qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    echo "KWin script removed: $KWIN_PLUGIN_ID"
}

# ---- actions ---------------------------------------------------------------------------------

do_install() {
    check_deps
    ensure_config
    install_service
    install_kwin_script

    sleep 1
    if [ -f "$TOKEN_PATH" ]; then
        echo
        echo "Auth token (paste into the extension Options page): $(tr -d '\n' < "$TOKEN_PATH")"
    else
        echo
        echo "token.txt not yet created — wait a moment, then run: cat '$TOKEN_PATH'"
    fi
    echo
    echo "Next: load BrowserExtension/ unpacked in your browser, open its Options page, and"
    echo "paste in the token above."
}

do_uninstall() {
    uninstall_service
    uninstall_kwin_script
    echo "Note: linux/server/config.py and Server/token.txt were left in place (same as the"
    echo "Windows uninstaller leaves token.txt) — remove them by hand if you want a clean slate."
}

do_status() {
    echo "--- server ---"
    systemctl --user status "$SERVICE_NAME" --no-pager -l 2>&1 || echo "$SERVICE_NAME is not installed."
    echo
    echo "--- kwin script ---"
    local loaded
    loaded=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded "$KWIN_PLUGIN_ID" 2>/dev/null || echo "false")
    echo "loaded: $loaded"
    if [ -f "$TOKEN_PATH" ]; then
        echo
        echo "Auth token: $(tr -d '\n' < "$TOKEN_PATH")"
    fi
}

do_start() { systemctl --user start "$SERVICE_NAME"; echo "Started $SERVICE_NAME."; }
do_stop()  { systemctl --user stop "$SERVICE_NAME"; echo "Stopped $SERVICE_NAME."; }

do_configure() {
    check_deps
    choose_browser
    echo
    echo "Run './installer.sh install' to redeploy the server with this browser config."
}

# Deliberately skips check_deps/ensure_config/install_service — by the time this can run at all
# (triggered from inside the KWin script via a live D-Bus call), kpackagetool6 etc. already
# succeeded once and the server is already running; re-verifying/restarting either on every
# hotkey-triggered reload would just be slower and risk a server hiccup for something that never
# touches the server.
do_reload_hotkeys() {
    install_kwin_script
}

case "$ACTION" in
    install)         do_install ;;
    uninstall)       do_uninstall ;;
    status)          do_status ;;
    start)           do_start ;;
    stop)            do_stop ;;
    configure)       do_configure ;;
    reload-hotkeys)  do_reload_hotkeys ;;
    *)
        echo "Usage: $0 [install|uninstall|status|start|stop|configure|reload-hotkeys]"
        exit 1
        ;;
esac
