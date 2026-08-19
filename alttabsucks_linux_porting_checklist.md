# AltTabSucks Linux/KDE Porting Checklist

Target environment (verified on this machine): **KDE Plasma, Wayland session, `kwin_wayland`**,
`kglobalaccel` and `org.kde.kwin.Scripting` DBus services present. This is a KWin port, not a
generic wlroots/wlr-protocols port — the mechanisms below are KDE-specific and won't carry over
to Sway/Hyprland/etc. without rework.

Work proceeds in the phases below, each one built and (where testable) verified before the next
starts. Status: **Phase 1 done. Phase 2 (KWin script) up next.**

## Implementation Phases

### Phase 1: Bridge Server — ✅ done
- [x] Runtime decided: **Python** (stdlib only) — already installed on this machine, matches the
      repo's existing bash tooling; no Node/npm dependency added
- [x] Full endpoint-parity port of `AltTabSucksServer.ps1` → `linux/server/alttabsucks_server.py`:
      `POST/GET /profiles`, `POST/DELETE/GET /tabs`, `GET /activetitles`, `GET /findtab`
      (substring match + micActive→audible→leftmost sort), `POST/GET /switchtab` (incl.
      `splitTab`/`mergeTabs`/`openUrl`), `GET /debugtabs` — same token auth, same CORS
      restriction to extension origins (incl. the queue-drain-attack guard on `GET /switchtab`),
      same body-size caps (1 MB `/tabs`, 4 KB `/profiles` and `/switchtab`)
- [x] `linux/systemd/alttabsucks-server.service` (`systemd --user` unit)
- [x] 30-test stdlib `unittest` suite (`linux/server/tests/`) — run with
      `python3 -m unittest discover -s linux/server/tests`
- [x] Bug found by the suite and fixed: any early-return error response (403/413/404) that
      hadn't read the request body left a keep-alive connection desynced; fixed with a bounded
      drain helper called before every such response
- [x] Housekeeping: removed the stray `alttabsucks.service`/`server.js` stubs (superseded by the
      above) and the unrelated `disable.continue_config.py`/`test_file.py` leftovers from the
      repo root
- [ ] Not yet done: manually verified against a **real** `BrowserExtension/` load-unpacked
      (only exercised via curl/unittest so far) — worth doing once Phase 2 gives us a hotkey to
      trigger it end to end, rather than as a standalone step

### Phase 2: Window Management + Hotkeys (KWin Script) — up next
- [ ] Minimal KWin script: one `registerShortcut` call that lists/activates windows via
      `workspace`, proving the DBus `loadScript` → hotkey → window-activate path end to end
- [ ] Port `ManageAppWindows` cycle/toggle logic
- [ ] Port `FocusTab`/`CycleChromiumProfile` logic (HTTP calls via the script's `XMLHttpRequest`
      + `workspace` activation by `resourceClass`)
- [ ] Port Firefox equivalents
- [ ] End-to-end check against the real `BrowserExtension/` (carried over from Phase 1) once a
      tab-focus hotkey exists to drive it

### Phase 3: Secrets — not started
- [ ] `ydotool`/`ydotoold` setup
- [ ] Companion daemon for lock-detection + secret cache + typing
- [ ] Wire up the secrets-manager hotkey

### Phase 4: Polish / Parity — not started
- [ ] Window switcher (typeahead + previews) — scope down for v1 (see Key Features note on DWM
      thumbnails)
- [ ] Toast overlay + titlebar color sampling
- [ ] Settings persistence (`lib/settings.ahk` equivalent — plain config file is fine, no GUI
      required for v1)
- [ ] Linux README section, install script polish

---

## Reference: per-area detail

The phases above are the source of truth for sequencing; this section is the supporting detail
for work not yet started, kept close to the phase list rather than duplicated across both.

### KDE/KWin Specifics (Phase 2)
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
      `.desktop`/icon theme, or drop the color-sampling feature for v1) — Phase 4

