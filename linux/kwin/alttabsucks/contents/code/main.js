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
// toastLabel is optional — omit it for activations that shouldn't show a toast (e.g. focusTab's
// preliminary focus-steal before the real tab switch is confirmed; AHK doesn't toast that step
// either). See showToast() below for what actually renders it.
function activateWindow(w, toastLabel) {
    workspace.activeWindow = w;
    if (toastLabel) showToast(toastLabel, w);
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
            // lib/window-management.ahk's ManageAppWindows does the equivalent Run(exePath) and
            // nothing more — fine on Windows, where a hotkey-launched app's window generally
            // grabs foreground on its own. Confirmed live this isn't true here: KWin's focus-
            // stealing prevention means a freshly Popen()'d process's window does *not* get
            // focus once it finally appears, moments after this callback has already returned —
            // reported as "won't launch a new instance", when the process was actually starting
            // fine, just silently, off-screen-focus-wise. Same 500ms/8s poll-then-activate shape
            // as waitAndActivateProfile/waitForTabOrOpen, which launch into the identical gap.
            waitAndActivateLaunchedWindow(resourceClass, Date.now() + 8000);
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
            activateWindow(visible.length > 0 ? visible[0] : minimized[0], resourceClass);
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
    activateWindow(all[(activeIdx + 1) % all.length], resourceClass);
}

