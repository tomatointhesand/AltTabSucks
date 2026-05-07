# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AutoHotkey (AHK) automation scripts for Windows productivity. **Cannot be executed or tested on Linux/WSL** — scripts must be run on a Windows machine with AutoHotkey installed.

Supports **Chromium-based browsers** (Brave, Chrome, Edge, Opera) and **Firefox** for profile-aware tab control.

## Running & Reloading

- **Run**: Double-click `AltTabSucks.ahk` in Windows Explorer
- **Reload**: `Ctrl+Alt+Shift+'`
- **Debug**: Right-click tray icon → "Window Spy"

## AltTabSucks Server

PowerShell HTTP server (`localhost:9876`) that bridges AHK ↔ browser extension for profile-aware tab control.

- **Auto-start (preferred)**: `.\installer.ps1 -Action install` from the repo root (scripts live in `Server/`) — requires **PowerShell 7.6+** (`winget install Microsoft.PowerShell`); triggers UAC, registers Task Scheduler task that restarts on crash, writes startup bat, launches AHK immediately
  - Manage: `.\installer.ps1 -Action status|start|stop|uninstall`
  - `stop` also kills any orphaned `AltTabSucksServer.ps1` processes holding the port
- **Manual**: `.\Server\startServer.ps1`
- **Load extension**: browser extensions page → Developer mode → Load unpacked → `BrowserExtension/` → set profile name and auth token in Options

**Auth token**: On first run, `AltTabSucksServer.ps1` generates `Server/token.txt` (gitignored) containing a random 32-byte base64 secret. All requests must include `X-AltTabSucks-Token: <secret>` or receive 403. AHK reads the token at startup from that file; the extension reads it from `chrome.storage.local` (set via Options page).

## Code Organization

`AltTabSucks.ahk` is the entry point — it self-elevates and `#Include`s everything in `lib/`. **All logic belongs in `lib/`.**

- `lib/config.ahk` — browser paths config (**gitignored** — copy from `config.template.ahk` and fill in)
- `lib/app-hotkeys.ahk` — new hotkeys go here (**gitignored** — contains real URLs/paths)
- `lib/app-hotkeys.template.ahk` — sanitized version of above, tracked in git
- `lib/utils.ahk` — window management utilities, window switcher, settings GUI
- `lib/chromium.ahk` — Chromium profile cycling + tab focus; dispatches to Firefox equivalents when `CHROMIUM_EXE = ""`
- `lib/firefox.ahk` — Firefox profile cycling + tab focus
- `lib/toast.ahk` — visual feedback overlays
- `lib/star-citizen.ahk` — SC-scoped hotkeys (`#HotIf WinActive("Star Citizen")`)

**Gitignored local files**: `lib/config.ahk`, `lib/app-hotkeys.ahk`, and `Server/token.txt` are never committed.

**Template workflow**: Edit `lib/app-hotkeys.ahk` freely — **never edit `lib/app-hotkeys.template.ahk` directly**, it is overwritten on every commit. The pre-commit hook (`hooks/pre-commit`) runs `dev-scripts/make-template.sh` automatically on every `git commit` or `git commit --amend`, regenerating both template files with URLs/paths/profile names redacted and staging them. To trigger template regeneration without other staged changes, amend the top commit: `git commit --amend --no-edit`. Run `bash dev-scripts/install-hooks.sh` once after cloning to activate the hook.

**Template sanitization rules** (`dev-scripts/make-template.sh`): `https://` URLs → `"https://YOUR_URL"` (localhost URLs preserved as-is); Windows paths → `"C:\YOUR\PATH"`; profile name args in `FocusTab()`/`CycleChromiumProfile()`/`FocusTabFirefox()`/`CycleFirefoxProfile()` → `"YOUR_BROWSER_PROFILE"`. AHK comment lines (`;`) are skipped in `config.template.ahk` so example paths in comments are preserved.

## AHK v1 vs v2

They are **not compatible** — check `#Requires` at the top of each file before editing.

| v1 | v2 |
|---|---|
| `MsgBox % var` | `MsgBox(var)` |
| `Send, text` | `Send("text")` |
| `#IfWinActive` | `#HotIf WinActive(...)` |
| `Loop, parse, str, delim` | `Loop Parse(str, delim)` |

