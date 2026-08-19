# AltTabSucks Linux/KDE Porting Checklist

Target environment (verified on this machine): **KDE Plasma, Wayland session, `kwin_wayland`**,
`kglobalaccel` and `org.kde.kwin.Scripting` DBus services present. This is a KWin port, not a
generic wlroots/wlr-protocols port — the mechanisms below are KDE-specific and won't carry over
to Sway/Hyprland/etc. without rework.

Work proceeds in the phases below, each one built and (where testable) verified before the next
starts. Status: **Phase 1 done. Phase 2 in progress — window management working, tab-focus
bridging still needs a design decision (see below).**

**Deliberately out of scope for now** (see Deferred section at the bottom): the **secrets
manager** and the **window switcher**. Both are explicitly deferred, not forgotten — do not pick
either back up without checking in first, since the secrets manager in particular is planned to
be approached differently than the Windows version was.

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

### Phase 2: Window Management + Hotkeys (KWin Script) — in progress
- [x] Minimal KWin script proven end to end: `linux/kwin/alttabsucks/` (installed via
      `kpackagetool6 --type=KWin/Script -i`, enabled via `kwriteconfig6`/`qdbus6 reconfigure`) —
      `registerShortcut` → real `kglobalaccel` registration → `kglobalaccel invokeShortcut` →
      callback fires → `workspace` mutation, verified via journal + before/after window-state
      inspection, not just "it loaded without error"
