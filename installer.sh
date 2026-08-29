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
# service touched) — not a special case, just what a "Reload Hotkeys" runCommand binding's argv
# points at (see hotkeys_generator.py's runCommand docs and hotkeys.template.js), the Linux side
# of AltTabSucks.ahk's own built-in `^!+'::Reload`. Picks up hotkeys.json edits saved via the
# hotkeys-ui page without a manual terminal step — run it by hand too, any time.

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
TOAST_SERVICE_SRC="$REPO_ROOT/linux/systemd/alttabsucks-toast.service"
TOAST_SERVICE_NAME="alttabsucks-toast.service"
TOAST_SERVICE_DEST="$HOME/.config/systemd/user/$TOAST_SERVICE_NAME"

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
    # Toast confirmations are a required part of the install, not a best-effort extra — checked
    # here alongside every other hard dependency instead of the separate soft check_toast_deps()
    # this used to be (which let `install` "succeed" with no on-screen feedback for any hotkey
    # ever, silently, unless you happened to read the terminal at install time). A missing
    # gtk4-layer-shell now stops the install the same way a missing kpackagetool6 does.
    python3 -c "
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gtk4LayerShell', '1.0')
from gi.repository import Gtk4LayerShell
" >/dev/null 2>&1 || missing+=("gtk4-layer-shell (toast confirmations after a hotkey fires)")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing dependencies:"
        printf '  - %s\n' "${missing[@]}"
        if command -v pacman >/dev/null 2>&1; then
            echo
            echo "Install the non-KDE ones on Arch with:"
            echo "  sudo pacman -S python-dbus python-gobject gtk4-layer-shell"
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
    local staged
    mkdir -p "$(dirname "$SERVICE_DEST")"
    # Templated the same way install_toast_service() below already handles YOUR_REPO_ROOT — this
    # used to be a bare `cp`, with the tracked unit file's ExecStart hardcoded to
    # %h/git/alttabsucks specifically. That only ever worked for a clone at exactly that path;
    # everyone else's install silently pointed ExecStart at a nonexistent file. Staged through a
    # tmpfile rather than sed -i'ing $SERVICE_SRC in place, so the tracked template itself never
    # gets mutated on disk.
    staged="$(mktemp)"
    sed -e "s|YOUR_REPO_ROOT|$REPO_ROOT|g" "$SERVICE_SRC" > "$staged"
    cp "$staged" "$SERVICE_DEST"
    rm -f "$staged"
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

# ---- toast daemon (linux/toast/alttabsucks_toast.py) -----------------------------------------
# Separate service, separate (non-fatal) dependency check — toasts are a pure enhancement layered
# on top of core functionality (every hotkey works fine without them), so a machine without
# gtk4-layer-shell installed shouldn't be blocked from installing the rest of AltTabSucks the way
# check_deps()'s hard requirements do.

find_gtk4_layer_shell_so() {
    # awk's `exit` closes its read end as soon as it finds a match, well before ldconfig (which
    # lists hundreds of libraries) finishes writing — ldconfig then gets SIGPIPE, and under
    # set -o pipefail that failure (141) propagates as this whole script exiting, even though the
    # awk side succeeded and got what it needed. `|| true` on ldconfig's own exit status is what
    # actually neutralizes that — piping its output through unchanged doesn't (confirmed the hard
    # way: the plain pipe version killed `./installer.sh install` immediately after the KWin
    # script step, with no other explanation than this).
    { ldconfig -p 2>/dev/null || true; } | awk '/libgtk4-layer-shell\.so / { print $NF; exit }'
}

