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

// manageAppWindows(resourceClass, mode, launchArgv)
//   resourceClass - Linux window class to match, e.g. "brave-browser", "org.kde.dolphin"
//   mode          - "cycle"  : advance through all windows (visible then minimized), wrapping
//                              around; restores the target window as it comes up in rotation;
//                              0 windows -> launch launchArgv if given; 1 window -> same as
//                              "toggle" when CYCLE_SINGLE_AS_TOGGLE is true
//                 - "toggle" : focus the app if it isn't active; minimize all its visible
//                              windows if one of them is currently active
//   launchArgv    - optional array of strings, e.g. ["dolphin"] or ["code", "--new-window"] —
//                   passed straight to dbus_bridge.py's LaunchCommand (subprocess.Popen argv,
//                   never shell-interpreted) when no windows exist. Omit to just no-op instead.
//
// Note: unlike the AHK version, "is the active window mine" is a direct resourceClass compare
// rather than a HWND-membership fallback — AHK needed the fallback because privilege-level
// differences could cause windows to be missed from the visible/minimized scan; there's no such
// gap here since KWin's workspace API isn't subject to that.
function manageAppWindows(resourceClass, mode, launchArgv) {
    mode = mode || "cycle";
    var found = findAppWindows(resourceClass);
    var visible = found.visible, minimized = found.minimized;

    if (visible.length === 0 && minimized.length === 0) {
        if (launchArgv) {
            // LaunchCommand takes ONE "as" parameter (the whole argv array) — bridgeCall's
            // .concat(args) spreads each element of `args` as its own D-Bus positional
            // parameter, which is right for every other bridge method (each JS arg = one D-Bus
            // scalar param) but wrong here, since launchArgv itself needs to arrive as a single
            // array argument. Wrapping it ([launchArgv]) is what makes that happen — omitting
            // the wrap silently coerces a 1-element argv into a bare string, which D-Bus then
            // iterates character-by-character into the array instead (confirmed empirically:
            // dbus.Array("dolphin") -> ['d','o','l','p','h','i','n'], not ["dolphin"]).
            bridgeCall("LaunchCommand", [launchArgv], function () {});
        } else {
            print("AltTabSucks: no windows for " + resourceClass + " and manageAppWindows() wasn't given a launch command");
        }
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

// args is the list of D-Bus *parameters* to pass — each element becomes its own positional
// D-Bus argument (works for every bridge method except LaunchCommand, whose single "as"
// parameter needs an extra wrapping array; see the comment at its call site for why).
function bridgeCall(method, args, callback) {
    var fullArgs = [DBUS_SERVICE, DBUS_PATH, DBUS_IFACE, method].concat(args).concat([callback]);
    callDBus.apply(null, fullArgs);
}

// setTimeout replacement (see the sandbox notes above for why) — used by the post-launch polling
// loops below (waitAndActivateProfile, waitForTabOrOpen), mirroring AHK's SetTimer(..., -500)
// chained one-shot pattern.
function afterDelay(ms, fn) {
    var t = new QTimer();
    t.interval = ms;
    t.singleShot = true;
    t.timeout.connect(fn);
    t.start();
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
            launchChromiumProfileAndActivate(resourceClass, profileName);
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

// Launches the profile fresh (dbus_bridge.py's LaunchChromiumProfile — resolves the profile
// *directory* server-side via the self-discovery in profile_discovery.py, and clears stale
// server-side tab state for it first) then polls GetActiveTitles every 500ms for up to 8s until
// a restored window shows up, activating it — mirrors AHK's _WaitAndCycleProfile. No-ops with a
// message if CHROMIUM_EXE/the profile aren't resolvable server-side.
function launchChromiumProfileAndActivate(resourceClass, profileName) {
    bridgeCall("LaunchChromiumProfile", [profileName], function (launched) {
        if (!launched) {
            print("AltTabSucks: couldn't launch profile '" + profileName + "' — check CHROMIUM_EXE in linux/server/config.py");
            return;
        }
        waitAndActivateProfile(resourceClass, profileName, Date.now() + 8000);
    });
}

function waitAndActivateProfile(resourceClass, profileName, deadline) {
    bridgeCall("GetActiveTitles", [profileName], function (titlesKey) {
        if (titlesKey) {
            var titles = titlesKey.split("\n");
            var candidates = listBrowserWindows(resourceClass);
            for (var i = 0; i < candidates.length; i++) {
                for (var j = 0; j < titles.length; j++) {
                    if (titles[j] && candidates[i].caption.indexOf(titles[j]) !== -1) {
                        activateWindow(candidates[i]);
                        return;
                    }
                }
            }
        }
        if (Date.now() < deadline) {
            afterDelay(500, function () { waitAndActivateProfile(resourceClass, profileName, deadline); });
        }
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
            openOrLaunchTab(resourceClass, profileName, cleanPatterns, openUrl);
            return;
        }
        if (arrivedFromOutside) _focusTabIdx[cacheKey] = 0;
        var idx = (_focusTabIdx[cacheKey] || 0) % matchLines.length;
        _focusTabIdx[cacheKey] = idx + 1;

        var parts = matchLines[idx].split("|");
        // Explicitly raise the window here rather than trusting chrome.windows.update({focused:
        // true}) (triggered by the extension once it dequeues /switchtab) to do it alone — a
        // Wayland client generally can't force itself to the front; only the compositor can,
        // which is exactly why this is a KWin script and not just a browser extension. This was
        // the one focusTab path missing that raise (waitForTabOrOpen and openOrLaunchTab's
        // existing-window branch both already do it) — the common case of an already-open
        // matching tab, silently relying on the extension alone and (per report) not actually
        // coming to the front. Same activateAnyWindow(resourceClass) simplification as those
        // other call sites: picks *a* window of this browser, not necessarily the exact one
        // containing the matched tab when several are open — acceptable in the common single-
        // window case, noted rather than silently assumed correct.
        activateAnyWindow(resourceClass);
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

function activateAnyWindow(resourceClass) {
    var w = listBrowserWindows(resourceClass)[0];
    if (w) activateWindow(w);
}

// No matching tab in an already-open window — open openUrl in an existing window for this
// profile if one exists (matched by active-tab titles same as cycleChromiumProfile, falling
// back to any window of this browser). If there's no window at all, launches the profile fresh
// and polls for a session-restored match before falling back to openUrl — mirrors AHK's
// _WaitForTabOrOpen.
function openOrLaunchTab(resourceClass, profileName, cleanPatterns, openUrl) {
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

        if (w) {
            activateWindow(w);
            bridgeCall("QueueSwitchOpenUrl", [profileName, openUrl], function () {});
            return;
        }

        bridgeCall("LaunchChromiumProfile", [profileName], function (launched) {
            if (!launched) {
                print("AltTabSucks: couldn't launch profile '" + profileName + "' — check CHROMIUM_EXE in linux/server/config.py");
                return;
            }
            waitForTabOrOpen(resourceClass, profileName, cleanPatterns, openUrl, Date.now() + 8000);
        });
    });
}

// Polls FindTab every 500ms for up to 8s after a fresh launch, looking for a session-restored
// tab matching one of the original patterns — no duplicate tab if the browser's own session
// restore already reopened it. Falls back to opening openUrl as a new tab on timeout. Either
// way, activates whatever window exists by then (the launch should have produced one).
function waitForTabOrOpen(resourceClass, profileName, cleanPatterns, openUrl, deadline) {
    findTabAcrossPatterns(profileName, cleanPatterns, 0, [], {}, function (matchLines) {
        if (matchLines.length > 0) {
            var parts = matchLines[0].split("|");
            activateAnyWindow(resourceClass);
            bridgeCall("QueueSwitchTab", [profileName, parseInt(parts[0], 10), parseInt(parts[1], 10)], function () {});
            return;
        }
        if (Date.now() < deadline) {
            afterDelay(500, function () { waitForTabOrOpen(resourceClass, profileName, cleanPatterns, openUrl, deadline); });
            return;
        }
        activateAnyWindow(resourceClass);
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
// for the registerShortcut calls that used to live here as dev-test stubs — including "Reload
// Hotkeys" (the Linux equivalent of AltTabSucks.ahk's built-in `^!+'::Reload`), which used to be
// hardcoded here as a special case but is now just an ordinary runCommand binding like any other
// (see hotkeys_generator.py's runCommand docs) — editable/removable in the hotkeys-ui page same
// as everything else, no bespoke framework carve-out.
