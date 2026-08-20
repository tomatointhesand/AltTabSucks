# AltTabSucks Linux/KDE Porting Checklist

Target environment (verified on this machine): **KDE Plasma, Wayland session, `kwin_wayland`**,
`kglobalaccel` and `org.kde.kwin.Scripting` DBus services present. This is a KWin port, not a
generic wlroots/wlr-protocols port — the mechanisms below are KDE-specific and won't carry over
to Sway/Hyprland/etc. without rework.

Work proceeds in the phases below, each one built and (where testable) verified before the next
starts. Status: **Phase 1 done. Phase 2 in progress — window management, D-Bus bridge, and
CycleChromiumProfile/FocusTab all working for Chromium; Firefox equivalents + a check against the
real BrowserExtension still remain.**

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
- [x] `linux/systemd/alttabsucks-server.service` (`systemd --user` unit) — installed and enabled
      on this machine (`~/.config/systemd/user/`, `systemctl --user enable --now`), actually
      running persistently now rather than just existing as a file in the repo
- [x] 38-test stdlib `unittest` suite (`linux/server/tests/`) — run with
      `python3 -m unittest discover -s linux/server/tests`
- [x] Bug found by the suite and fixed: any early-return error response (403/413/404) that
      hadn't read the request body left a keep-alive connection desynced; fixed with a bounded
      drain helper called before every such response
- [x] Housekeeping: removed the stray `alttabsucks.service`/`server.js` stubs (superseded by the
      above) and the unrelated `disable.continue_config.py`/`test_file.py` leftovers from the
      repo root
