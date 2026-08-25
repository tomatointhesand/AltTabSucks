// hotkeys.js — your real hotkey bindings go here. Copy this file to hotkeys.js and edit;
// hotkeys.js is gitignored (mirrors lib/app-hotkeys.ahk's pattern on Windows) and
// installer.sh seeds it from this template automatically on first install if it's missing —
// same "seed on first install" behavior installer.ps1 uses for app-hotkeys.ahk.
//
// This file is concatenated onto the end of main.js at *install* time (installer.sh's
// install_kwin_script()), not read at runtime — see main.js's header comment for why. That
// means every function main.js defines (manageAppWindows, cycleChromiumProfile, focusTab,
// activateWindow, ...) is already in scope here; you're just calling registerShortcut with
// them.
//
// Key notation: registerShortcut's third argument is a Qt key sequence string, e.g.
// "Ctrl+Alt+Shift+G". Unlike AHK's ^!+g:: syntax there's no single-character shorthand.

// --- app window cycling/toggle ---------------------------------------------------------------
// manageAppWindows(resourceClass, mode, launchArgv) — resourceClass is the app's Linux window
// class, not its binary name (they often differ — KDE apps commonly use reversed-domain names
// like "org.kde.dolphin"; check with a KWin script probe or `xprop`/similar if unsure).
// launchArgv (optional) is the argv to spawn when no window is open — e.g. ["dolphin"]; omit it
// to just no-op instead of launching.

registerShortcut("Cycle Browser", "AltTabSucks: Cycle Browser Windows",
    "Ctrl+Alt+Shift+B", function () { manageAppWindows("YOUR_BROWSER_RESOURCE_CLASS", "cycle", ["YOUR_BROWSER_COMMAND"]); });

registerShortcut("Toggle File Manager", "AltTabSucks: Toggle File Manager",
    "Ctrl+Alt+Shift+E", function () { manageAppWindows("org.kde.dolphin", "toggle", ["dolphin"]); });

// --- browser profile cycling -------------------------------------------------------------------
// cycleChromiumProfile(resourceClass, profileName) — profileName is the display name from
// about:profiles / chrome://version, not the "Default"/"Profile 1" directory name.

registerShortcut("Cycle Work Profile", "AltTabSucks: Cycle Work Browser Profile",
    "Ctrl+Alt+Shift+P", function () { cycleChromiumProfile("YOUR_BROWSER_RESOURCE_CLASS", "YOUR_BROWSER_PROFILE"); });

// --- browser tab focus ---------------------------------------------------------------------
// focusTab(resourceClass, profileName, urlPatterns, openUrl) — urlPatterns is a single string
// or an array of strings; all matches across all patterns are unioned and cycled together.

registerShortcut("Focus Gmail", "AltTabSucks: Focus Gmail",
    "Ctrl+Alt+Shift+G", function () {
        focusTab("YOUR_BROWSER_RESOURCE_CLASS", "YOUR_BROWSER_PROFILE", "mail.google.com", "https://mail.google.com");
    });

registerShortcut("Focus Calendar or Mail", "AltTabSucks: Focus Calendar or Mail",
    "Ctrl+Alt+Shift+C", function () {
        focusTab("YOUR_BROWSER_RESOURCE_CLASS", "YOUR_BROWSER_PROFILE",
            ["calendar.google.com", "mail.google.com"], "https://calendar.google.com");
    });

// --- run an arbitrary command -------------------------------------------------------------------
// runCommandWithToast(title, argv) — runs argv[0] directly (no shell, so no quoting/injection
// concerns), waits for it to finish, and shows a toast with its exit status and any output.
// (For a GUI app that never exits and whose output nobody's waiting to read, use
// manageAppWindows' optional launchArgv instead — that one's the fire-and-forget escape hatch.)
// YOUR_REPO_ROOT is substituted by installer.sh's ensure_hotkeys() with this clone's actual
// absolute path — every other placeholder here needs your own input, this one doesn't.
//
// Reload — the Linux equivalent of AltTabSucks.ahk's own built-in `^!+'::Reload`. Rebuilds and
// force-reloads the deployed KWin script from main.js+hotkeys.js, picking up any hotkeys.json/
// hotkeys.js edits without a manual terminal step — and the toast is what actually lets you see
// it worked, rather than wondering.
registerShortcut("Reload Hotkeys", "AltTabSucks: Reload Hotkeys",
    "Ctrl+Alt+Shift+'", function () {
        runCommandWithToast("Reload Hotkeys", ["YOUR_REPO_ROOT/installer.sh", "reload-hotkeys"]);
    });
