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
# Usage: ./installer.sh [install|uninstall|status|start|stop]  (default: install)

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
# Known Linux Chromium-family user-data dirs, confirmed by the presence of a "Local State" file
# (so an empty/leftover config dir from a since-uninstalled browser doesn't count as a hit).

detect_chromium_installs() {
    local dirs=(
        "$HOME/.config/BraveSoftware/Brave-Browser"
        "$HOME/.config/google-chrome"
        "$HOME/.config/microsoft-edge"
        "$HOME/.config/vivaldi"
        "$HOME/.config/chromium"
    )
    for dir in "${dirs[@]}"; do
        [ -f "$dir/Local State" ] && echo "$dir"
    done
}

ensure_config() {
    if [ -f "$CONFIG_PATH" ]; then
        echo "linux/server/config.py already exists — leaving it as-is (edit it by hand to change browsers)."
        return
    fi

    mapfile -t found < <(detect_chromium_installs)
    local chosen=""
    if [ ${#found[@]} -eq 0 ]; then
        echo "No supported Chromium-based browser auto-detected."
    elif [ ${#found[@]} -eq 1 ]; then
        chosen="${found[0]}"
        echo "Detected browser data at: $chosen"
    else
        echo "Multiple browsers detected — pick one (you can add more manually later):"
        select dir in "${found[@]}"; do
            if [ -n "${dir:-}" ]; then chosen="$dir"; break; fi
        done
    fi

    if [ -n "$chosen" ]; then
        {
            echo "import os"
            echo "CHROMIUM_USERDATA = \"$chosen\""
        } > "$CONFIG_PATH"
        echo "Wrote linux/server/config.py (CHROMIUM_USERDATA=$chosen)."
    else
        cp "$CONFIG_TEMPLATE" "$CONFIG_PATH"
        echo "Wrote linux/server/config.py from the template — edit CHROMIUM_USERDATA by hand"
        echo "before profile cycling will work."
    fi
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
    echo "Created linux/kwin/alttabsucks/contents/code/hotkeys.js from the template — edit it to add your hotkeys."
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

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    start)     do_start ;;
    stop)      do_stop ;;
    *)
        echo "Usage: $0 [install|uninstall|status|start|stop]"
        exit 1
        ;;
esac