- [x] **Chromium profile self-discovery** (`linux/server/profile_discovery.py` +
      `linux/server/config.py`, gitignored, from `config.template.py`): fixes
      `BrowserExtension/`'s Options page showing no profiles — root cause was two-fold, no server
      was running at all, and even running, nothing populated `GET /profiles` since that's
      normally AHK's `_InitChromiumState()` pushing what it found, and there's no Linux
      equivalent doing that yet. Server now discovers profiles itself at startup by parsing
      "Local State" (real JSON — simpler than AHK's regex approach). Verified live against this
      machine's real Brave install (`Personal`), not just fixture data. See commit `ced7a50`.
- [x] Manually verified against a **real, running server** (curl/unittest plus the live Brave
      profile-discovery check above); verifying against a **loaded `BrowserExtension/`** itself
      (not just what it calls) is still open — see Phase 2's equivalent item

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
- [x] **D-Bus bridge decided and built**: KWin's plain-JS scripting sandbox has **no
      `XMLHttpRequest`** (confirmed empirically — corrected the earlier assumption in the KDE/KWin
      Specifics section below) — only `callDBus`/`readConfig`, no network, no process spawn, no
      file read. Chose adding a D-Bus-facing interface to the bridge server (over the alternative
      of splitting hotkey registration across two mechanisms) — see `linux/server/dbus_bridge.py`
      (`com.github.tomatointhesand.AltTabSucks`, exposing `FindTab`/`GetActiveTitles`/
      `GetProfiles`/`QueueSwitchTab`/`QueueSwitchOpenUrl`). Uses `dbus-python` + `PyGObject`
      (`python-dbus`/`python-gobject` on Arch — system packages, not pip; already present on this
      KDE install). Verified end to end including from an actual loaded KWin script's `callDBus`
      — see commit `fc5c120`. Same escape hatch (not yet used) would cover the still-unimplemented
      "launch app when no windows exist" case in `manageAppWindows`.
- [x] Ported `FocusTab`/`CycleChromiumProfile` → `cycleChromiumProfile`/`focusTab` in `main.js`,
      using `workspace` for window activation and the D-Bus bridge for `GetActiveTitles`/
      `FindTab`/`QueueSwitchTab`/`QueueSwitchOpenUrl`. Structured as callback chains, not
      straight-line code — `callDBus` is async-only, and this engine has no `setTimeout` and
      can't parse `async function` at all (confirmed empirically; `QTimer` is the delay
      primitive, unused so far since nothing here needed one yet). Verified end to end against
      real Brave windows with seeded server data: cycling between matched windows and back,
      the no-match fallback (opens a new tab in an existing window), the match-found path
      (`FindTab` → `QueueSwitchTab` → dequeued via the real `GET /switchtab` path), and
      multi-match cycling with wraparound — all through the actual installed `kpackagetool6`
      package, not just an ad-hoc dev-loaded copy. See commit `b586ec3` for the noted
      simplifications (no HWND-style stable sort, no `_ServerHasAnyTabData()` distinction, no
      duplicate-tab-open cooldown, launch-when-no-window-exists still stubbed like
      `manageAppWindows`') and a real gotcha worth remembering: `kpackagetool6 --upgrade` +
      `qdbus6 ... reconfigure` does **not** force an already-loaded script to reload its JS —
      needs an explicit `unloadScript` first, or you'll silently keep testing stale code.
- [ ] Port Firefox equivalents (`lib/firefox.ahk`'s `CycleFirefoxProfile`/`FocusTabFirefox`)
- [ ] End-to-end check against the real `BrowserExtension/` (carried over from Phase 1) — still
      not done; so far only verified against seeded server data, never a real loaded extension
      actually driving `chrome.tabs.update`/`chrome.windows.update`
- [ ] Process-spawn escape hatch for the three now-stubbed "launch when nothing's open" cases
      (`manageAppWindows`, `cycleChromiumProfile`, `focusTab`'s full-launch tier) — needs a new
      `dbus_bridge.py` method; not started

### Phase 3: Polish / Parity — in progress
- [x] **`installer.sh`** (repo root, mirrors `installer.ps1`'s `install|uninstall|status|
      start|stop` contract) — done ahead of the rest of Phase 3 since it was needed to actually
      deploy the Phase 1/2 work for real use rather than leaving it as manually-run test
      commands. Much smaller than `installer.ps1`: no elevation/UAC needed at all (`systemd
      --user` and `kpackagetool6` are both ordinary per-user operations), no scheduled-task API,
      no separate "launch the hotkey layer at login" step (the KWin script already runs inside
      the always-running compositor once installed). Tested the full cycle live — install
      (idempotent against an already-installed service + already-loaded KWin script), status,
      stop, start, uninstall (confirmed config.py/token.txt survive, matching `installer.ps1`
      leaving token.txt alone), reinstall. See commit `e6aacf5` for a real bug this surfaced:
      `enable --now` on an already-running service doesn't restart it, so a naive re-run would
      silently keep serving stale code.
- [x] **Hotkey definition management** (`hotkeys.js`/`hotkeys.template.js`, mirrors
      `lib/app-hotkeys.ahk`) — also done ahead of the rest of Phase 3, for the same "needed to
      actually use this" reason as `installer.sh`. Couldn't mirror AHK's `#Include` directly
      since the KWin sandbox has no file-read primitive; the split happens at *install* time
      instead — `installer.sh` concatenates the tracked `main.js` (library only, no
      `registerShortcut` calls anymore) with gitignored `hotkeys.js` (seeded from
      `hotkeys.template.js` on first install) into a staged copy before installing it. Verified
      live end to end with a real binding needing no placeholder edits ("Toggle File Manager").
      See commit `efa714b`.
  - [ ] **Follow-up, not done**: `dev-scripts/make-template.sh`/the pre-commit hook don't know
        about `hotkeys.js` yet — unlike `app-hotkeys.ahk`, editing your real `hotkeys.js` won't
        auto-regenerate `hotkeys.template.js` with values redacted on commit. `hotkeys.template.js`
        is hand-written for now; extending the sanitizer to also handle `hotkeys.js`'s (different,
        JS-syntax) URL/profile-name patterns is real but modest follow-up work.
- [ ] Toast overlay + titlebar color sampling
- [ ] Settings persistence (`lib/settings.ahk` equivalent — plain config file is fine, no GUI
      required for v1)
- [ ] Linux README section (installer.sh usage still needs documenting there)

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
      and `readConfig` are available alongside `workspace`/`registerShortcut`. Addressed via the
      `linux/server/dbus_bridge.py` D-Bus bridge — see Phase 2 above.
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
- [x] Browser profile cycling / tab focus, Chromium side (`lib/chromium.ahk`) → done, see Phase 2
      above. Matching by `client.resourceClass` for the browser's Linux window class (e.g.
      `brave-browser`) confirmed working as expected.
- [ ] Firefox side (`lib/firefox.ahk`) — not started
- [x] Profile management: unaffected by the OS port — this logic lives entirely in the bridge
      server + browser extension already (covered by Phase 1)

### Browser Integration (mostly no-op, verify in Phase 2)
- [x] `BrowserExtension/` itself needs **no code changes** — it already only talks to
      `localhost:9876` over HTTP and is loaded via the browser's own "load unpacked"/`.xpi`
      install flow, same on Linux as Windows
- [ ] Update install docs (README) for Linux browser installs: extensions page paths are the same
      URLs (`brave://extensions`, `about:addons`), no change needed there either (Phase 3)
- [x] Chromium profile discovery (`_InitChromiumState`'s equivalent) — done server-side, see
      Phase 1 above (`linux/server/profile_discovery.py`), not in the KWin script
- [ ] Firefox profile discovery (`ReadFirefoxProfilesInfo`'s equivalent, `~/.mozilla/firefox/
      profiles.ini` instead of `%APPDATA%`) — not started; `profile_discovery.py` is the template
      to follow (server-side discovery, not pushed by a hotkey-layer process) (Phase 2)

### Dependencies still to install
- [x] `kpackagetool6` for packaging the KWin script — already present via `kwin_wayland`/Plasma
      install, no separate install step needed; used in Phase 2 (`linux/kwin/alttabsucks/`)
- [x] `python-dbus` + `python-gobject` (Arch package names) for `linux/server/dbus_bridge.py` —
      system packages, not pip; already present on this KDE Plasma install (pulled in
      transitively by Plasma itself). `installer.sh` checks for these explicitly (`check_deps`)
      rather than assume every install has them, since `_start_dbus_bridge()`'s error message can
      only help someone who's already watching the server's stdout.
- [x] `installer.sh` (repo root) — done, see Phase 3 above. Installs the KWin script, installs/
      enables the systemd `--user` service, checks for `python-dbus`/`python-gobject`, and
      auto-generates `Server/token.txt` indirectly (the server itself still creates it on first
      run — the installer just makes sure that first run actually happens and prints it).

### Infrastructure
- [ ] ~~Docker containers~~ — dropped: this talks to the host compositor and browser profile
      dirs directly; containerizing it fights the design
- [ ] ~~CI/CD for Linux builds~~ — premature until there's more of a working port to build;
      revisit after Phase 2
- [ ] Linux setup docs (README section, mirroring the existing Windows Quick Start) — Phase 3

### Testing
- [x] Bridge server: automated (`linux/server/tests/`, 30 tests, stdlib `unittest`) for the HTTP
      side; D-Bus bridge verified manually (constructing `AppState`/`make_handler` directly, as
      the tests do, never touches D-Bus — see `dbus_bridge.py`'s module docstring)
- [x] KWin script: manual verification only (not meaningfully unit-testable without a running
      compositor), as expected — `ManageAppWindows` cycle/toggle, the D-Bus bridge (HTTP↔D-Bus
      shared state, `callDBus` from an actual loaded KWin script), and `cycleChromiumProfile`/
      `focusTab` against real windows with seeded data, all verified this way (see Phase 2 above)
- [ ] Integration test: extension ↔ server ↔ KWin script round trip for one hotkey (tab focus)
      with a **real loaded `BrowserExtension/`** — still open; everything so far was verified
      against seeded server data standing in for the extension, never the extension itself
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