## Hotkey Conventions

- General hotkeys: `^!+<key>` (Ctrl+Alt+Shift+key)
- App-scoped: wrap in `#HotIf WinActive("Window Title")` ... `#HotIf`
- `.tmp` files (`*.ahk.tmp.*`) are AHK reload artifacts — not source files

## Architecture Patterns

### Window Management (`lib/utils.ahk`)
`ManageAppWindows(processName, exePath, mode)`:
- Filters to only WS_VISIBLE, unowned windows (avoids Discord tray, child dialogs)
- `"cycle"`: none → launch; 1 → toggle minimize/activate; 2+ → advance through list
- `"toggle"`: active → minimize all; inactive → activate first visible
- On activate, shows `ShowProfileToast` with app name (via `_SwitcherExeName`) and titlebar color
- `exePath` can be a `Func` object (e.g. `() => LaunchStoreApp(...)`) for Store/MSIX apps
- `CYCLE_SINGLE_AS_TOGGLE` global (default `false`): cycle mode falls back to toggle when only one window

### Settings GUI (`lib/utils.ahk`)
`ShowSettingsGui()` — opened via `^!+,`. Themed dark/light, resizable, categorized:
- **Browser**: Chromium EXE/UserData, Firefox EXE/profiles.ini (with Browse buttons)
- **Window Cycling**: `CYCLE_SINGLE_AS_TOGGLE` checkbox
- **Window Switcher**: preview toggle (`SWITCHER_SHOW_PREVIEW`), preview side (`SWITCHER_PREVIEW_SIDE`: "right"/"left"), preview size slider (`SWITCHER_PREVIEW_SIZE`: 10–200%)
- **Appearance**: `THEME` dropdown ("auto"/"light"/"dark")

`_WriteConfigFile()` persists all settings to `lib/config.ahk` (gitignored). Browser path changes trigger `Reload()`; all other changes take effect immediately without reload.

### Window Switcher (`lib/utils.ahk`)
`ShowWindowSwitcher(dir := "down")` — typeahead Alt+Tab replacement. Hotkeys: `!Tab` (down), `!+Tab`/`!vkC0` (up, backtick), `!WheelDown`/`!WheelUp`.

**Globals**: `SWITCHER_SHOW_PREVIEW`, `SWITCHER_PREVIEW_SIDE`, `SWITCHER_PREVIEW_SIZE`.

**Behavior**:
- Lists all visible, unowned, non-cloaked top-level windows in Z-order; defaults to row 2 (previous window)
- Typeahead filters by exe name + title; `_SwitcherExeName` maps/capitalises process names
- Two-column layout (exe name | title), column width dynamic from longest exe name
- Dark/light themed via `_ApplySwitcherTheme`; DWM rounded corners (Win11)
- **Activation**: popup always activates immediately when all held modifiers are released; no persistent mode
- **Mod-release detection**: uses `GetKeyState(mod, "P")` (physical state) to ignore AHK synthetic key-ups
- **Alt+char typeahead**: `WM_SYSKEYDOWN` intercepted, `ToUnicodeEx` (Alt-stripped) translates to char, `EM_REPLACESEL` inserts into edit, `EM_SETSEL` clears auto-select-all
- `_SwitcherRefresh`: Win32 DllCalls throughout (GetTopWindow, GetWindowLong, GetWindowTextW, QueryFullProcessImageNameW with PID cache, WM_SETREDRAW batching)
- `_SwitcherAutoActivateTimer`: started after `g.Show()` (not before `_SwitcherRefresh`) so delay is measured from when popup is visible

**DWM Thumbnail Preview** (`_SwitcherPreviewTimer`, 30ms debounce):
- `DwmRegisterThumbnail(previewHwnd, targetHwnd)` — compositor renders at display refresh rate, zero CPU
- `DwmQueryThumbnailSourceSize` → aspect-correct scaling (max `640×SWITCHER_PREVIEW_SIZE/100` × `400×SWITCHER_PREVIEW_SIZE/100`)
- Preview GUI uses `+ToolWindow` so it is excluded from the switcher's own window list
- `_SwitcherPreviewClose()` called on all close paths: `CloseSwitcher`, `_SwitcherActivate`, Escape, `_SwitcherWMActivate`

