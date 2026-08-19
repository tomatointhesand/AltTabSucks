# AltTabSucks Linux/KDE Porting Checklist

Target environment (verified on this machine): **KDE Plasma, Wayland session, `kwin_wayland`**,
`kglobalaccel` and `org.kde.kwin.Scripting` DBus services present. This is a KWin port, not a
generic wlroots/wlr-protocols port — the mechanisms below are KDE-specific and won't carry over
to Sway/Hyprland/etc. without rework.

## Housekeeping
- [ ] Remove or relocate `disable.continue_config.py` and `test_file.py` from repo root —
      leftovers from an unrelated Continue.dev experiment, not part of this project
- [ ] Decide server runtime: **Node.js** (an untracked `server.js` stub already exists but no
      Node/npm is installed on this machine yet) vs **Python** (already installed, and matches
      the repo's existing Linux-side tooling — `dev-scripts/*.sh`, `secret-bridge.sh` — better
      than Node does)

## Core Components
- [ ] Port `Server/AltTabSucksServer.ps1` to the chosen runtime, with **full endpoint parity**:
      `POST/GET /profiles`, `POST/DELETE/GET /tabs`, `GET /activetitles`, `GET /findtab`
      (wildcard-safe substring match + micActive→audible→leftmost sort), `POST/GET /switchtab`
      (including `splitTab`/`mergeTabs`/`openUrl` variants), `GET /debugtabs`. The existing
      `server.js` stub is missing `/debugtabs` and the `splitTab`/`mergeTabs` sort-order details —
      treat it as a starting point, not a finished port.
  - [ ] Same token-auth model: generate/read `Server/token.txt`, require
        `X-AltTabSucks-Token` on every non-OPTIONS request
  - [ ] Same CORS restriction: only `chrome-extension://*` / `moz-extension://*` origins get
        `Access-Control-Allow-*` headers; `GET /switchtab` must still reject requests carrying a
        non-extension `Origin` to prevent the queue-drain attack the PS1 comments describe
  - [ ] Body size caps preserved (1 MB for `/tabs`, 4 KB for `/switchtab`, 4 KB for `/profiles`)
- [ ] Replace AutoHotkey's role with a **KWin script** (see below) plus a small companion
      process for anything a KWin script can't do itself (spawning `secret-bridge.sh`, driving
      `ydotool`)
- [ ] Linux service management: `systemd --user` unit for the bridge server (an untracked
      `alttabsucks.service` stub exists — needs a real `ExecStart` path, `WantedBy=default.target`
      for a user unit rather than `multi-user.target`, and installation via `systemctl --user`)

## KDE/KWin Specifics (replaces the old "Wayland & KDE Specifics" section)
- [ ] **KWin scripting, not wlr-protocols.** Load a `.js` KWin script via
      `org.kde.kwin.Scripting`'s `loadScript`/`loadDeclarativeScript` DBus methods (confirmed
      available: `qdbus6 org.kde.KWin /Scripting`). Package it properly as a `.kwinscript` via
      `kpackagetool6` for anything beyond dev iteration.
- [ ] **Window enumeration/activation**: use the script's `workspace` global
      (`workspace.windowList()`, `client.frameGeometry`, `workspace.activeWindow`, activate/
      minimize calls) — this is the direct equivalent of `lib/window-management.ahk` and
      `lib/window-switcher-core.ahk`'s `WinGetList`/`WinActivate`/`WinMinimize` calls.
- [ ] **Global hotkeys**: use the script's `registerShortcut(name, text, keySequence, callback)`,
      which registers through `kglobalaccel` (confirmed running) — this is the correct way to
      claim Meta/Super combos under Wayland; raw input grabs from a userspace process are not
      possible and are not the right approach.
- [ ] **Bridge to the tab-focus server from inside the script**: KWin's JS engine exposes a
      global `XMLHttpRequest`, so the script can call `/findtab`, `/switchtab`, etc. directly,
      mirroring what AHK's `WinHttp` calls do today — no separate hotkey daemon needed for the
      window-focus + tab-focus hotkeys.