// Polls for the first window of resourceClass to appear after manageAppWindows's LaunchCommand
// spawn, then activates it — see the comment at that call site for why this step exists at all.
// Same 500ms/8s poll-then-activate tuning as waitAndActivateProfile/waitForTabOrOpen, not new
// numbers.
function waitAndActivateLaunchedWindow(resourceClass, deadline) {
    var found = findAppWindows(resourceClass);
    var w = found.visible[0] || found.minimized[0];
    if (w) {
        activateWindow(w, resourceClass);
        return;
    }
    if (Date.now() < deadline) {
        afterDelay(500, function () { waitAndActivateLaunchedWindow(resourceClass, deadline); });
    }
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

// --- Toast overlay (linux/toast/alttabsucks_toast.py) -----------------------------------------
// Linux port of lib/toast.ahk's ShowProfileToast — a separate D-Bus service, not dbus_bridge.py,
// since it's a standalone GTK4 daemon rather than part of the Python HTTP bridge server (see that
// file's module docstring for why it's built the way it is, including why there's no titlebar-
// color sampling here the way SampleTitlebarColor does on Windows).
//
// Label convention, matching every currently-ported hotkey type's own activateWindow/
// activateAnyWindow call site: manageAppWindows toasts with resourceClass (no _SwitcherExeName-
// style friendly-name table has been ported — same deferral as the window switcher itself, see
// the checklist), cycleChromiumProfile/focusTab toast with profileName, matching
// ShowProfileToast's own callers exactly (AHK always toasts with the profile name for any
// Chromium window activation, never the tab title).
//
// Fire-and-forget: if the toast daemon isn't installed/running (gtk4-layer-shell is a non-fatal
// dependency — see installer.sh's check_toast_deps), this callDBus just fails the same silent way
// any call to a D-Bus service with no owner does. Nothing here depends on toasts actually
// appearing — every hotkey works identically whether or not the daemon exists.
var TOAST_BUS_NAME = "com.github.tomatointhesand.AltTabSucksToast";
var TOAST_OBJECT_PATH = "/com/github/tomatointhesand/AltTabSucksToast";
var TOAST_INTERFACE = "com.github.tomatointhesand.AltTabSucksToast";

function showToast(label, w) {
    if (!w) return;
    callDBus(TOAST_BUS_NAME, TOAST_OBJECT_PATH, TOAST_INTERFACE, "ShowToast",
        label, "", w.x, w.y, w.width, w.height, 500, function () {});
}

// runCommand bindings (hotkeys_generator.py) call this instead of the LaunchCommand escape
// hatch manageAppWindows' launchArgv uses — that one is fire-and-forget, right for GUI apps that
// never exit and whose output nobody's waiting to read. A runCommand binding is the opposite
// case: usually a short CLI-style command (installer.sh reload-hotkeys is the motivating one)
// where the entire point of pressing the hotkey is finding out whether it actually worked.
// RunCommandWithOutput (dbus_bridge.py) waits for it and hands back "exitCode\noutput" as one
// string — parsed here rather than relying on a multi-value D-Bus return, which nothing in this
// codebase has exercised yet (see that method's own docstring for why).
function runCommandWithToast(title, argv) {
    bridgeCall("RunCommandWithOutput", [argv], function (resultStr) {
        var nl = resultStr.indexOf("\n");
        var exitCode = parseInt(resultStr.slice(0, nl), 10);
        var output = resultStr.slice(nl + 1);
        showCommandResultToast(title, exitCode === 0, output);
    });
}

// Not tied to any particular window the way showToast's other callers are (manageAppWindows/
// cycleChromiumProfile/focusTab all act on a specific app or browser window) — a runCommand
// binding is generic "run this on this key", so this just positions over whatever's currently
// focused rather than anything the command itself touched.
function showCommandResultToast(title, ok, output) {
    var w = workspace.activeWindow;
    if (!w) return;
    callDBus(TOAST_BUS_NAME, TOAST_OBJECT_PATH, TOAST_INTERFACE, "ShowCommandResult",
        title, ok ? 1 : 0, output, w.x, w.y, w.width, w.height, 0, function () {});
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
        activateWindow(matching[(activeIdx + 1) % matching.length], profileName);
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
                        activateWindow(candidates[i], profileName);
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
var _focusTabLast = {}; // "profile:patternKey" -> {windowId, tabId, tick} we ourselves last switched to
// Same identity-isn't-enough problem the toast daemon's rainbow-cycling already solved with a
// recency window (see toast_colors.py's RAINBOW_CONTINUE_WINDOW_MS): landing on the exact tab
// this hotkey last picked doesn't by itself prove *this* press is a deliberate repeat — you could
// just as easily have gotten back to that same tab some *other* way (cycled to that browser
// window with a different hotkey, switched to it by hand, ...) long after the fact, with no
// intention of cycling. Bounding "is this our own last pick" by how recently we picked it is what
// tells "you're still actively repeating this hotkey" apart from "you happen to be on the tab we
// put you on a while ago" — 2s mirrors the cooldown lib/chromium.ahk's own FocusTab uses for a
// related purpose (_focusTabOpenedAt, duplicate-tab prevention), not an arbitrary new constant.
var FOCUS_TAB_REPEAT_WINDOW_MS = 2000;

// Position of a {windowId, tabId} within a parsed FindTab result, or -1 if it's not there
// (closed since, or nothing recorded yet).
function findTabIndex(parsed, ref) {
    if (!ref) return -1;
    for (var i = 0; i < parsed.length; i++) {
        if (parsed[i].windowId === ref.windowId && parsed[i].tabId === ref.tabId) return i;
    }
    return -1;
}

function focusTab(resourceClass, profileName, urlPatterns, openUrl) {
    if (typeof urlPatterns === "string") urlPatterns = [urlPatterns];
    var cleanPatterns = urlPatterns.map(function (p) { return p.replace(/^https?:\/\//, ""); });
    var cacheKey = profileName + ":" + cleanPatterns.join("|");

    // Steal focus to a browser window first, same as the AHK version — harmless even though
    // Linux/Wayland likely doesn't need AHK's foreground-lock-timeout workaround (the extension
    // activates the target window itself via chrome.windows.update), kept faithful rather than
    // assuming that holds without verifying it.
    var arrivedFromOutside = !(workspace.activeWindow && workspace.activeWindow.resourceClass === resourceClass);
    // Captured before the pre-activation step below can change workspace.activeWindow, and only
    // meaningful when !arrivedFromOutside anyway (if we arrived from outside the browser
    // entirely, there's no sense in which we could already be "on" one of the matches).
    var currentCaption = (!arrivedFromOutside && workspace.activeWindow) ? workspace.activeWindow.caption : "";
    if (arrivedFromOutside) {
        var anyWindow = listBrowserWindows(resourceClass)[0];
        if (anyWindow) activateWindow(anyWindow);
    }

    findTabAcrossPatterns(profileName, cleanPatterns, 0, [], {}, function (matchLines) {
        if (matchLines.length === 0) {
            openOrLaunchTab(resourceClass, profileName, cleanPatterns, openUrl);
            return;
        }
        var parsed = matchLines.map(parseTabLine);
        var last = _focusTabLast[cacheKey];
        var idx;
        if (arrivedFromOutside) {
            idx = 0;
        } else {
            // Which match (if any) is already the front-and-center tab right now.
            var currentIdx = -1;
            for (var k = 0; k < parsed.length; k++) {
                if (parsed[k].title && currentCaption.indexOf(parsed[k].title) !== -1) {
                    currentIdx = k;
                    break;
                }
            }
            if (currentIdx !== -1) {
                // Showing a match — but "stay" and "cycle to next" look identical from here
                // unless we know *why* it's showing. If it's the exact tab *we* switched to on
                // our own last invocation of this same hotkey, *recently*, this is a deliberate
                // repeat press asking for the next one — advance. Otherwise (fresh arrival some
                // other way, or a stale/no-longer-relevant pick from an earlier press) it already
                // satisfies the hotkey's goal on its own — stay, don't disturb it.
                //
                // The recency bound matters on its own, not just the identity check: without it,
                // landing back on the exact tab this hotkey happened to pick the *last* time it
                // ran — via some unrelated route, possibly long after, e.g. cycling to this same
                // browser window with a different hotkey — reads identically to a genuine repeat
                // press, and gets cycled away from instead of left alone. (An earlier version of
                // this fix had no recency bound at all and just checked "is any match showing" —
                // that broke cycling entirely, since after the first switch you're always
                // "currently showing a match"; identity-without-recency is the narrower version
                // of that same mistake.)
                var isOwnLastPick = last && parsed[currentIdx].windowId === last.windowId
                    && parsed[currentIdx].tabId === last.tabId
                    && (Date.now() - last.tick) < FOCUS_TAB_REPEAT_WINDOW_MS;
                idx = isOwnLastPick ? (currentIdx + 1) % parsed.length : currentIdx;
            } else {
                // Not currently on any match at all (in the browser, but on an unrelated tab) —
                // pick up from wherever we last left off within the *current* match set, same
                // fallback cycling as before this whole investigation started. No recency bound
                // here: there's no "already correct" ambiguity to guard against when nothing
                // currently showing is a match at all.
                var lastIdx = findTabIndex(parsed, last);
                idx = lastIdx === -1 ? 0 : (lastIdx + 1) % parsed.length;
            }
        }
        _focusTabLast[cacheKey] = { windowId: parsed[idx].windowId, tabId: parsed[idx].tabId, tick: Date.now() };

        var parts = parsed[idx];
        // Explicitly raise the *specific* window containing this tab rather than trusting
        // chrome.windows.update({focused: true}) (triggered by the extension once it dequeues
        // /switchtab) to do it alone — a Wayland client generally can't force itself to the
        // front; only the compositor can, which is exactly why this is a KWin script and not just
        // a browser extension. This used to call activateAnyWindow() — *any* window of this
        // browser, not necessarily the one with the matched tab — which looked fine with a single
        // browser window open but was a real reported bug with several: it raised some other
        // window and left the actual target's tab silently switched in the background.
        //
        // Matching by *this* tab's own title (a first attempt) was also wrong, just less
        // obviously: it only works when the matched tab already happens to be the one currently
        // showing in its window, since that's the only case where its title is what the window's
        // caption currently reads. Confirmed exactly this way — worked for Gmail (coincidentally
        // already the active tab), silently fell back to "any window" for YouTube (wasn't).
        // GetWindowActiveTitle asks for the window's *actual current* active-tab title instead —
        // reliable regardless of which tab within it got matched — then activateWindowForTab
        // matches window caption against that, same technique cycleChromiumProfile/
        // GetActiveTitles already use elsewhere.
        bridgeCall("GetWindowActiveTitle", [profileName, parts.windowId], function (activeTitle) {
            activateWindowForTab(resourceClass, activeTitle, profileName);
            bridgeCall("QueueSwitchTab", [profileName, parts.windowId, parts.tabId], function () {});
        });
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

// FindTab's result is "windowId|tabId|title" per line (see dbus_bridge.py's FindTab docstring
// for what the title is/isn't used for) — title last and unsplit, since a page title can itself
// contain "|".
function parseTabLine(line) {
    var p1 = line.indexOf("|");
    var p2 = line.indexOf("|", p1 + 1);
    return {
        windowId: parseInt(line.slice(0, p1), 10),
        tabId: parseInt(line.slice(p1 + 1, p2), 10),
        title: line.slice(p2 + 1),
    };
}

function activateAnyWindow(resourceClass, toastLabel) {
    var w = listBrowserWindows(resourceClass)[0];
    if (w) activateWindow(w, toastLabel);
}

// Like activateAnyWindow, but targets the *specific* window whose caption matches the given
// title instead of just grabbing the first one — see the comment at focusTab's call site for why
// that distinction is a real bug fix, not a nicety, and why the title passed in needs to be the
// target window's *currently active* tab's title (from GetWindowActiveTitle), not the matched
// tab's own title. Falls back to activateAnyWindow's "any window" behavior when there's no title
// to match (e.g. a just-opened window with no active tab reported yet) or nothing matches it,
// rather than activating nothing at all.
function activateWindowForTab(resourceClass, title, toastLabel) {
    var candidates = listBrowserWindows(resourceClass);
    var target = null;
    if (title) {
        for (var i = 0; i < candidates.length; i++) {
            if (candidates[i].caption.indexOf(title) !== -1) { target = candidates[i]; break; }
        }
    }
    if (!target) target = candidates[0];
    if (target) activateWindow(target, toastLabel);
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
            activateWindow(w, profileName);
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
            var parts = parseTabLine(matchLines[0]);
            // Specific window, same as focusTab's main match branch (see its comment for why
            // this needs GetWindowActiveTitle rather than the matched tab's own title) — a
            // session-restored tab found in a freshly-launched profile can still land in the
            // wrong window if more than one was already open for other profiles/reasons.
            bridgeCall("GetWindowActiveTitle", [profileName, parts.windowId], function (activeTitle) {
                activateWindowForTab(resourceClass, activeTitle, profileName);
                bridgeCall("QueueSwitchTab", [profileName, parts.windowId, parts.tabId], function () {});
            });
            return;
        }
        if (Date.now() < deadline) {
            afterDelay(500, function () { waitForTabOrOpen(resourceClass, profileName, cleanPatterns, openUrl, deadline); });
            return;
        }
        // No specific tab to target here — falling back to opening openUrl as a brand new tab,
        // so there's no title yet to match a window by. activateAnyWindow's plain "any window"
        // behavior is the correct fallback, not a shortcut.
        activateAnyWindow(resourceClass, profileName);
        bridgeCall("QueueSwitchOpenUrl", [profileName, openUrl], function () {});
    });
}

// --- Split/merge (Ctrl+Alt+Shift+X / +Z on Windows: lib/chromium.ahk's SplitFocusedTab /
// MergeFocusedWindow) --------------------------------------------------------------------------
// Both require resourceClass+profileName explicitly (unlike AHK, which auto-detects the profile
// from the active window's title via _DetectProfileFromWindow) — matches every other browser-
// related binding type here (profileCycle, tabFocus), and QueueSplitTab/QueueMergeTabs need a
// profile to key the switch queue by regardless. Both no-op if the active window isn't this
// browser at all, same as AHK's WinActive(winFilter) early-return.

// splitTab(profile) tells the extension to detach the active tab into its own new window
// (chrome.windows.create({tabId})); this side then finds that new window and puts it and the
// original window side by side. AHK does the "side by side" part by simulating Win+Right/Win+Left
// (Windows' own Snap, the only scriptable way to place a window there without doing the geometry
// math by hand) — KWin exposes window.frameGeometry directly, so this sets both windows'
// geometry explicitly instead of simulating anything, and doesn't need AHK's WinMove-before-
// Win+Left workaround for "snap state" carrying over from a previous snap.
//
// frameGeometry takes a plain {x, y, width, height} object, not Qt.rect(...) — confirmed live
// (a KDE Plasma 6 discuss.kde.org example used Qt.rect, but this sandbox has no global `Qt` at
// all: typeof Qt === "undefined" here, so that call would throw). Also confirmed live that
// mutating the *returned* object's properties (w.frameGeometry.x = ...) is a silent no-op — it
// hands back a detached snapshot, not a live-bound reference — so this always assigns a whole
// new object to w.frameGeometry rather than touching one of its properties.
function splitFocusedTab(resourceClass, profileName) {
    var origWindow = workspace.activeWindow;
    if (!origWindow || origWindow.resourceClass !== resourceClass) return;

    var existingWindows = listBrowserWindows(resourceClass);
    bridgeCall("QueueSplitTab", [profileName], function () {
        afterDelay(100, function () { waitAndSnapSplit(resourceClass, origWindow, existingWindows, Date.now() + 3000); });
    });
}

// Polls (mirrors the 100ms/3s tuning of every other bridgeCall-then-poll loop above) for a
// browser window that wasn't in the pre-split snapshot — the one the extension just detached the
// tab into. A freshly created window can take a moment to get a caption (listBrowserWindows
// requires one), so this can't just check "one more window than before" on the first poll.
function waitAndSnapSplit(resourceClass, origWindow, existingWindows, deadline) {
    var current = listBrowserWindows(resourceClass);
    var newWindow = null;
    for (var i = 0; i < current.length; i++) {
        if (existingWindows.indexOf(current[i]) === -1) { newWindow = current[i]; break; }
    }
    if (!newWindow) {
        if (Date.now() < deadline) {
            afterDelay(100, function () { waitAndSnapSplit(resourceClass, origWindow, existingWindows, deadline); });
        }
        return;
    }
    if (!windowStillExists(origWindow)) return; // vanished mid-split — nothing sane to snap

    var area = workspace.clientArea(KWin.MaximizeArea, origWindow);
    var halfW = Math.floor(area.width / 2);
    origWindow.frameGeometry = { x: area.x, y: area.y, width: halfW, height: area.height };
    newWindow.frameGeometry = { x: area.x + halfW, y: area.y, width: area.width - halfW, height: area.height };
    workspace.activeWindow = newWindow; // AHK ends the same way: WinActivate(newHwnd)
}

// mergeTabs(profile) moves every tab from the focused window into the profile's other window,
// then the extension activates and maximizes that target window itself (chrome.windows.update)
// — no window-hunting/snapping needed on this side at all, unlike split.
function mergeFocusedWindow(resourceClass, profileName) {
    var active = workspace.activeWindow;
    if (!active || active.resourceClass !== resourceClass) return;
    bridgeCall("QueueMergeTabs", [profileName], function () {});
}

// --- periodic push: keep hotkeys-ui.html's resourceClass typeahead fresh -----------------------
// The bridge server has no way to ask this script for live window data on demand — everything
// else in dbus_bridge.py flows this-script-calls-server (the sandbox can call *out* via callDBus,
// never be called *into*), so a live "what's running right now" typeahead needs this script to
// push instead of the server pulling. Same shape as the browser extension's own POST /tabs.
// 10s is plenty fresh for a human picking a resourceClass while editing a hotkey, and cheap
// enough (one enumeration + one D-Bus call) to just run forever rather than being tied to window
// add/remove events.
function pushRunningResourceClasses() {
    var order = workspace.stackingOrder;
    var seen = {};
    var classes = [];
    for (var i = 0; i < order.length; i++) {
        var w = order[i];
        // Same normalWindow/!transient filter as findAppWindows above — only real top-level app
        // windows are worth offering, not panels/docks/dialogs.
        if (!w.normalWindow || w.transient || !w.resourceClass) continue;
        if (seen[w.resourceClass]) continue;
        seen[w.resourceClass] = true;
        classes.push(w.resourceClass);
    }
    bridgeCall("PushRunningResourceClasses", [classes], function () {});
    afterDelay(10000, pushRunningResourceClasses);
}
pushRunningResourceClasses();

// --- one-shot startup: pick up a pending reload confirmation ---------------------------------
// See installer.sh's install_kwin_script for the other half of this. A "Reload Hotkeys"
// runCommand binding's confirmation toast can't ride on its own RunCommandWithOutput reply — the
// command it runs (installer.sh reload-hotkeys) unloads *this exact script* on success, partway
// through, destroying the JS context waiting for that reply before it could ever show anything
// (confirmed empirically: a harmless non-reloading command shows its toast fine every time, this
// one never can, sync or async — the reload always wins the race). Workaround: installer.sh
// writes a timestamped marker into this script's own kwinrc config section just before
// triggering the reload; the *new* instance (this code, run once at the top level on every
// script load) checks for one recent enough to be from *that* reload, not some unrelated earlier
// one. No writeConfig in this sandbox to explicitly clear the marker after showing it (only
// readConfig — see the sandbox notes above) — recency does that job instead.
(function () {
    var raw = readConfig("pendingReloadToast", "");
    if (!raw) return;
    var pipe = raw.indexOf("|");
    if (pipe === -1) return;
    var tick = parseInt(raw.slice(0, pipe), 10);
    var message = raw.slice(pipe + 1);
    if (isNaN(tick) || Date.now() - tick > 10000) return; // stale — not from a reload just now
    // Small delay rather than showing immediately at script-load time — gives KWin's own
    // post-reload window/workspace churn a moment to settle before reading workspace.activeWindow
    // to position the toast against.
    afterDelay(300, function () {
        showCommandResultToast("Reload Hotkeys", true, message);
    });
})();

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