### Chromium Profile Cycling (`lib/chromium.ahk`)
Browser is configured via `CHROMIUM_EXE` and `CHROMIUM_USERDATA` globals in `lib/config.ahk`. At startup, `_InitChromiumState()`:
- Saves the foreground-lock timeout via `SPI_GETFOREGROUNDLOCKTIMEOUT` and sets it to 0 so `WinActivate` can always steal focus; restores it on exit via `OnExit(_RestoreFgLockTimeout)`
- Reads `Server\token.txt` into `_serverToken` for authenticating HTTP requests
- Derives `_chromiumExe` (bare filename) via `SplitPath` and populates `_chromiumProfileDirCache` from the browser's `Local State` JSON. Fallback for browsers without `info_cache` (e.g. Opera): scans the user data dir for `Default`/`Profile N` subdirectories, then falls back to a single `"Default"` entry so the extension Options dropdown always has at least one choice
- When Firefox is configured instead (`CHROMIUM_EXE = ""`), detects it via the Windows registry (`HKLM\SOFTWARE\Mozilla\Mozilla Firefox`)

All window filters use `"ahk_class Chrome_WidgetWin_1 ahk_exe " . _chromiumExe`. All WinHttp requests include `X-AltTabSucks-Token` header.

`CycleChromiumProfile(profileName)` dispatches to `CycleFirefoxProfile(profileName)` when `CHROMIUM_EXE = ""`. Otherwise uses a two-level HWND cache:
1. Fetch active tab titles from AltTabSucks (`GET /activetitles?profile=`) → build `titlesKey`
2. Cache hit (same `titlesKey` + valid HWNDs) → reuse list; miss → enumerate by window class+exe, match by title
3. Cycle via `Mod(currentIdx, length) + 1`; sample titlebar color; `WinActivate`; show toast

### Tab Focus (`lib/chromium.ahk`)
`FocusTab(profileName, urlPatterns, openUrl)` dispatches to `FocusTabFirefox` when `CHROMIUM_EXE = ""`. Otherwise:
- `urlPatterns` is a single string or an Array of strings; all matching tabs across all patterns are unioned and cycled together
1. **Steals focus to a browser window before HTTP requests** — required to preserve AHK input eligibility
2. `GET /findtab` called once per pattern; results unioned (deduped), each pattern's server sort order preserved (audible first, then leftmost)
3. Cycle index resets when arriving from outside the browser
4. `POST /switchtab` → extension dequeues within 50ms via `chrome.tabs.update` + `chrome.windows.update`
5. Polls with chained 50ms timers (up to 1.5s) until a browser window is active, then shows toast

### Firefox Profile Cycling (`lib/firefox.ahk`)
Firefox is configured via `FIREFOX_EXE` and `FIREFOX_PROFILE_INI` globals in `lib/config.ahk`. At startup, `_InitFirefoxState()`:
- Parses `profiles.ini` via `ReadFirefoxProfilesInfo()` to build a `displayName → absPath` map
- Posts the profile name list to `POST /profiles` after a 2-second delay (Firefox starts slowly)

`CycleFirefoxProfile(profileName)`: same two-level HWND cache pattern as Chromium, using `"ahk_class MozillaWindowClass ahk_exe firefox.exe"`. Falls back to all visible Firefox windows when the server has no data for the profile. Only launches a new Firefox instance if no windows exist at all (avoids "Firefox is already running" error).

`FocusTabFirefox(profileName, urlPatterns, openUrl)`: same query/cycle pattern as `FocusTab`. When no matching tabs are found and Firefox is already running, POSTs `{profile, openUrl}` to `/switchtab` so the extension opens the URL via `chrome.tabs.create` — never runs `firefox.exe` while Firefox is open to avoid the "already running" IPC error. Only falls back to `Run(firefox.exe -P ...)` when no Firefox windows exist at all.

**Profile names**: use the `Name=` field from `profiles.ini` (visible at `about:profiles` in Firefox). This is what `_firefoxProfileDirCache` keys on and what the extension Options dropdown shows.

