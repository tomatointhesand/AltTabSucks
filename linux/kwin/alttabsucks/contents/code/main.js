// AltTabSucks — KWin script
//
// Linux/KWin port of lib/window-management.ahk's ManageAppWindows(). Runs inside KWin's
// compositor-side JS scripting sandbox (X-Plasma-API: "javascript"), which is where window
// enumeration/activation and registerShortcut()-based global hotkeys live on Wayland — see
// alttabsucks_linux_porting_checklist.md's "KDE/KWin Specifics" section for why.
//
// Sandbox notes (confirmed empirically, not from docs — the docs are inconsistent across KWin
// versions/script types): no XMLHttpRequest, no process spawning, no file reads, no setTimeout,
// and `async function` fails to parse at all (though Promise itself exists — just not the
// syntax sugar). `callDBus` and `readConfig` ARE available, and `QTimer` is the polling/delay
// primitive in place of setTimeout. The tab-focus/profile-cycling hotkeys below reach
// linux/server/dbus_bridge.py via callDBus, which is async/callback-based (no synchronous
// variant, unlike AHK's WinHttp.Send(..., false)) — that's why their control flow is shaped as
// callback chains rather than the AHK original's straight-line synchronous code.

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

// --- D-Bus bridge to linux/server/dbus_bridge.py ---------------------------------------------
var DBUS_SERVICE = "com.github.tomatointhesand.AltTabSucks";
var DBUS_PATH = "/com/github/tomatointhesand/AltTabSucks";
var DBUS_IFACE = "com.github.tomatointhesand.AltTabSucks";

function bridgeCall(method, args, callback) {
    var fullArgs = [DBUS_SERVICE, DBUS_PATH, DBUS_IFACE, method].concat(args).concat([callback]);
    callDBus.apply(null, fullArgs);
}

// --- Browser window helpers ---------------------------------------------------------------
// Unlike findAppWindows (used by manageAppWindows above), profile-cycling/tab-focus need to
// match windows by *caption* against tab titles from the server, not just resourceClass —
// mirrors AHK's WinGetTitle-based matching in lib/chromium.ahk. Same normalWindow/!transient
// filter as the WS_VISIBLE+unowned equivalent; also requires a non-empty caption since an
// unmatched window can't be identified as belonging to any profile anyway.
function listBrowserWindows(resourceClass) {
    var result = [];
    var order = workspace.stackingOrder;
    for (var i = 0; i < order.length; i++) {
        var w = order[i];
        if (w.resourceClass !== resourceClass) continue;
        if (!w.normalWindow || w.transient) continue;
        if (!w.caption) continue;
        result.push(w);
    }
    return result;
}

function windowStillExists(w) {
    return workspace.stackingOrder.indexOf(w) !== -1;
}

// cycleChromiumProfile(resourceClass, profileName)
//
// Linux port of lib/chromium.ahk's CycleChromiumProfile(). Cycles through a browser profile's
// open windows, identified by matching their captions against that profile's active-tab titles
// (fetched from the bridge server via GetActiveTitles) — same approach as the AHK version.
//
// Simplifications from the AHK version (noted rather than silently dropped):
//   - No HWND-ascending sort for "stable ordering" — KWin windows have no numeric-id equivalent,
//     so this preserves workspace.stackingOrder's iteration order instead. Still stable across
//     repeated presses as long as the window set doesn't change, which is all that matters.
//   - No _ServerHasAnyTabData()-based distinction between "server just restarted" and "profile
//     really isn't open" — always falls back to all visible windows of resourceClass when no
//     title match is found. Minor UX difference, only visible right after a server (re)start.
//   - Launching the browser when NO windows exist at all isn't implemented (same gap as
//     manageAppWindows' launch-on-empty) — needs a process-spawn D-Bus method, not yet added to
//     dbus_bridge.py. Logs and returns instead of silently doing nothing.
var _chromiumCache = {}; // profileName -> { titlesKey: string, windows: [Window, ...] }

function cycleChromiumProfile(resourceClass, profileName) {
    bridgeCall("GetActiveTitles", [profileName], function (titlesKey) {
        var matching = [];
        var cached = _chromiumCache[profileName];
        if (cached && cached.titlesKey === titlesKey && cached.windows.every(windowStillExists)) {
            matching = cached.windows;
        } else if (titlesKey) {
            var titles = titlesKey.split("\n");
            var candidates = listBrowserWindows(resourceClass);
            for (var i = 0; i < candidates.length; i++) {
                var w = candidates[i];
                for (var j = 0; j < titles.length; j++) {
                    if (titles[j] && w.caption.indexOf(titles[j]) !== -1) { matching.push(w); break; }
                }
            }
            _chromiumCache[profileName] = { titlesKey: titlesKey, windows: matching };
        }

        if (matching.length === 0) matching = listBrowserWindows(resourceClass); // fallback: any window of this browser

        if (matching.length === 0) {
            // TODO: launch the browser with this profile — needs a process-spawn D-Bus method
            // (see manageAppWindows' equivalent TODO). Not implemented yet.
            print("AltTabSucks: no windows open for profile '" + profileName + "' and launch isn't wired up yet");
            return;
        }

        var active = workspace.activeWindow;
        var activeIdx = -1;
        for (var i = 0; i < matching.length; i++) {
            if (matching[i] === active) { activeIdx = i; break; }
        }
        activateWindow(matching[(activeIdx + 1) % matching.length]);
    });
}