- [ ] Window title/PID → process name resolution inside the script (KWin's `client.resourceClass`
      / `client.resourceName` replace AHK's `WinGetProcessName`)
- [ ] Titlebar-color sampling for the toast overlay (`lib/toast.ahk`'s per-app color) has no
      direct KWin equivalent yet — needs its own investigation (possibly read from the app's
      `.desktop`/icon theme, or drop the color-sampling feature for v1)

## Key Features (Linux mapping)
- [ ] App window cycling/toggle (`ManageAppWindows`) → KWin script using `workspace` API
- [ ] Window switcher (typeahead Alt+Tab replacement) → KWin script UI. Note: the AHK version
      draws its own GUI (edit box, DWM thumbnail previews via `DwmRegisterThumbnail`); KWin has
      no direct DWM-thumbnail equivalent — likely needs a QML overlay (KWin scripts can load QML
      components) using compositor-side thumbnails via `kwin` effects, or a much simpler
      text-only picker for v1
- [ ] Browser profile cycling / tab focus (`lib/chromium.ahk`, `lib/firefox.ahk`) → logic ports
      almost as-is into the KWin script or companion process, since it's mostly HTTP calls +
      window activation by class/exe match (`ahk_class Chrome_WidgetWin_1` →
      match on `client.resourceClass` for the browser's Linux window class, e.g. `google-chrome`,
      `brave-browser`, `firefox`)
- [ ] Profile management: unaffected by the OS port — this logic lives entirely in the bridge
      server + browser extension already

## Browser Integration
- [ ] `BrowserExtension/` itself needs **no code changes** — it already only talks to
      `localhost:9876` over HTTP and is loaded via the browser's own "load unpacked"/`.xpi`
      install flow, same on Linux as Windows
- [ ] Update install docs (README) for Linux browser installs: extensions page paths are the same
      URLs (`brave://extensions`, `about:addons`), no change needed there either
- [ ] Chromium/Firefox profile discovery (`_InitChromiumState`, `ReadFirefoxProfilesInfo`) needs
      Linux path equivalents: `~/.config/google-chrome/`, `~/.config/BraveSoftware/...`,
      `~/.mozilla/firefox/profiles.ini` instead of `%LOCALAPPDATA%`/`%APPDATA%`

## Secrets Workflow
- [ ] `lib/secret-bridge.sh` → `gopass` is already bash and largely portable as-is; verify it
      doesn't shell out to any Windows-only tool
- [ ] The AHK side (`lib/secrets.ahk`'s in-memory cache + lock-on-workstation-lock behavior) needs
      a Linux replacement process — likely the companion daemon above, listening for KDE's
      screen-lock DBus signal (`org.freedesktop.ScreenSaver` / `org.kde.screensaver`) instead of
      AHK's lock-detection
- [ ] **Typing the secret** (AHK's `Send`) has no Wayland equivalent from a regular process —
      needs `ydotool` + `ydotoold` (uinput-based injection, requires the `input` group or a
      running `ydotoold` daemon). Not installed on this machine yet; add to Dependencies.
- [ ] `dev-scripts/manage-secrets.sh` menu is already bash — should work unmodified on Linux

## Dependencies (concrete, installable)
- [ ] `ydotool` + `ydotoold` (Wayland input injection, for the secrets-typing hotkey)
- [ ] Node.js+npm **or** nothing extra if Python is chosen (see Housekeeping decision above)
- [ ] `kpackagetool6` (packaging the KWin script properly, already present via
      `kwin_wayland`/Plasma install)
- [ ] Linux installer script (bash) replacing `installer.ps1`: installs the KWin script
      (`kpackagetool6 -t KWin/Script -i ...`), installs/enables the systemd `--user` service,
      writes `Server/token.txt`

## Infrastructure
- [ ] ~~Docker containers~~ — dropped: this talks to the host compositor and browser profile
      dirs directly; containerizing it fights the design
- [ ] ~~CI/CD for Linux builds~~ — premature until there's a working port to build; revisit once
      Phase 1–2 below are functional
- [ ] Linux setup docs (README section, mirroring the existing Windows Quick Start)

## Testing
- [ ] Manual verification only for now (KWin scripting + hotkeys aren't meaningfully unit-testable
      without a running compositor); scope automated tests to the bridge server's HTTP endpoints
      once ported
- [ ] Integration test: extension ↔ server ↔ KWin script round trip for one hotkey (tab focus)
      before building out the rest
- [ ] User acceptance testing on this machine (KDE/Wayland) before considering other DEs

## Implementation Phases

### Phase 1: Bridge Server
- [ ] Decide runtime (Node vs Python — see Housekeeping)
- [ ] Full endpoint-parity port of `AltTabSucksServer.ps1` (see Core Components above)
- [ ] `systemd --user` unit + basic install script
- [ ] Verify `BrowserExtension/` talks to it unmodified (load unpacked, confirm `/tabs` POSTs land)

### Phase 2: Window Management + Hotkeys (KWin Script)
- [ ] Minimal KWin script: one `registerShortcut` call that lists/activates windows via
      `workspace`, proving the DBus `loadScript` → hotkey → window-activate path end to end
- [ ] Port `ManageAppWindows` cycle/toggle logic
- [ ] Port `FocusTab`/`CycleChromiumProfile` logic (HTTP calls via the script's `XMLHttpRequest`
      + `workspace` activation by `resourceClass`)
- [ ] Port Firefox equivalents

### Phase 3: Secrets
- [ ] `ydotool`/`ydotoold` setup
- [ ] Companion daemon for lock-detection + secret cache + typing
- [ ] Wire up the secrets-manager hotkey

### Phase 4: Polish / Parity
- [ ] Window switcher (typeahead + previews) — scope down for v1 (see Key Features note on DWM
      thumbnails)
- [ ] Toast overlay + titlebar color sampling
- [ ] Settings persistence (`lib/settings.ahk` equivalent — plain config file is fine, no GUI
      required for v1)
- [ ] Linux README section, install script polish