### BrowserExtension (`BrowserExtension/background.js`)
MV3 service worker with a dual role:
- **Push**: calls `POST /tabs` with current tab state on every tab event (`onCreated`, `onRemoved`, `onUpdated` title/URL change, `onFocusChanged`, etc.)
- **Pull**: polls `GET /switchtab?profile=` every 50ms; on a 200 response:
  - If `cmd.openUrl` is set: calls `chrome.tabs.create({ url })` (used by Firefox to avoid "already running" errors)
  - Otherwise: calls `chrome.tabs.update(tabId, { active: true })` and, if `chrome.windows` is available (Chrome only), `chrome.windows.update(windowId, { focused: true })`

**Keepalive**: Chrome suspends MV3 service workers between events, which would stop the 50ms poll. Prevented by `chrome.runtime.getPlatformInfo(() => setTimeout(keepAlive, 20000))` — a known workaround.

**URL normalization**: tabs are posted with URL truncated to `origin + first path segment` (e.g. `https://mail.google.com/mail` not the full URL). URL patterns in `FocusTab` must match this normalized form.

**Dual manifests**: `manifest.json` is for Chrome (includes `windows` permission); `manifest-firefox.json` is for Firefox (omits `windows` — Firefox MV3 rejects it, and `chrome.windows` is gated on `if (chrome.windows)` in background.js). The Firefox packaging script swaps in `manifest-firefox.json` before signing. Never merge the two manifests back into one.

**Options page**: profile dropdown auto-populated from `GET /profiles` on open; refresh button (↺) re-fetches. On save, if profile name changed, calls `DELETE /tabs?profile=<oldName>` to remove stale server-side tab state.

**Icons**: `BrowserExtension/icons/` — generated by `dev-scripts/generate-icons.ps1` (requires `System.Drawing`). Regenerate if icon design changes.

### AltTabSucks Server (`Server/AltTabSucksServer.ps1`)
CORS is restricted to `chrome-extension://` and `moz-extension://` origins. All non-OPTIONS requests require the `X-AltTabSucks-Token` header matching `token.txt`. `GET /switchtab` ignores requests from browser-page origins (present `Origin` that isn't an extension) to prevent simple-request queue drain attacks.

Endpoints:
- `POST /tabs` — store tab state for a profile (called by extension on every tab event); body capped at 1 MB
- `DELETE /tabs?profile=` — remove a profile's tab state (called by options page when profile name changes)
- `GET /tabs` — return all stored profile tab state as JSON
- `GET /activetitles?profile=` — newline-separated active tab titles per window
- `GET /findtab?profile=&url=` — `windowId|tabId` lines matching URL pattern (wildcard-escaped before `-like`); sorted micActive → audible → leftmost
- `POST /switchtab` — queue a tab-focus command; accepts `{profile, windowId, tabId}` or `{profile, openUrl}`; body capped at 4 KB
- `GET /switchtab?profile=` — dequeue pending command for a profile
- `POST /profiles` — AHK pushes browser profile display-name list at startup
- `GET /profiles` — extension Options page fetches to populate profile dropdown
- `GET /debugtabs` — full state dump (shown by `^!+l` overlay)

### Firefox Extension Packaging (`dev-scripts/package-firefox-extension.ps1`)
Packages and optionally signs the Firefox extension for sideloading:
- **Unsigned** (default): zips `BrowserExtension/` with `manifest-firefox.json` swapped in as `manifest.json`
- **Signed** (`-Sign`): stages a temp dir, runs `web-ext sign --channel unlisted` against AMO, auto-increments the patch version, renames output to `AltTabSucks-firefox.xpi`, writes version back to both manifests
- AMO credentials stored in `.amo-credentials` (gitignored); script prompts on first run
- Requires Node.js (script offers to install via `winget` if missing)
- Gecko extension ID: `alttabsucks@piratesailing.com`

### Game Automation (`lib/star-citizen.ahk`)
Uses `W_Pressed_Flag` as a coordination flag: `~w` sets it on keydown; looping hotkeys check it to allow user interruption by pressing `w`.

## AutoHotkey Resources

- AHK v2 docs: https://www.autohotkey.com/docs/v2/
- AHK v1 docs: https://www.autohotkey.com/docs/v1/
- Key notation: `^`=Ctrl, `!`=Alt, `+`=Shift, `#`=Win, `~`=pass-through