// focusTab(resourceClass, profileName, urlPatterns, openUrl)
//
// Linux port of lib/chromium.ahk's FocusTab(). Finds a tab matching any of urlPatterns within
// profileName (across all patterns, unioned, each pattern's server-side sort order preserved)
// and queues a switch command for the browser extension to actually perform — same division of
// labor as the AHK version: this activates a browser *window*, the extension
// (BrowserExtension/background.js, polling GET /switchtab) handles the *tab*-level switch.
//
// Simplifications from the AHK version:
//   - No cooldown-guarded duplicate-tab prevention on rapid repeated presses while a tab is
//     still loading (AHK's _focusTabOpenedAt map) — would need a per-hotkey QTimer-based
//     equivalent; not yet added.
//   - No _ServerHasAnyTabData() fallback distinction, same caveat as cycleChromiumProfile above.
//   - Launching the browser fresh (no window open at all) isn't implemented — same gap as
//     manageAppWindows/cycleChromiumProfile. Opening a new tab in an *existing* window IS
//     implemented, since that doesn't need process spawning.
var _focusTabIdx = {}; // "profile:patternKey" -> last cycled index

function focusTab(resourceClass, profileName, urlPatterns, openUrl) {
    if (typeof urlPatterns === "string") urlPatterns = [urlPatterns];
    var cleanPatterns = urlPatterns.map(function (p) { return p.replace(/^https?:\/\//, ""); });
    var cacheKey = profileName + ":" + cleanPatterns.join("|");

    // Steal focus to a browser window first, same as the AHK version — harmless even though
    // Linux/Wayland likely doesn't need AHK's foreground-lock-timeout workaround (the extension
    // activates the target window itself via chrome.windows.update), kept faithful rather than
    // assuming that holds without verifying it.
    var arrivedFromOutside = !(workspace.activeWindow && workspace.activeWindow.resourceClass === resourceClass);
    if (arrivedFromOutside) {
        var anyWindow = listBrowserWindows(resourceClass)[0];
        if (anyWindow) activateWindow(anyWindow);
    }

    findTabAcrossPatterns(profileName, cleanPatterns, 0, [], {}, function (matchLines) {
        if (matchLines.length === 0) {
            openInExistingWindow(resourceClass, profileName, openUrl);
            return;
        }
        if (arrivedFromOutside) _focusTabIdx[cacheKey] = 0;
        var idx = (_focusTabIdx[cacheKey] || 0) % matchLines.length;
        _focusTabIdx[cacheKey] = idx + 1;

        var parts = matchLines[idx].split("|");
        bridgeCall("QueueSwitchTab", [profileName, parseInt(parts[0], 10), parseInt(parts[1], 10)], function () {});
    });
}

// Sequentially queries FindTab for each pattern (mirrors AHK's for-loop of synchronous HTTP
// calls, just as a callback chain instead), unions results de-duplicated, preserving each
// pattern's own sort order.
function findTabAcrossPatterns(profileName, patterns, i, acc, seen, done) {
    if (i >= patterns.length) { done(acc); return; }
    bridgeCall("FindTab", [profileName, patterns[i]], function (result) {
        if (result) {
            var lines = result.split("\n");
            for (var j = 0; j < lines.length; j++) {
                if (lines[j] && !seen[lines[j]]) { seen[lines[j]] = true; acc.push(lines[j]); }
            }
        }
        findTabAcrossPatterns(profileName, patterns, i + 1, acc, seen, done);
    });
}

// No matching tab — open openUrl in an existing window for this profile if one exists (matched
// by active-tab titles same as cycleChromiumProfile, falling back to any window of this browser).
function openInExistingWindow(resourceClass, profileName, openUrl) {
    bridgeCall("GetActiveTitles", [profileName], function (titlesKey) {
        var w = null;
        if (titlesKey) {
            var titles = titlesKey.split("\n");
            var candidates = listBrowserWindows(resourceClass);
            for (var i = 0; i < candidates.length && !w; i++) {
                for (var j = 0; j < titles.length; j++) {
                    if (titles[j] && candidates[i].caption.indexOf(titles[j]) !== -1) { w = candidates[i]; break; }
                }
            }
        }
        if (!w) w = listBrowserWindows(resourceClass)[0];

        if (!w) {
            // TODO: same launch gap as cycleChromiumProfile/manageAppWindows.
            print("AltTabSucks: no window open for profile '" + profileName + "' to open a tab in, and launch isn't wired up yet");
            return;
        }
        activateWindow(w);
        bridgeCall("QueueSwitchOpenUrl", [profileName, openUrl], function () {});
    });
}

// --- your hotkeys go in hotkeys.js, not here --------------------------------------------------
// This file has no registerShortcut calls of its own — it's the library half only. KWin's
// scripting sandbox can't read a sibling file at runtime (no file-read primitive, confirmed
// empirically — see the sandbox notes above), so unlike AHK's #Include lib\app-hotkeys.ahk, the
// two halves can't be combined at *run* time. installer.sh's install_kwin_script() concatenates
// this file with hotkeys.js (gitignored — seeded from hotkeys.template.js if missing, same
// "seed from template on first install" behavior as installer.ps1 uses for app-hotkeys.ahk) into
// the actual deployed contents/code/main.js at *install* time instead. See hotkeys.template.js
// for the registerShortcut calls that used to live here as dev-test stubs.
