// AltTabSucks — KWin script
//
// Linux/KWin port of lib/window-management.ahk's ManageAppWindows(). Runs inside KWin's
// compositor-side JS scripting sandbox (X-Plasma-API: "javascript"), which is where window
// enumeration/activation and registerShortcut()-based global hotkeys live on Wayland — see
// alttabsucks_linux_porting_checklist.md's "KDE/KWin Specifics" section for why.
//
// Sandbox notes (confirmed empirically, not from docs — the docs are inconsistent across KWin
// versions/script types): no XMLHttpRequest, no process spawning, no file reads. `callDBus` and
// `readConfig` ARE available. This means the tab-focus/profile-cycling hotkeys (which need to
// call the Python bridge server) can't do so directly the way this file's comments in earlier
// planning assumed — that bridge still needs to be designed (see checklist). Pure window
// management, which is everything in this file so far, needs none of that.

var CYCLE_SINGLE_AS_TOGGLE = false; // mirrors the AHK global of the same name; TODO(Phase 3): make configurable

// Windows matching resourceClass, split into visible/minimized — equivalent to the AHK version's
// WS_VISIBLE + unowned filter over WinGetList("ahk_exe " processName):
//   - w.normalWindow excludes panels/docks/tooltips/popups/etc (WS_VISIBLE-ish: only real
//     top-level app windows)
//   - w.transient excludes dialogs owned by another window (AHK's GetWindow(hwnd, GW_OWNER) check)
function findAppWindows(resourceClass) {
    var visible = [], minimized = [];
    var order = workspace.stackingOrder;
    for (var i = 0; i < order.length; i++) {
        var w = order[i];
        if (w.resourceClass !== resourceClass) continue;
        if (!w.normalWindow) continue;
        if (w.transient) continue;
        if (w.minimized) minimized.push(w);
        else visible.push(w);
    }
    return { visible: visible, minimized: minimized };
}

// Assigning workspace.activeWindow auto-restores a minimized window (confirmed empirically) —
// matches AHK's WinActivate semantics, so callers don't need a separate restore step first.
function activateWindow(w) {
    workspace.activeWindow = w;
    // TODO(Phase 3): ShowProfileToast equivalent (lib/toast.ahk) — needs its own titlebar-color
    // sampling investigation, see checklist.
}

// manageAppWindows(resourceClass, mode)
//   resourceClass - Linux window class to match, e.g. "brave-browser", "org.kde.dolphin"
//   mode          - "cycle"  : advance through all windows (visible then minimized), wrapping
//                              around; restores the target window as it comes up in rotation;
//                              0 windows -> launch (not yet implemented, see TODO below); 1
//                              window -> same as "toggle" when CYCLE_SINGLE_AS_TOGGLE is true
//                 - "toggle" : focus the app if it isn't active; minimize all its visible
//                              windows if one of them is currently active
//
// Note: unlike the AHK version, "is the active window mine" is a direct resourceClass compare
// rather than a HWND-membership fallback — AHK needed the fallback because privilege-level
// differences could cause windows to be missed from the visible/minimized scan; there's no such
// gap here since KWin's workspace API isn't subject to that.
function manageAppWindows(resourceClass, mode) {
    mode = mode || "cycle";
    var found = findAppWindows(resourceClass);
    var visible = found.visible, minimized = found.minimized;

    if (visible.length === 0 && minimized.length === 0) {
        // TODO: launching requires spawning a process, which this sandbox can't do directly.
        // Needs the same bridge-server escape hatch as tab focus/profile cycling — see checklist.
        print("AltTabSucks: no windows for " + resourceClass + " and launch-on-empty isn't wired up yet");
        return;
    }

    var active = workspace.activeWindow;

    if (mode === "toggle") {
        var isMine = active && active.resourceClass === resourceClass;
        if (isMine) {
            for (var i = 0; i < visible.length; i++) visible[i].minimized = true;
        } else {
            for (var i = 0; i < minimized.length; i++) minimized[i].minimized = false;
            activateWindow(visible.length > 0 ? visible[0] : minimized[0]);
        }
        return;
    }

    if (mode === "cycle" && CYCLE_SINGLE_AS_TOGGLE && (visible.length + minimized.length === 1)) {
        manageAppWindows(resourceClass, "toggle");
        return;
    }

    var all = visible.concat(minimized);
    var activeIdx = -1;
    for (var i = 0; i < all.length; i++) {
        if (all[i] === active) { activeIdx = i; break; }
    }
    activateWindow(all[(activeIdx + 1) % all.length]);
}

// --- dev-only verification hotkeys ---------------------------------------------------------
// Temporary, not real bindings (those belong in a gitignored local config once that pattern is
// worked out for Linux, mirroring lib/app-hotkeys.ahk) — just enough to invoke manageAppWindows
// against real windows for manual verification via:
//   qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut "<title>"
registerShortcut("ATS Dev Test: Cycle Brave", "AltTabSucks Dev Test: Cycle Brave Windows",
    "Ctrl+Alt+Shift+F13", function () { manageAppWindows("brave-browser", "cycle"); });
registerShortcut("ATS Dev Test: Toggle Brave", "AltTabSucks Dev Test: Toggle Brave Windows",
    "Ctrl+Alt+Shift+F14", function () { manageAppWindows("brave-browser", "toggle"); });