- [x] Ported `ManageAppWindows` cycle/toggle logic → `findAppWindows`/`activateWindow`/
      `manageAppWindows` in `main.js`. Manually verified against two independent, fully-controlled
      test windows (spawned instances, not ambient ones — ambient windows turned out to be an
      unreliable test fixture, see commit `2e59a2e`): cycle wraps correctly, toggle
      minimizes-if-active / restores-and-activates-if-not, and `workspace.activeWindow =`
      assignment auto-restores a minimized window (matches AHK's `WinActivate`).
- [ ] **Open design decision before continuing**: `FocusTab`/`CycleChromiumProfile` need the
      script to call the bridge server, but KWin's plain-JS scripting sandbox has **no
      `XMLHttpRequest`** (confirmed empirically — corrects the assumption in the KDE/KWin
      Specifics section below) — only `callDBus`/`readConfig` are available, no network, no
      process spawn, no file read. The bridge server needs a DBus-facing interface for the script
      to call into via `callDBus`, which likely means adding a small D-Bus service to
      `linux/server/alttabsucks_server.py` (no dbus module in Python's stdlib — would need a
      third-party pure-Python DBus library, e.g. `jeepney`; first new non-stdlib dependency in
      this port). Same escape hatch would cover the still-unimplemented "launch app when no
      windows exist" case in `manageAppWindows` too. **Don't start this without discussing the
      dependency first.**
- [ ] Port `FocusTab`/`CycleChromiumProfile` logic once the above is decided
- [ ] Port Firefox equivalents
- [ ] End-to-end check against the real `BrowserExtension/` (carried over from Phase 1) once a
      tab-focus hotkey exists to drive it

### Phase 3: Polish / Parity — not started
- [ ] Toast overlay + titlebar color sampling
- [ ] Settings persistence (`lib/settings.ahk` equivalent — plain config file is fine, no GUI
      required for v1)
- [ ] Linux README section, install script polish

---

## Reference: per-area detail

The phases above are the source of truth for sequencing; this section is the supporting detail
for work not yet started, kept close to the phase list rather than duplicated across both.

### KDE/KWin Specifics (Phase 2)
- [x] **KWin scripting, not wlr-protocols.** Load a `.js` KWin script via `org.kde.kwin.Scripting`'s
      `loadScript`/`loadDeclarativeScript` DBus methods for dev iteration; package properly as a
      `.kwinscript` (`metadata.json` + `contents/code/main.js`) and install via
      `kpackagetool6 --type=KWin/Script -i <dir>`, enable via
      `kwriteconfig6 --file kwinrc --group Plugins --key <id>Enabled true` +
      `qdbus6 org.kde.KWin /KWin reconfigure`. Both paths proven working (`linux/kwin/alttabsucks/`).
- [x] **Window enumeration/activation**: `workspace.stackingOrder` (array of Window objects,
      z-ordered) + `workspace.activeWindow` (read-write — assigning it activates and, confirmed
      empirically, auto-restores a minimized window). `Window.normalWindow` + `!Window.transient`
      is the equivalent of AHK's WS_VISIBLE+unowned filter; `Window.minimized` is directly
      read-write. See `linux/kwin/alttabsucks/contents/code/main.js`.
- [x] **Global hotkeys**: `registerShortcut(title, text, keySequence, callback)` registers through
      `kglobalaccel` (confirmed: shows up under `qdbus6 org.kde.kglobalaccel /component/kwin`,
      and is invokable there via `invokeShortcut(name)` — useful for scripted verification without
      physically pressing keys). This is the correct way to claim Meta/Super combos under Wayland.
      To fully deregister a shortcut later (e.g. cleaning up dev/test bindings), unloading the
      script isn't enough — kglobalaccel remembers shortcut names across unloads; use
      `qdbus6 org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.unregister kwin "<name>"`.
- [x] **Correction from planning**: KWin's plain `"javascript"` scripting sandbox has **no
      `XMLHttpRequest`, no process spawning, no file reads** — confirmed empirically, contradicting
      earlier research (which likely described a different/older scripting mode). Only `callDBus`
      and `readConfig` are available alongside `workspace`/`registerShortcut`. This blocks the
      tab-focus bridge design — see the open item in Phase 2 above.
- [x] Window process identification inside the script: `Window.resourceClass`/`.resourceName`
      replace AHK's `WinGetProcessName`. Confirmed empirically these are **not** always the bare
      exe name — KDE apps use reversed-domain style (`org.kde.kate`, `org.kde.dolphin`,
      `org.kde.kwrite`) while others use the bare name (`brave-browser`, `code-oss`). Any
      per-app hotkey config (the eventual Linux equivalent of `app-hotkeys.ahk`) needs the actual
      `resourceClass` looked up per app, not assumed from the binary name.
- [ ] Titlebar-color sampling for the toast overlay (`lib/toast.ahk`'s per-app color) has no
      direct KWin equivalent yet — needs its own investigation (possibly read from the app's
      `.desktop`/icon theme, or drop the color-sampling feature for v1) — Phase 3

### Key Features mapping (Phase 2)
- [x] App window cycling/toggle (`ManageAppWindows`) → KWin script using `workspace` API
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
      URLs (`brave://extensions`, `about:addons`), no change needed there either (Phase 3)
- [ ] Chromium/Firefox profile discovery (`_InitChromiumState`, `ReadFirefoxProfilesInfo`) needs
      Linux path equivalents: `~/.config/google-chrome/`, `~/.config/BraveSoftware/...`,
      `~/.mozilla/firefox/profiles.ini` instead of `%LOCALAPPDATA%`/`%APPDATA%` (Phase 2)

### Dependencies still to install
- [ ] `kpackagetool6` for packaging the KWin script properly (Phase 2; already present via
      `kwin_wayland`/Plasma install, just needs to be invoked)
- [ ] Linux installer script (bash) replacing `installer.ps1`: installs the KWin script
      (`kpackagetool6 -t KWin/Script -i ...`), installs/enables the systemd `--user` service,
      writes `Server/token.txt` (Phase 3)

### Infrastructure
- [ ] ~~Docker containers~~ — dropped: this talks to the host compositor and browser profile
      dirs directly; containerizing it fights the design
- [ ] ~~CI/CD for Linux builds~~ — premature until there's more of a working port to build;
      revisit after Phase 2
- [ ] Linux setup docs (README section, mirroring the existing Windows Quick Start) — Phase 3

### Testing
- [x] Bridge server: automated (`linux/server/tests/`, 30 tests, stdlib `unittest`)
- [x] KWin script: manual verification only (not meaningfully unit-testable without a running
      compositor), as expected — `ManageAppWindows` cycle/toggle verified this way against real
      windows (see Phase 2 above)
- [ ] Integration test: extension ↔ server ↔ KWin script round trip for one hotkey (tab focus),
      blocked on the callDBus bridge design decision (Phase 2)
- [ ] User acceptance testing on this machine (KDE/Wayland) before considering other DEs — Phase 3

---

## Deferred (not part of the active phases)

### Secrets manager — deferred, revisit with a different approach
Explicitly **not** being ported as designed. When this comes back, it'll be a different
mechanism, not a straight AHK→Linux translation. Keeping the investigation notes below for
whenever that redesign discussion happens, but none of this should be started without that
discussion first:
- `lib/secret-bridge.sh` → `gopass` is already bash and largely portable as-is
- The AHK side (`lib/secrets.ahk`'s in-memory cache + lock-on-workstation-lock behavior) would
  need a Linux replacement process — e.g. a companion daemon listening for KDE's screen-lock
  DBus signal (`org.freedesktop.ScreenSaver` / `org.kde.screensaver`)
- **Typing the secret** (AHK's `Send`) has no Wayland equivalent from a regular process — would
  need `ydotool` + `ydotoold` (uinput-based injection, requires the `input` group or a running
  `ydotoold` daemon)
- `dev-scripts/manage-secrets.sh` menu is already bash — should work unmodified whenever this
  picks back up

### Window switcher — deferred to a later time
Typeahead Alt+Tab replacement (`lib/window-switcher*.ahk`). Not part of Phase 2's window
management work (which only covers `ManageAppWindows` cycle/toggle) or Phase 3. Note for
whenever it does get picked up: the AHK version draws its own GUI (edit box, DWM thumbnail
previews via `DwmRegisterThumbnail`); KWin has no direct DWM-thumbnail equivalent — likely needs
a QML overlay (KWin scripts can load QML components) using compositor-side thumbnails via `kwin`
effects, or a much simpler text-only picker to start.