### Key Features mapping (Phase 2)
- [ ] App window cycling/toggle (`ManageAppWindows`) → KWin script using `workspace` API
- [ ] Window switcher (typeahead Alt+Tab replacement) → KWin script UI. Note: the AHK version
      draws its own GUI (edit box, DWM thumbnail previews via `DwmRegisterThumbnail`); KWin has
      no direct DWM-thumbnail equivalent — likely needs a QML overlay (KWin scripts can load QML
      components) using compositor-side thumbnails via `kwin` effects, or a much simpler
      text-only picker for v1 (Phase 4)
- [ ] Browser profile cycling / tab focus (`lib/chromium.ahk`, `lib/firefox.ahk`) → logic ports
      almost as-is into the KWin script, since it's mostly HTTP calls + window activation by
      class/exe match (`ahk_class Chrome_WidgetWin_1` → match on `client.resourceClass` for the
      browser's Linux window class, e.g. `google-chrome`, `brave-browser`, `firefox`)
- [x] Profile management: unaffected by the OS port — this logic lives entirely in the bridge
      server + browser extension already (covered by Phase 1)

### Browser Integration (mostly no-op, verify in Phase 2)
- [x] `BrowserExtension/` itself needs **no code changes** — it already only talks to
      `localhost:9876` over HTTP and is loaded via the browser's own "load unpacked"/`.xpi`
      install flow, same on Linux as Windows
- [ ] Update install docs (README) for Linux browser installs: extensions page paths are the same
      URLs (`brave://extensions`, `about:addons`), no change needed there either (Phase 4)
- [ ] Chromium/Firefox profile discovery (`_InitChromiumState`, `ReadFirefoxProfilesInfo`) needs
      Linux path equivalents: `~/.config/google-chrome/`, `~/.config/BraveSoftware/...`,
      `~/.mozilla/firefox/profiles.ini` instead of `%LOCALAPPDATA%`/`%APPDATA%` (Phase 2)

### Secrets Workflow (Phase 3)
- [ ] `lib/secret-bridge.sh` → `gopass` is already bash and largely portable as-is; verify it
      doesn't shell out to any Windows-only tool
- [ ] The AHK side (`lib/secrets.ahk`'s in-memory cache + lock-on-workstation-lock behavior) needs
      a Linux replacement process — likely the companion daemon below, listening for KDE's
      screen-lock DBus signal (`org.freedesktop.ScreenSaver` / `org.kde.screensaver`) instead of
      AHK's lock-detection
- [ ] **Typing the secret** (AHK's `Send`) has no Wayland equivalent from a regular process —
      needs `ydotool` + `ydotoold` (uinput-based injection, requires the `input` group or a
      running `ydotoold` daemon). Not installed on this machine yet.
- [ ] `dev-scripts/manage-secrets.sh` menu is already bash — should work unmodified on Linux

### Dependencies still to install (Phase 3 unless noted)
- [ ] `ydotool` + `ydotoold` (Wayland input injection, for the secrets-typing hotkey)
- [ ] `kpackagetool6` for packaging the KWin script properly (Phase 2; already present via
      `kwin_wayland`/Plasma install, just needs to be invoked)
- [ ] Linux installer script (bash) replacing `installer.ps1`: installs the KWin script
      (`kpackagetool6 -t KWin/Script -i ...`), installs/enables the systemd `--user` service,
      writes `Server/token.txt` (Phase 4)

### Infrastructure
- [ ] ~~Docker containers~~ — dropped: this talks to the host compositor and browser profile
      dirs directly; containerizing it fights the design
- [ ] ~~CI/CD for Linux builds~~ — premature until there's more of a working port to build;
      revisit after Phase 2
- [ ] Linux setup docs (README section, mirroring the existing Windows Quick Start) — Phase 4

### Testing
- [x] Bridge server: automated (`linux/server/tests/`, 30 tests, stdlib `unittest`)
- [ ] KWin script: manual verification only (not meaningfully unit-testable without a running
      compositor) — Phase 2
- [ ] Integration test: extension ↔ server ↔ KWin script round trip for one hotkey (tab focus),
      once Phase 2's minimal script exists
- [ ] User acceptance testing on this machine (KDE/Wayland) before considering other DEs — Phase 4