install_toast_service() {
    local so_path staged
    so_path="$(find_gtk4_layer_shell_so)"
    if [ -z "$so_path" ]; then
        # check_deps already confirmed gtk4-layer-shell's Python bindings import cleanly, so
        # reaching this specific failure means the .so itself is somewhere ldconfig doesn't know
        # about (an unusual install layout) — worth stopping for rather than silently shipping
        # an install with no toast daemon, now that this is a required feature, not optional.
        echo "ERROR: gtk4-layer-shell's Python bindings are available, but couldn't resolve" >&2
        echo "libgtk4-layer-shell.so's path via ldconfig — can't install the toast daemon." >&2
        echo "Check 'ldconfig -p | grep gtk4-layer-shell' and your library path setup." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$TOAST_SERVICE_DEST")"
    staged="$(mktemp)"
    sed -e "s|YOUR_GTK4_LAYER_SHELL_SO|$so_path|g" -e "s|YOUR_REPO_ROOT|$REPO_ROOT|g" \
        "$TOAST_SERVICE_SRC" > "$staged"
    cp "$staged" "$TOAST_SERVICE_DEST"
    rm -f "$staged"
    systemctl --user daemon-reload
    if systemctl --user is-active "$TOAST_SERVICE_NAME" >/dev/null 2>&1; then
        systemctl --user enable "$TOAST_SERVICE_NAME"
        systemctl --user restart "$TOAST_SERVICE_NAME"
        echo "Toast daemon already running — restarted to pick up any changes: $TOAST_SERVICE_NAME"
    else
        systemctl --user enable --now "$TOAST_SERVICE_NAME"
        echo "Toast daemon installed and started: $TOAST_SERVICE_NAME"
    fi
}

uninstall_toast_service() {
    if systemctl --user is-enabled "$TOAST_SERVICE_NAME" >/dev/null 2>&1 || [ -f "$TOAST_SERVICE_DEST" ]; then
        systemctl --user disable --now "$TOAST_SERVICE_NAME" 2>/dev/null || true
        rm -f "$TOAST_SERVICE_DEST"
        systemctl --user daemon-reload
        echo "Toast daemon removed: $TOAST_SERVICE_NAME"
    fi
    pkill -f "python3 .*alttabsucks_toast\.py" 2>/dev/null || true
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
    # Unconditional (unlike CHOSEN_RESOURCE_CLASS below, which depends on the browser wizard
    # having run) — $REPO_ROOT is always known, so if the template still has this placeholder at
    # all (see below — it usually won't), any "Reload Hotkeys"-style example ends up pointing at
    # this exact clone's installer.sh, no user input required.
    sed -i "s|YOUR_REPO_ROOT|$REPO_ROOT|g" "$HOTKEYS_PATH"
    # hotkeys.template.js is dev-scripts/make-template.sh's *unsanitized* mirror of the repo
    # owner's own real hotkeys.js by default now (see .gitignore's own comment) — a working
    # example with real resourceClass/URL values already in it, not "YOUR_BROWSER_RESOURCE_CLASS"
    # placeholders, so there's usually nothing here for CHOSEN_RESOURCE_CLASS to fill in at all.
    # Checked rather than assumed either way, so the printed message stays accurate regardless of
    # which kind of template a given checkout happens to have.
    if [ -n "$CHOSEN_RESOURCE_CLASS" ] && grep -q "YOUR_BROWSER_RESOURCE_CLASS" "$HOTKEYS_PATH"; then
        sed -i "s/YOUR_BROWSER_RESOURCE_CLASS/$CHOSEN_RESOURCE_CLASS/g" "$HOTKEYS_PATH"
        echo "Created linux/kwin/alttabsucks/contents/code/hotkeys.js from the template, with your"
        echo "browser's resourceClass ('$CHOSEN_RESOURCE_CLASS') already filled in — still edit in"
        echo "your real profile name(s) and URLs before the examples do anything."
    else
        echo "Created linux/kwin/alttabsucks/contents/code/hotkeys.js from hotkeys.template.js — this"
        echo "mirrors the repo owner's own real config as of the last commit (a working example, not"
        echo "generic placeholders), so edit it to match your own setup before relying on it."
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

# kglobalaccel keeps a global action's key sticky to whatever it was on *first-ever* registration
# under that action name — confirmed the hard way: renaming a binding's key via the hotkeys-ui
# page (same title, different key) silently kept the *old* key bound forever, because
# registerShortcut()'s key argument is only honored the first time kglobalaccel sees that action
# name; a later call under the same name is treated as "already configured, don't overwrite" (by
# design, so a script update doesn't clobber a user's own customization made in System Settings).
# Explicitly unregistering every AltTabSucks-owned action before each reload's fresh
# registerShortcut calls is what makes a key *change* (not just a first-time key *set*) actually
# take effect — scoped to the "AltTabSucks: " friendly-name prefix every generated binding uses
# (see hotkeys_generator.py) so this never touches an unrelated kwin/Plasma shortcut. Best-effort:
# if python3/dbus errors out here for any reason, the reload should still proceed rather than
# abort over a cleanup step — worst case, a stale key persists, same as before this existed.
unregister_alttabsucks_shortcuts() {
    python3 -c "
import dbus
bus = dbus.SessionBus()
kga = dbus.Interface(bus.get_object('org.kde.kglobalaccel', '/kglobalaccel'), 'org.kde.KGlobalAccel')
comp = dbus.Interface(bus.get_object('org.kde.kglobalaccel', '/component/kwin'), 'org.kde.kglobalaccel.Component')
for info in comp.allShortcutInfos():
    unique, friendly = str(info[0]), str(info[1])
    if friendly.startswith('AltTabSucks: '):
        kga.unregister('kwin', unique)
" 2>/dev/null || true
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
    # Written just before reconfigure (the call that actually triggers the new script instance
    # loading), not after this whole function returns. This is what a "Reload Hotkeys" runCommand
    # binding's confirmation toast actually rides on: that binding triggers this exact function
    # from *inside* the script being reloaded, and unloadScript above tears down that JS context
    # — on success — before it could ever see a reply to its own RunCommandWithOutput call
    # (confirmed empirically; see the porting checklist). The *new* instance picks up the baton on
    # its own startup instead (see main.js's own comment for the other half), checking for a
    # marker recent enough to be from *this* reload rather than some unrelated earlier one — no
    # writeConfig available in the KWin scripting sandbox to explicitly clear it after showing it
    # (only readConfig — see main.js's sandbox notes), so recency stands in for that.
    kwriteconfig6 --file kwinrc --group "Script-$KWIN_PLUGIN_ID" --key pendingReloadToast \
        "$(date +%s%3N)|KWin script reloaded successfully."
    # Also only once kpackagetool6 has already succeeded above, same reasoning as the marker
    # write just above — a failure earlier in this function leaves the *old* script (and its
    # already-working shortcuts) untouched rather than unregistering hotkeys with no new
    # registration ready to replace them.
    unregister_alttabsucks_shortcuts
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
    install_toast_service

    # token.txt is written by the server process itself on its first run (load_or_create_token),
    # not by anything in this script — `systemctl --user enable --now` only guarantees the
    # process has been *spawned* (Type=simple's whole definition of "active"), not that it's
    # gotten far enough to import dbus-python/GLib and write the file yet. A flat `sleep 1` here
    # used to just guess that was always enough; polled instead so a one-shot `install` reliably
    # ends with the token in hand on a slower first cold start too, not a "run this again in a
    # second" fallback as the common case.
    local waited=0
    while [ ! -f "$TOKEN_PATH" ] && [ "$waited" -lt 100 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if [ -f "$TOKEN_PATH" ]; then
        echo
        echo "Auth token (paste into the extension Options page): $(tr -d '\n' < "$TOKEN_PATH")"
    else
        echo
        echo "token.txt still not created after 10s — something's wrong with the server; check:"
        echo "  journalctl --user -u $SERVICE_NAME -e"
    fi
    echo
    echo "Next: load BrowserExtension/ unpacked in your browser, open its Options page, and"
    echo "paste in the token above."
}

do_uninstall() {
    uninstall_service
    uninstall_kwin_script
    uninstall_toast_service
    echo "Note: linux/server/config.py and Server/token.txt were left in place (same as the"
    echo "Windows uninstaller leaves token.txt) — remove them by hand if you want a clean slate."
}

do_status() {
    echo "--- server ---"
    systemctl --user status "$SERVICE_NAME" --no-pager -l 2>&1 || echo "$SERVICE_NAME is not installed."
    echo
    echo "--- toast daemon ---"
    systemctl --user status "$TOAST_SERVICE_NAME" --no-pager -l 2>&1 || echo "$TOAST_SERVICE_NAME is not installed."
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

do_start() {
    systemctl --user start "$SERVICE_NAME"
    echo "Started $SERVICE_NAME."
    if [ -f "$TOAST_SERVICE_DEST" ]; then
        systemctl --user start "$TOAST_SERVICE_NAME"
        echo "Started $TOAST_SERVICE_NAME."
    fi
}
do_stop() {
    systemctl --user stop "$SERVICE_NAME"
    echo "Stopped $SERVICE_NAME."
    if [ -f "$TOAST_SERVICE_DEST" ]; then
        systemctl --user stop "$TOAST_SERVICE_NAME"
        echo "Stopped $TOAST_SERVICE_NAME."
    fi
}

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
