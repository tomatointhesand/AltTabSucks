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
- [x] 60-test stdlib `unittest` suite (`linux/server/tests/`) — run with
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
- [x] **Real production hang found and fixed — two rounds, second one was the actual fix**:
      surfaced by the user's real browser failing to load `/hotkeys-ui`, the first time this
      server had run persistently under real sustained extension traffic (every prior test this
      session used short-lived instances).
      - **Round 1** (commit `3d7dbb2`): diagnosed live via `/proc/<pid>/task/*/wchan` (main thread
        stuck in `wait_woken`, an unbounded blocking read — `Handler.timeout` was never set, so
        the request-line read inside `http.server`'s own `parse_request()`, and this file's own
        `_read_body`/`_drain_unread_body`, all waited *forever* if a client ever stalled
        mid-request). Since the server was deliberately single-threaded, one stall blocked every
        other client permanently. Fixed with `Handler.timeout = 10` — confirmed via the actual
        stdlib source that `handle_one_request()` already wraps request handling in a
        `try/except TimeoutError` that closes just that connection, no other change needed.
      - **Round 2** (commit `bc1688b`): redeployed, and `wchan` now showed a *bounded* `poll()` wait
        — correct — but the symptom didn't actually go away: `ss` showed a steady 5+ connections
        with real, non-trivial payloads (473 bytes each) queued behind whichever one the server
        was on, and it never caught up faster than new problematic connections arrived. A single
        per-connection timeout doesn't help when the *rate* of stalls exceeds the rate of
        recovery — each stall is individually bounded, but they queue serially forever. Root
        cause was the original Phase 1 design assumption itself ("one browser extension polling
        every 50ms, no concurrency to gain") — empirically false in this exact investigation (see
        the ~2x-expected-volume side-finding below). Switched to `ThreadingHTTPServer`; added
        `AppState.lock` around the one genuine read-modify-write in the whole file (`GET
        /switchtab`'s check-then-clear dequeue — the only spot two concurrent requests for the
        same profile could actually race now that concurrency is real, not theoretical); set
        `daemon_threads = True` so a stuck connection can't delay shutdown either; lowered
        `timeout` to 3s (loopback-only server, no reason for the old generous default). Verified
        live: 5 consecutive requests all sub-millisecond under the same real ongoing traffic that
        wedged it before, not just immediately after a restart.
      - Test suite updated to match (`ThreadingHTTPServer` throughout, `daemon_threads` in tests
        too, stalled-client test now asserts *fast* concurrent service rather than just
        eventual — a strictly stronger guarantee). Along the way, fixed an unrelated 18s test
        suite regression the switch introduced: `ThreadingHTTPServer.shutdown()` costs a full
        `poll_interval` (default 0.5s) per call, unlike plain `HTTPServer` — confirmed via a
        direct A/B timing script rather than assumed — fixed with `poll_interval=0.05` in test
        setup only (production doesn't care how fast shutdown() returns). 60/60 tests passing,
        suite back to ~2s.
  - **Side-finding, not fixed here**: roughly 2x the expected `/switchtab` poll volume for one
    profile observed during diagnosis — consistent with a known MV3 service-worker-restart bug
    class stacking up duplicate poll loops. Lives in `BrowserExtension/background.js`, not this
    file; noted for awareness, not investigated further. Directly relevant to Round 2 above, since
    it's plausibly *why* the single-threaded design's core assumption didn't hold in practice.

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
- [x] **Process-spawn escape hatch, all three "launch when nothing's open" cases** (commit
      `b68722b`): `dbus_bridge.py` gained `LaunchCommand(argv)` (general-purpose, used by
      `manageAppWindows`'s new `launchArgv` param) and `LaunchChromiumProfile(profile)` (resolves
      the profile *directory* via `AppState.chromium_profile_dirs`, clears stale server state for
      it, spawns `$CHROMIUM_EXE --profile-directory=<dir> $CHROMIUM_EXTRA_FLAGS` — used by
      `cycleChromiumProfile`/`focusTab`'s new launch-then-poll tiers,
      `waitAndActivateProfile`/`waitForTabOrOpen`, mirroring AHK's `_WaitAndCycleProfile`/
      `_WaitForTabOrOpen` via the `afterDelay`/`QTimer` polling primitive). `config.py` gained
      `CHROMIUM_EXE`/`CHROMIUM_EXTRA_FLAGS`, resolved by the installer wizard against real
      launch-command candidates on `PATH` per browser — confirmed empirically that command and
      resourceClass are genuinely different things (this machine's Brave installs as plain
      `brave`, not `brave-browser`, despite its resourceClass being `brave-browser`), not assumed
      to match.
  - Found and fixed two real bugs via live testing, not inspection: (1) `bridgeCall`'s
    `args.concat()` spreads each element as its own D-Bus positional parameter — correct for
    every method except `LaunchCommand`, whose single `as` parameter needs to arrive as ONE
    array argument. The unwrapped call silently "succeeded" with no exception but launched
    nothing (confirmed the exact mechanism: `dbus.Array("dolphin")` iterates the string into
    `['d','o','l','p','h','i','n']` rather than treating it as one element) — fixed with an
    explicit `[launchArgv]` wrap, documented at both the call site and `bridgeCall`'s own
    definition for the next array-typed method. (2) Spawned processes were never reaped
    (`Popen` without `wait()`), leaving zombies once the child exited — fixed with a background
    reaper thread (`_spawn_detached`).
  - Verified live end to end: closed all Dolphin windows, pressed the real "Toggle File Manager"
    hotkey, confirmed a fresh process actually launched (this is what caught the marshaling bug
    above) with no zombie afterward and correct toggle-not-relaunch on a second press; called
    `LaunchChromiumProfile("Personal")` directly and confirmed a real new "New Tab - Brave"
    window appeared, confirming profile-dir resolution + `CHROMIUM_EXE` lookup + the actual spawn.

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
  - [x] **Upgraded to a real interactive wizard** (`choose_browser`, commit `a13d1ea`): always
        prompts with a numbered menu (detected browsers + manual entry) instead of silently
        auto-picking, and — the actual point — verifies the chosen browser's `resourceClass`
        against a real open window when one exists (a one-off KWin script probe matching the
        window caption's `" - <BrowserName>"` suffix) rather than trusting the guessed
        `BROWSER_RESOURCE_CLASSES` table blindly. That table is guessed for everything except
        `brave-browser` (this port's only empirical confirmation) — exactly the kind of value
        that silently breaks every hotkey with zero error output if wrong, which is what
        motivated this (see the "hotkeys not working" troubleshooting that preceded it).
        `ensure_hotkeys` now pre-fills the confirmed `resourceClass` into a freshly-seeded
        `hotkeys.js` too, so only `YOUR_BROWSER_PROFILE` (a personal choice, not guessable)
        still needs manual editing. New `./installer.sh configure` action re-runs just the
        wizard. Tested live: detected-browser path (confirmed `brave-browser` via a real
        window), manual-entry path, and the full fresh-install flow.
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
- [x] **Hotkeys config UI, Linux half** (commit `d78cb65`): a shared local web page
      (`shared/hotkeys-ui.html`) served by the bridge server, rather than a native GTK/PyQt app —
      both platforms already run a local HTTP+token bridge server, so this needed nothing new on
      either side beyond a couple of endpoints, no new GUI toolkit dependency on Linux, and no
      new language runtime added to Windows to share code with. `hotkeys.json` (gitignored, like
      `hotkeys.js`) is the source of truth once you save from the UI — `hotkeys_generator.py`
      regenerates `hotkeys.js` from it on every `POST /hotkeys-config`, validating each binding
      and rejecting (400 + message) rather than ever writing a broken `hotkeys.js`. `GET
      /hotkeys-ui` deliberately isn't behind the token check (a plain browser navigation can't
      attach a custom header the way the page's own `fetch()` calls do). 11 new tests; verified
      live end to end — POSTed a real 3-binding config including a real "Focus Gmail" tabFocus
      binding against the actual "Personal" profile, confirmed `hotkeys.json`/`hotkeys.js`
      regenerated correctly, deployed via `./installer.sh install`, confirmed all three
      registered as real `kglobalaccel` shortcuts.
  - [ ] **Follow-up, deliberately not done here**: wiring the same `shared/hotkeys-ui.html` into
        `AltTabSucksServer.ps1` (static-file serving + regenerating `app-hotkeys.ahk` from the
        same `hotkeys.json` shape) — scoped as a separate step requiring explicit go-ahead, since
        it touches working Windows code rather than adding something new. `hotkeys_generator.py`
        would need a PowerShell/AHK-generating counterpart alongside the existing JS one.
  - [x] **Live resourceClass typeahead, built** (follow-up to the note above) — every
        resourceClass field now suggests whatever's actually running right now instead of
        requiring it typed from memory. The "reverse-direction channel" problem noted above
        turned out not to need solving at all: rather than the server asking the KWin script on
        demand (which the sandbox has no way to answer — it can only call *out* via `callDBus`,
        never be called *into*), `main.js` gained a self-rescheduling
        `pushRunningResourceClasses()` (10s interval, same `normalWindow`/`!transient` filter
        `findAppWindows` already uses) that *pushes* the current deduped, sorted set — the same
        shape the browser extension's own `POST /tabs` already uses for tab state, not a new
        pattern.
        - New `dbus_bridge.py` method `PushRunningResourceClasses(list)`, storing into a new
          `AppState.running_resource_classes` field; new `GET /running-resource-classes` for
          the page to fetch. The dedupe/sort itself is `normalize_resource_classes`, pulled out
          as a pure function (same reasoning as `url_matches_pattern`) so it's unit-testable
          without a live session bus — 5 new tests, plus 2 more for the HTTP endpoint. This half
          verified live end to end from the very first attempt: restarted the bridge server and
          redeployed the KWin script, waited for a real push cycle, and confirmed
          `GET /running-resource-classes` returned the actual live set of open windows'
          resourceClasses (`brave-browser`, `discord`, `code-oss`, ...) with no manual seeding —
          main.js's periodic push was reaching the server correctly on its own.
        - **First client-side attempt — native `<input list=...>` + `<datalist>` — looked
          completely correct and wasn't**: the user reported an empty dropdown that never
          populated while typing. Every server-side check came back clean (fresh live data over
          `curl`, the KWin script genuinely loaded and pushing), which pointed at the client —
          but the client looked right too on inspection. Settled it with a headless DOM replay
          (`jsdom`, no browser available to attach devtools to in this environment): fed the
          *exact bytes* `curl` fetched from the real running server into a real DOM + script
          execution environment, and the `<datalist>` populated with real `<option>`s, no thrown
          error, first try. The bug wasn't in this codebase at all — it's a confirmed Chromium/
          Wayland issue (native popup-style widgets, `<datalist>` suggestions and `<select>`
          dropdowns alike, silently failing to paint on this platform combination). Nothing
          fixable from HTML/JS; the whole approach had to go.
        - **Fix: a hand-rolled typeahead, not a native popup at all** — one shared floating
          suggestion box (`showSuggestionsFor`/`selectSuggestion`/`handleSuggestionKeydown`),
          plain `position: fixed` page content positioned from the focused input's own
          `getBoundingClientRect()`, filtered from `runningResourceClasses` on every keystroke.
          Selecting a suggestion (click or Enter) dispatches a synthetic `input` event rather
          than duplicating the `binding[key] = ...` write, so there's exactly one place that
          commits a value from this field either way. Since this renders as ordinary DOM nodes
          instead of a compositor-level popup surface, the Chromium/Wayland bug simply doesn't
          apply to it.
        - Re-verified the same way as the root-cause hunt: a headless DOM replay of the real
          served page, this time driving real interaction (focus, typing "disc", a mousedown on
          the resulting "discord" suggestion) rather than just checking static structure —
          confirmed the box populated with the correct filtered match and the click correctly
          committed the value and closed the box. (Simulating the initial focus-triggered
          "show everything" state came back empty under `jsdom` specifically — a known `jsdom`
          synthetic-focus-event limitation, not something touching real browser behavior; typing
          and selecting, the parts that actually matter, worked correctly both times.)
  - [x] **Follow-up: typeahead couldn't be found by an app's binary/package name, only its
        resourceClass** — reported live ("the resourceClass typeahead for app cycle isn't working
        for shelly-ui"). Root-caused with a `loadScript` probe scanning every current window for
        anything Shelly-related: the real app's `resourceClass` is the reversed-domain
        `com.shellyorg.shelly`; `shelly-ui` is its `resourceName` — a completely different X11/
        Wayland window property this typeahead never looked at. Not a bug in the substring-match
        filter itself (confirmed it's a plain `.includes(q)` check, working exactly as written) —
        `"com.shellyorg.shelly"` genuinely doesn't contain `"shelly-ui"` as a substring, so zero
        results was the *correct* answer to the query actually being run. The real gap: a user
        has no way to know that ahead of typing, and `resourceName` is usually the more
        recognizable of the two (this project's own README already calls out KDE apps'
        reversed-domain resourceClasses as the single most common hotkey failure mode).
        - `main.js`'s `pushRunningResourceClasses()` now also collects each window's
          `resourceName`, sent alongside `resourceClass` as a second, positionally-parallel
          array (`PushRunningResourceClasses(classes, names)`, `in_signature="asas"`).
          `dbus_bridge.py` gained `merge_resource_class_names` (pure function, same
          unit-testability reasoning as `normalize_resource_classes`/`url_matches_pattern`) to
          zip them into a `{resourceClass: resourceName}` lookup, stored as a new
          `AppState.running_resource_class_names` field. `GET /running-resource-classes`'
          response shape changed from a bare string list to `[{resourceClass, resourceName}, ...]`
          pairs — a deliberate breaking change to that endpoint's shape, fine since
          `hotkeys-ui.html` is its only consumer and got updated in the same change.
        - `hotkeys-ui.html`'s `showSuggestionsFor` now matches the typed query against *either*
          field, and shows `resourceClass (resourceName)` in the dropdown when they differ (bare
          `resourceClass` when they're the same, e.g. `kate`/`kate` — no redundant parenthetical).
          The value actually written into the field on selection is always `resourceClass`,
          never the display label or the name it was found by — `dataset.value` on each
          suggestion `<div>` carries that, read by both the mousedown handler and
          `handleSuggestionKeydown`'s Enter case, specifically so a match found *by* resourceName
          can't accidentally commit that parenthetical text instead of the real value.
        - Verified live end to end: redeployed the server and KWin script, waited for a real push
          cycle, and confirmed `GET /running-resource-classes` returned the real
          `com.shellyorg.shelly` / `shelly-ui` pairing (and correct pairings for every other
          currently-open app) with no manual seeding. The exact filter/label expressions from the
          fix were also run standalone in plain Node against that reported case — `"shelly-ui"`
          correctly matches and resolves to `com.shellyorg.shelly`, and a same-name case (`kate`/
          `kate`) correctly skips the redundant parenthetical. 8 new/updated unit tests
          (`merge_resource_class_names` and the HTTP endpoint's new response shape); full
          68-test suite still green.
  - [x] **Follow-up: focusing a resourceClass field now rescans instead of only ever showing
        whatever was cached at page load** — `runningResourceClasses` was previously populated
        exactly once, in `load()`; `main.js` only pushes a fresh snapshot every 10s on its own
        schedule regardless of what the user is doing, so an app launched *after* opening the
        Hotkeys UI (or after the last time a given field happened to be focused) had no way to
        show up in that field's suggestions short of reloading the whole page — a real
        discoverability gap for the exact workflow this feature exists for ("launch the app once
        and start typing its name," per the README).
        - The page-load fetch logic was pulled out into its own `refreshRunningResourceClasses()`
          (unchanged behavior there — `load()` just calls it now instead of inlining the same
          `try`/`catch`), and `textInput`'s `focus` handler for suggest-enabled fields now calls
          it too: shows suggestions instantly from whatever's already cached (no flicker waiting
          on a fetch), then re-shows them once the background rescan resolves — only if the field
          is still the one focused, since the user may have already tabbed away, clicked a
          suggestion, or blurred by the time it lands. A failed rescan leaves the previous list in
          place rather than blanking suggestions that were working a moment ago.
        - Verified live: confirmed via `curl` that the running server (serving `hotkeys-ui.html`
          straight from disk, no separate deploy step for this file) picked up the change
          immediately with no restart needed; syntax-checked the extracted inline `<script>` block
          directly with `node --check`.
  - [x] **`windowCycle`/`windowToggle` merged into one "App windows" section** — they're the
        exact same `manageAppWindows(resourceClass, mode, launchArgv)` call either way
        (`hotkeys_generator.py` already only ever varied a `mode` string between them), so having
        them as two entirely separate sections was mostly duplicated structure for what's really
        one binding concept with two behaviors. `hotkeys.json`/`hotkeys_generator.py` are
        untouched — `binding.type` is still the literal string `"windowCycle"`/`"windowToggle"`,
        no schema change at all; only how `hotkeys-ui.html` *groups and labels* those two values
        changed.
        - Replaced the flat `TYPE_LABELS` (type -> title) with a `GROUPS` array — each entry
          lists every `binding.type` it covers (`types`), which one a bare `+ Add` should create
          (`defaultType`), and, only for this merged group, a `modeOptions` list driving a
          per-row Mode `<select>` (values `windowCycle`/`windowToggle`, labels "Cycle"/"Toggle").
          `GROUP_BY_TYPE`, built once from `GROUPS`, replaces the old one-type-is-one-group
          assumption everywhere that mattered: `renderAll`'s section list, the drag-reorder
          same-group guard (now compares groups, not exact types — reordering across
          Cycle/Toggle rows within the merged section works the same as within any other
          section), and `renderGroupHeader`'s field-list lookup (via `defaultType`, since every
          type in a group is required to share `TYPE_COLUMNS`, unchanged from before — `windowCycle`
          and `windowToggle` already aliased to the same array).
        - The Mode dropdown is a narrower, intentionally different thing from the old *global*
          Type `<select>` removed earlier: that one could reassign a binding to any of 7 mostly-
          unrelated types (and got removed for being redundant display + confusing reassignment);
          this one only ever offers the 2 values that are actually the same underlying function,
          scoped to the one group where "switch to the other behavior, keep everything else"
          is a real, common thing to want.
        - Verified live with a headless DOM replay of the real running page against the actual
          `hotkeys.json`: 6 sections instead of 7, all 3 real `windowCycle`/`windowToggle`
          bindings rendering together under one "App windows" heading with correct per-row Mode
          values, and — the part that actually exercises the new code, not just its structure —
          flipping one row's Mode dropdown (Cycle -> Toggle) correctly updated that binding's
          `type` and left it sitting in the same section afterward, still 3 rows, not split off
          anywhere.
  - [x] **`Ctrl+Alt+Shift+'` reloads hotkeys** — the Linux equivalent of `AltTabSucks.ahk`'s
        built-in `^!+'::Reload`, but *not* hardcoded as a framework special case the way it first
        shipped (a `main.js` `registerShortcut` + a dedicated `dbus_bridge.py` `ReloadHotkeys`
        method) — superseded one commit later by the generic **`runCommand` binding type**
        (below): "Reload Hotkeys" is now an ordinary `hotkeys.json` binding like any other,
        editable/removable in the UI, with `argv` pointing at this clone's `installer.sh
        reload-hotkeys`. `installer.sh reload-hotkeys` itself is unchanged — still the narrow
        action (skips deps/config/service, just `install_kwin_script`) a hotkey-triggered reload
        should run. `hotkeys.template.js` got the same binding as an example (`YOUR_REPO_ROOT`
        placeholder, substituted unconditionally by `ensure_hotkeys()` — unlike
        `YOUR_BROWSER_RESOURCE_CLASS` this needs no user input, `$REPO_ROOT` is always known) so
        hand-editors who never touch the UI still get a working reload hotkey out of the box.
        Verified live end to end post-refactor: `kglobalaccel.invokeShortcut("Reload Hotkeys")`
        (the most faithful real-keypress simulation available over D-Bus) actually ran
        `installer.sh` (journalctl), left the script `isScriptLoaded == true` afterward, and
        `Reload Hotkeys` appears in `kglobalaccel`'s shortcut list with no other action colliding
        on its title. One bootstrap caveat unchanged: a clone needs one manual
        `./installer.sh install` (or `reload-hotkeys`) before the hotkey itself exists to press.
  - [x] **`runCommand` binding type** — generic "spawn this argv on this key" binding
        (`bridgeCall("LaunchCommand", [argv], ...)`, the same escape hatch `manageAppWindows`'s
        optional `launchArgv` already uses), added specifically so "Reload Hotkeys" (above) could
        stop being a bespoke hardcoded case and become just another configurable hotkey. No
        `resourceClass` field (nothing to match against) — `hotkeys_generator.py`'s per-type
        validation and `hotkeys-ui.html`'s field rendering both special-case that. Also fixed
        while building this: two bindings sharing a `title` collide silently in `kglobalaccel`
        (title is the action's unique ID) — root-caused a real "Focus Gmail doesn't work" report
        to exactly this (cloned via the UI's "Dup" button, never renamed from "discord"); 
        `generate_hotkeys_js` now rejects duplicate titles at save time. 3 new tests.
  - [x] **`runCommand` now waits for its command and shows a toast with the result, including
        output** — the user's literal complaint motivating this: "I can't tell if the reload
        hotkeys command is actually working" (`LaunchCommand`'s detached fire-and-forget spawn,
        right for GUI apps that never exit, gives zero feedback for a CLI-style command). New
        `dbus_bridge.py` method `RunCommandWithOutput(argv) -> "exitCode\noutput"` (one
        newline-joined string, not two D-Bus out-args or a boolean in-arg — see below for why
        avoiding untested marshaling patterns mattered here specifically); `main.js`'s
        `runCommandWithToast(title, argv)` is what `runCommand` bindings now call instead of
        `bridgeCall("LaunchCommand", ...)` directly. `hotkeys.template.js`'s "Reload Hotkeys"
        example updated to match, so hand-editors get this too.
      - **Toast daemon grew a second rendering mode**, `show_command_result`/`ShowCommandResult`
        — green/red background+border by exit status (not `next_color()`'s rainbow, which is a
        "rapid window/tab switching" signal, meaningless for a one-off command result), a title
        line plus a left-aligned monospace output block (unlike the profile/window toast's single
        uppercased line, this has to actually be *read*), 4s default duration instead of 500ms.
        One persistent `Gtk.Box` with two labels shared between both modes, not two separate
        surfaces — same "stay warm" reasoning as the daemon's core design.
      - **Two real bugs found building this, both resolved by not trusting an unproven pattern
        and switching to one already proven in this codebase**:
        1. First attempt used `dbus-python`'s `async_callbacks` (reply sent later, from a
           background thread) so a slow command wouldn't block the GLib mainloop other bridge
           calls (`FindTab`, `QueueSwitchTab`, ...) share. The reply demonstrably reached the
           D-Bus wire correctly (confirmed independently over `dbus-monitor` and a direct `qdbus6`
           call) — but KWin's `callDBus` never delivered it to the waiting JS callback, confirmed
           by a debug marker as the callback's first statement never firing across multiple real
           presses. Root cause sits inside KWin's own `callDBus`, not this codebase; not pursued
           further given a `runCommand` press is rare/manual, not polled — switched to a plain
           synchronous reply (every other bridge method's pattern) and it worked immediately.
           Observed round trip for `installer.sh reload-hotkeys`: ~34ms, imperceptible to block on.
        2. `ok` is passed as an int (0/1), not a D-Bus boolean — every other bridge argument in
           this codebase is a string/int/array, never a bool; this stuck to what's already proven
           to marshal correctly rather than being the first thing to assume a bool argument does
           too (the multi-value-D-Bus-return question got the same treatment — encoded as one
           string instead, see above).
      - **A real, structural, honestly-documented limitation, not a bug**: `installer.sh
        reload-hotkeys` is self-referential — the very script waiting for `RunCommandWithOutput`'s
        reply is what `install_kwin_script`'s `unloadScript` call tears down partway through that
        same command's execution, on **success**. The old JS context is gone before it can ever
        show its own confirmation toast, sync or async, no matter what — confirmed by testing a
        harmless non-reloading command (`echo`) through the exact same real, persistently-
        installed script, which showed its toast correctly every time. Verified the asymmetry that
        makes this tolerable rather than a full regression: since `installer.sh` runs under
        `set -e`, a *failing* `reload-hotkeys` (tested with a real temporary binding pointed at an
        invalid `installer.sh` subcommand, deployed and invoked through the real script — not an
        ad-hoc probe, which turned out to be an unreliable way to test this specific timing
        question) never reaches `unloadScript` at all, so its context survives and its failure
        toast — full error output included — displays correctly. Net effect at the time: a
        successful reload was silent (same as before this feature), a failing one was clearly
        reported (new).
      - **Follow-up (same session, next turn) — the marker-based fix, built and verified**:
        `install_kwin_script` now writes `"<epoch_ms>|<message>"` via `kwriteconfig6 --file
        kwinrc --group Script-alttabsucks --key pendingReloadToast` right before the `reconfigure`
        call that actually triggers the new script instance loading (not after
        `install_kwin_script` returns — a race against exactly when KWin finishes the reload,
        avoided by writing it before the trigger rather than after the effect). `main.js` gained a
        one-shot top-level check (runs once per script load, not inside any `registerShortcut`):
        `readConfig("pendingReloadToast", "")`, and if the timestamp is under 10s old, shows the
        same `showCommandResultToast` after a 300ms `afterDelay` (letting KWin's post-reload
        window/workspace churn settle before reading `workspace.activeWindow` to position
        against). No `writeConfig` in the sandbox to explicitly clear the marker after showing it
        (only `readConfig` — see the sandbox notes) — the recency check does that job instead, and
        doubles as the guard against a stale marker replaying on some unrelated future reload
        (e.g. a plain Plasma restart hours later still finds the old value sitting in `kwinrc`,
        correctly ages it out).
        First had to verify empirically that `readConfig` actually reads from the config group a
        real, KPackage-installed script's `kwriteconfig6`-written value ends up in — an ad-hoc
        `loadScript` probe (the tool used for nearly every other live check in this file) does
        *not* share that config context, silently returning the default for a key that
        genuinely exists once written from a properly installed script's own perspective.
        Verified live twice: once via a plain manual `./installer.sh reload-hotkeys` from a
        terminal, once via the actual `kglobalaccel`-invoked "Reload Hotkeys" hotkey — both showed
        "Reload Hotkeys ✓ KWin script reloaded successfully." Net effect now: both success and
        failure show a toast for `reload-hotkeys` specifically, matching every other `runCommand`
        binding.
      - **Then the user reported the physical `Ctrl+Alt+Shift+'` press itself still did nothing —
        a hardware limitation, not a bug, root-caused with a same-session diagnostic technique**:
        a temporary `runCommand` binding whose `argv` appended a timestamp to a plain file (`date
        +%s%N >> /tmp/....log`) rather than relying on `print()`/`journalctl` (already established
        unreliable earlier this session) or `org.freedesktop.Notifications` (also tried, also
        didn't render reliably in screenshots here). Confirmed the file never got a line no matter
        how many times the real key was pressed — the callback was never reached at all, upstream
        of everything this feature built. Ruled out a `kglobalaccel` conflict (scanned every
        component for the same key code — clean) and a dead-key/IME layout issue (plain `us`
        layout, no intl variant). Root cause found with four simultaneous diagnostic bindings
        (same file-log technique, four different key combinations, one round of physical
        keypresses): every combination holding **Shift together with the apostrophe key** failed
        (`Ctrl+Alt+Shift+'`, and even `Ctrl+Alt+Shift+"` — registered for the actual shifted
        keysym Shift+`'` produces, which ruled out a keysym-translation theory), while the one
        combination *without* Shift (`Ctrl+Alt+'`) fired every time — classic keyboard matrix
        ghosting: that specific key *pair* can't be sensed together on this keyboard, regardless
        of what else is held (`Alt+Shift+'`, only 3 keys, failed too) — not a total-key-count
        limit, since other real `Ctrl+Alt+Shift+<letter>` hotkeys work fine. Not fixable in
        software; user chose to rebind "Reload Hotkeys" to the proven-working `Ctrl+Alt+'`.
      - **Rebinding surfaced a second, systemic bug**: changing a binding's `key` (same `title`)
        and redeploying didn't actually change what's bound — `kglobalaccel` keeps a global
        action's key sticky to whatever it was on *first-ever* registration under that action
        name; a later `registerShortcut` call with a different key, same name, is silently treated
        as "already configured, don't overwrite" (by design — a script update shouldn't clobber a
        user's own System Settings customization). Found because rebinding "Reload Hotkeys" didn't
        take effect until manually run through `qdbus6 .../KGlobalAccel.unregister kwin "Reload
        Hotkeys"` first — and then found *again*, independently, as the actual root cause of a
        separate user report ("Hotkey config" — `Ctrl+Alt+Shift+H` for the hotkeys-ui tab — not
        responding to `H`): its registered key had been silently stuck on `Ctrl+Alt+Shift+?` from
        an earlier version of that same binding, ever since its key was last changed via the UI.
        Fixed systemically, not just for these two bindings: `installer.sh` gained
        `unregister_alttabsucks_shortcuts` (queries `allShortcutInfos` for the `kwin` component,
        unregisters every action whose friendly name starts with `"AltTabSucks: "` — the exact
        prefix `hotkeys_generator.py` uses, so this never touches an unrelated Plasma/kwin
        shortcut), called from `install_kwin_script` right before the `reconfigure` that triggers
        fresh `registerShortcut` calls — and, like the reload-toast marker, only *after*
        `kpackagetool6` has already succeeded, so a failure earlier in the function leaves the
        *old* script and its already-working shortcuts untouched rather than unregistering
        hotkeys with nothing new ready to replace them. Verified live: changed "Kate"'s key from
        `N` to `K` through the real `POST /hotkeys-config` save path (not a manual unregister) and
        confirmed the new key was live immediately; changed it back, confirmed that round-tripped
        too. Every future key change made through the hotkeys-ui page now just works, no manual
        `unregister` step required.
  - [x] **`focusTab` wasn't raising the target window** — the common "tab already open in an
        existing window" path queued `QueueSwitchTab` with no `activateWindow`/`activateAnyWindow`
        call, unlike the other two `focusTab` paths (`waitForTabOrOpen`, `openOrLaunchTab`'s
        existing-window branch), relying entirely on the browser extension's own
        `chrome.windows.update({focused:true})` to raise the window — unreliable under Wayland,
        where a client generally can't force itself to the front (only the compositor can, which
        is the entire reason this is a KWin script). Added the missing `activateAnyWindow(
        resourceClass)` call. Verified live with a real before/after check (not just code
        reading): started with Discord focused, invoked "Focus Gmail" via
        `kglobalaccel.invokeShortcut`, confirmed via a one-off KWin script probe that
        `workspace.activeWindow` actually flipped from `discord` to `brave-browser` on the
        correct Gmail tab.
  - [x] **That fix was still wrong with more than one browser window open — two rounds, second
        one was the actual fix** (same shape as the earlier hang investigation: round 1 looked
        right and verified fine, round 2 found the real problem). `activateAnyWindow` raises *any*
        window of the resourceClass (`listBrowserWindows(resourceClass)[0]`, first in
        `workspace.stackingOrder`), not necessarily the one the matched tab is actually in. Fine
        by luck with a single browser window, a real reported bug with several: "Focus Gmail"
        raised some unrelated window while the Gmail tab switched silently in the background.
        - **Round 1**: gave `dbus_bridge.py`'s `FindTab` (D-Bus variant only — not the `GET
          /findtab` HTTP endpoint Windows AHK parses, no reason to touch that) a third field
          carrying the *matched tab's own* title (`windowId|tabId|title`), and added
          `activateWindowForTab()` to `main.js` to match window caption against it. Verified live
          with 3 real Brave windows open (Gmail, hotkeys-ui, a GPU dashboard): forced a different
          one active, captured via a probe exactly which window the *old* logic would have picked
          (confirmed wrong), invoked "Gmail" for real, confirmed the actual Gmail window came out
          on top. Looked like a complete fix.
        - **Round 2**: the user reported Gmail now worked but YouTube — same function, same fix —
          still raised the wrong window. Root cause: matching against the *matched* tab's own
          title only works when that tab already happens to be the one currently showing in its
          window, since that's the only case where its title is what the window's caption
          currently reads. It coincidentally was for Gmail (already the active tab) and wasn't for
          YouTube (a background tab in a window showing something else) — the "fix" only ever
          worked by luck, same as the bug it replaced. Real fix: reverted `FindTab` back to plain
          `windowId|tabId` and added `GetWindowActiveTitle(profile, windowId)` — the *window's*
          currently active tab's title (mirrors `GetActiveTitles` but scoped to one windowId),
          which reliably matches that window's actual current caption regardless of which tab
          within it got matched. `focusTab`/`waitForTabOrOpen` now call this before
          `activateWindowForTab`, adding one more chained `bridgeCall` to the sequence.
        - **Observability note for future debugging in this environment**: partway through
          verifying round 2, `kwin_wayland`'s `print()` output stopped reaching `journalctl`
          entirely (system-wide, `_PID=2170` included) — not a code regression, cause undetermined
          (journald rate-limiting from this session's cumulative probe-script volume was suspected
          but its config is default/unset, so unconfirmed), and it didn't recover on its own
          within the session. `dbus-monitor` filtered to the relevant service names/methods still
          works perfectly and doesn't depend on `kwin_wayland`'s own logging at all — use that
          first if `print()`-via-`journalctl` goes quiet again, rather than assuming the script
          itself broke.
        Verified round 2 live via `dbus-monitor` (not `print()`/`journalctl`, per the note above):
        watched the real "Youtube" hotkey fire, confirmed `FindTab` matched tabs in one window,
        `GetWindowActiveTitle` for that exact windowId returned a real non-empty title, and
        `QueueSwitchTab` targeted that same windowId — the window that gets raised (by matching
        that title) is now provably the same one whose tab is being switched, not a coincidence.
  - [x] **`focusTab` cycling ignored whether you were already on a match — three rounds, third
        one was the actual fix** (same shape as every investigation above: each round verified
        fine against the exact reported case, and each next round found what it broke). A
        separate bug from the window-raising ones above, in the *tab selection* logic rather than
        window activation. `_focusTabIdx[cacheKey]` only reset to 0 on `arrivedFromOutside` (you
        weren't in this browser's resourceClass at all a moment ago); otherwise it kept advancing
        from wherever it last left off, with no check for whether the *currently showing* tab
        already satisfied the hotkey. Reported case: several tabs match `youtube.com` in the same
        window, you're already looking at one of them (not because you just cycled here with this
        same hotkey — maybe hours earlier, maybe a different route entirely), press "Focus
        YouTube" once, and it jumps to a *different* matching tab instead of staying, purely
        because the stale counter wasn't 0.
        - **Round 1**: `FindTab`'s D-Bus variant grew a third field again — the matched tab's own
          title, for a genuinely different purpose than the earlier window-raising mistake:
          main.js compared it against `workspace.activeWindow.caption` as it already is,
          synchronously, before anything is touched (present state, not predicted future state).
          If any match was already showing, `focusTab` stayed on it. Verified live via
          `dbus-monitor` with a real two-tab scenario (one YouTube tab active, a second present but
          not showing): pressing the hotkey *twice in a row* kept `QueueSwitchTab` targeting the
          same already-active tab both times, fixing exactly the reported case.
        - **Round 2**: the user reported this broke deliberate cycling entirely — with two
          YouTube tabs open, there was now no way to reach the second one at all. Root cause:
          "already showing a match" is true on *every* press once you've switched to any match
          once, since that's now what's on screen — round 1 had no way to tell "you're here
          because you just arrived" from "you're here because you pressed this same hotkey a
          moment ago and want the next one." Both look identical from a bare
          currently-showing-a-match check. Fix: track *which* `{windowId, tabId}` this hotkey
          itself last switched to (`_focusTabLast`, replacing the bare-index `_focusTabIdx`), not
          just an index — if the tab currently showing is exactly the one this hotkey put there
          last time, treat it as a deliberate repeat and advance; otherwise stay. Verified live via
          `dbus-monitor`, three presses in a row: stay (fresh) → cycle (repeat) → wrap around.
        - **Round 3**: the user reported cycling-vs-staying regressed again — landing on the
          correct tab could still trigger an unwanted cycle. Root cause: identity alone (`{windowId,
          tabId}` matches the last pick) doesn't prove *this* press is a deliberate repeat — you
          can land back on the exact tab this hotkey picked last time through some *other* route
          entirely (cycled to that browser window with a different hotkey, switched by hand, ...),
          arbitrarily long after the fact, and it reads identically to "still actively repeating."
          Same mistake as round 1, one level narrower: identity-without-recency instead of
          presence-without-ownership. Fix: `_focusTabLast` entries now carry a timestamp too
          (`tick`), and "deliberate repeat" additionally requires that pick to be recent
          (`FOCUS_TAB_REPEAT_WINDOW_MS`, 2000ms — mirrors the cooldown `lib/chromium.ahk`'s own
          `FocusTab` already uses for a related purpose, `_focusTabOpenedAt`, not a new arbitrary
          number). Same recency-window shape as the toast daemon's rainbow-cycling
          (`toast_colors.RAINBOW_CONTINUE_WINDOW_MS`) solving the identical class of problem there.
          Verified live via `dbus-monitor`: pressed once (landed on tab A), waited 3s (past the
          window) with tab A still showing, pressed again — stayed on A (proving the stale pick no
          longer reads as a repeat) — then immediately pressed a third time (<2s later) — correctly
          cycled to tab B (proving genuine rapid repeats still work). Both requirements verified
          holding simultaneously in one sequence, not just separately.
  - [x] **Drag-handle reordering** — a small `⋮⋮` handle pinned to each row's corner (not a flex
        field — would've stolen row width from Title/Key/etc., which is also what a `.field.fixed`
        `min-width: 90px` leak was independently doing to the badge/Dup/Remove buttons, fixed in
        the same pass), native HTML5 drag-and-drop, restricted to the handle so ordinary text
        selection in the row's inputs doesn't turn into an accidental drag.
  - [x] **`#N` badge is now an enable/disable toggle**, not just an index label — click to flip
        `binding.enabled`, dims the whole row. `generate_hotkeys_js` skips `enabled:false`
        bindings entirely (no `registerShortcut` emitted, same as if absent from `hotkeys.json`),
        which also exempts a disabled binding from the duplicate-title check and lets it be left
        half-filled-in as a draft without failing validation. 5 new tests.
  - [x] **Save now deploys automatically** — `POST /hotkeys-config` runs `installer.sh
        reload-hotkeys` itself (via `AppState.deploy_command`, overridable so tests exercise the
        real `subprocess.run`-and-report-the-result path against a harmless stub instead of the
        real installer.sh) right after writing `hotkeys.js`, and reports `deployed: true/false` +
        a status-line-visible note back to the UI. Turns Save from a two-step "save, then
        remember to redeploy" into one step; the `Ctrl+Alt+Shift+'`/manual-`reload-hotkeys` paths
        still exist for hand-edits made outside the UI. 3 new tests (success, failure, command-
        not-found). Verified live: POSTed a real config change through the running server,
        confirmed `deployed: true` in well under a second, and confirmed via the deployed
        `main.js`'s mtime that a real redeploy — not just a claimed one — had just happened.
- [x] **Toast overlay** (`linux/toast/`) — Linux port of `lib/toast.ahk`'s `ShowProfileToast` only
      (`ShowSetupToast`/`ShowChoiceDialog` not ported, out of scope). KWin's scripting sandbox has
      no popup-window primitive of its own (same category of gap the window switcher's DWM
      preview ran into), so this is a separate persistent daemon
      (`linux/toast/alttabsucks_toast.py`, GTK4 + `gtk4-layer-shell`) the KWin script reaches via
      a direct `callDBus` — not routed through `dbus_bridge.py`/the HTTP server, since it's a
      standalone process. User picked this over two lighter native options (Plasma's own OSD
      service, a desktop notification bubble) specifically for closer visual parity with the AHK
      version — rainbow-cycling color included, at the cost of a new system dependency
      (`gtk4-layer-shell`, non-fatal — `check_toast_deps` skips just the toast daemon, doesn't
      block the rest of `./installer.sh install`, if it's missing) and meaningfully more code than
      either lighter option would have needed.
      - **Why a persistent daemon, not a per-toast spawn** (the same `LaunchCommand` escape hatch
        `manageAppWindows` uses to launch apps): the AHK rainbow-cycling-on-rapid-fire behavior
        needs memory of the previous toast's color/timing, and cold-starting GTK4 per call would
        add visible latency to what's meant to be instant feedback.
      - **No titlebar-color sampling** — reading arbitrary screen pixels needs an
        xdg-desktop-portal screenshot permission grant on Wayland, i.e. an interactive prompt,
        a non-starter for something that fires silently on every hotkey press. Toasts use one
        fixed base color (the same navy `ShowSetupToast`/`ShowChoiceDialog` already use elsewhere
        in this project) instead — the rainbow-cycling behavior on rapid repeated presses is
        preserved in full, since that only ever needed *a* previous color to advance from, not a
        sampled one.
      - **Rainbow logic split into `linux/toast/toast_colors.py`**, a zero-dependency module
        (mirrors `hotkeys_generator.py` being separate from `alttabsucks_server.py`), so it's
        testable without GTK4/gtk4-layer-shell/dbus-python installed. 7 tests — including one
        that locks in the exact starting color of the rainbow sequence (verified by hand against
        AHK's 1-indexed-array arithmetic, not assumed).
      - **`installer.sh`**: `check_toast_deps` (non-fatal) + `install_toast_service`/
        `uninstall_toast_service`, wired into `do_install`/`do_uninstall`/`do_status`/
        `do_start`/`do_stop`. The tracked `linux/systemd/alttabsucks-toast.service` carries
        `YOUR_GTK4_LAYER_SHELL_SO`/`YOUR_REPO_ROOT` placeholders — `find_gtk4_layer_shell_so`
        resolves the actual `.so` path via `ldconfig -p` at install time (LD_PRELOAD is required
        for a known gtk4-layer-shell/PyGObject linking quirk — confirmed empirically, silent
        fallback to an ordinary floating window without it) rather than hardcoding an
        Arch-specific path into the tracked unit file. Hit a real `set -o pipefail` foot-gun
        building this: `ldconfig -p | awk '{...; exit}'` gets SIGPIPE'd by `ldconfig` once awk
        closes its read end early, and that non-zero exit silently killed the whole
        `./installer.sh install` run immediately after the KWin script step — fixed with
        `{ ldconfig -p || true; } | awk ...`.
      - **`main.js` wiring**: `activateWindow`/`activateAnyWindow` both gained an optional
        `toastLabel` param. Label convention matches `ShowProfileToast`'s own callers exactly:
        `manageAppWindows` toasts with `resourceClass` (no `_SwitcherExeName`-style friendly-name
        table ported — same deferral as the window switcher itself), `cycleChromiumProfile`/
        `focusTab` toast with `profileName`. `focusTab`'s preliminary focus-steal activation
        deliberately stays toast-less, matching AHK (only the confirmed final activation toasts).
      - **Verified live, extensively, not just by reading code**: direct `ShowToast` D-Bus calls
        screenshotted on both monitors of this dev machine (`HDMI-A-1` and `DP-1` — different
        origins, proving the per-monitor margin math, not just a lucky single-monitor default);
        rapid-fire calls screenshotted showing a rainbow color instead of the default navy; a
        real `kglobalaccel.invokeShortcut("vscode")` (a real hotkey, not a direct D-Bus call)
        screenshotted showing "CODE-OSS" toasted over the actually-activated window. One
        red herring during testing, worth recording: an `invokeShortcut("Focus Gmail")` call
        appeared to do nothing — root cause was a stale/orphaned `kglobalaccel` action name from
        hotkeys.json having been renamed to "Gmail" by a concurrent edit (a second Claude Code
        session was open on this same repo) mid-testing, not a toast bug — confirmed via
        `dbus-monitor` that `ShowToast` was in fact reaching the daemon and returning
        successfully even on the run that produced no visible screenshot (a plain screenshot-
        timing miss against the 500ms window, not a functional issue — confirmed separately with
        a long-duration direct call on the same monitor).
- [x] **`FindTab` treated `music.youtube.com` as a match for a `youtube.com` pattern** — reported
      directly: "the matching logic is ignoring the 'music.' prefix and treating music.youtube.com
      the same as youtube.com. it shouldn't be." Root cause: plain `pattern in url` substring
      containment, which is also exactly what `GET /findtab` and `Server/AltTabSucksServer.ps1`
      (`-like "*$safePattern*"`) still do — confirmed by reading the PS1 handler directly, so this
      is a pre-existing behavior shared with Windows, not a Linux-porting regression. Scoped the
      fix to `dbus_bridge.py`'s D-Bus-only `FindTab` (no Windows counterpart to keep parity with,
      unlike `GET /findtab`, which Windows AHK has no use for on Linux either but is left alone on
      principle — same reasoning already applied to this method's `windowId|tabId|title` format
      above); `GET /findtab` and the PS1 server are both untouched.
      - New module-level `url_matches_pattern(url, pattern)`, pulled out as a pure function
        (mirrors `toast_colors.py`/`hotkeys_generator.py` being separate from their D-Bus/GTK-
        dependent callers) specifically so it's unit-testable without a live session bus — the
        `Bridge` class itself needs a real `bus_name` to construct, so it isn't tested directly.
        Matches at the *start* of the scheme-stripped URL, tolerating a `www.` prefix on the URL
        side only (the one subdomain variation common enough to treat as "the same site" without
        listing it explicitly — every other subdomain is a deliberately different match, same
        philosophy as `urlPatterns` already letting callers OR multiple exact variants together,
        e.g. `["calendar.google.com", "mail.google.com"]`), and requires a boundary right after
        the pattern (end of string, or one of `/:?#`) so `youtube.com` doesn't also match an
        unrelated `youtube.company.com` — a second, narrower instance of the same class of bug,
        not separately reported but caught for free by anchoring the match properly instead of
        patching just the one reported case.
      - 13 new tests covering the reported case, the `www.` tolerance, the trailing-boundary
        case, and a path-scoped pattern (`google.com/maps`, from the real `hotkeys.js`) still
        matching correctly. Verified live against the running `alttabsucks-server.service`: posted
        two real tabs (`youtube.com/watch...` and `music.youtube.com/watch...`) into a scratch
        profile via `POST /tabs`, called the real `FindTab` D-Bus method directly — pattern
        `youtube.com` returned only the plain-YouTube tab, pattern `music.youtube.com` returned
        only the Music tab, then cleaned up via `DELETE /tabs`.
- [x] **Split/merge browser windows** — port of `lib/chromium.ahk`'s `SplitFocusedTab`/
      `MergeFocusedWindow` (`Alt+X`/`Alt+Z` on Windows). Two new binding types, `splitTab`/
      `mergeTabs`, mapping to new `main.js` functions `splitFocusedTab(resourceClass,
      profileName)`/`mergeFocusedWindow(resourceClass, profileName)` — unlike AHK, which
      auto-detects the profile from the active window's title via `_DetectProfileFromWindow`,
      both take `resourceClass`+`profileName` explicitly, matching every other browser-related
      binding type here (`profileCycle`, `tabFocus`) rather than porting a whole extra
      detection subsystem for these two. Both no-op if the active window isn't the configured
      browser, same as AHK's `WinActive(winFilter)` early-return.
      - **New `dbus_bridge.py` methods** `QueueSplitTab(profile)`/`QueueMergeTabs(profile)` —
        mirror `POST /switchtab`'s `{splitTab}`/`{mergeTabs}` variants, writing straight into
        `switch_queue` like `QueueSwitchTab`/`QueueSwitchOpenUrl` already do. No changes needed
        anywhere else server-side: `GET /switchtab`'s dequeue and the extension's
        `background.js` handling of `cmd.splitTab`/`cmd.mergeTabs` are both already generic
        (shared with Windows/PS1, browser-side code, OS-independent) — confirmed live via a
        direct `QueueSplitTab` D-Bus call that the extension really does detach the active tab
        into a new window via `chrome.windows.create`, and a direct `QueueMergeTabs` call that
        it really does move every tab back into the other window.
      - **`splitFocusedTab` snapshots existing browser windows, queues the split, then polls
        (100ms/3s, same tuning as every other bridgeCall-then-poll loop here) for a window not
        in that snapshot** — the one the extension just detached the tab into — then places it
        and the original window side by side.
      - **A real, KWin-specific bug found and fixed via live testing, not just code reading**:
        the first implementation followed a Plasma 6 discuss.kde.org example verbatim,
        `window.frameGeometry = Qt.rect(x, y, w, h)`. Deployed and invoked for real through
        `kglobalaccel` — nothing happened, no new window ever got positioned, no exception
        visible anywhere. Root-caused with a `loadScript` probe that printed `typeof Qt` via a
        toast (this sandbox's established substitute for `journalctl`/`print()`, both already
        unreliable earlier this session): **`Qt` is `undefined` in this KWin scripting
        environment** (`typeof KWin === "function"` but `typeof Qt === "undefined"`) — the
        example's `Qt.rect(...)` call was throwing a `ReferenceError` on every invocation,
        silently, before ever reaching `waitAndSnapSplit`'s geometry-setting lines. A second
        probe found mutating the *returned* `frameGeometry` object's own properties
        (`w.frameGeometry.x = ...`, also from a real community example) is a silent no-op too —
        it hands back a detached snapshot, not a live-bound reference; reading the property back
        immediately confirmed the value never changed. **What actually works**: assigning a
        whole plain JS object literal to `frameGeometry` — `w.frameGeometry = { x, y, width,
        height }` — confirmed live against a real window (`kate`, then a real `brave-browser`
        window) with a before/after geometry printout. One more wrinkle found the same way:
        reading `frameGeometry` back *synchronously in the same script tick* right after
        assigning it can still show the old value (the compositor commit isn't necessarily
        immediate) — confirmed by re-checking the same window's geometry from a *separate*,
        later probe and finding the assignment had in fact taken effect — so a same-tick
        read-back isn't a reliable way to verify this API; a separate later query is.
      - **Verified live end to end** against the real bridge/extension (see the testing note
        below for why the real hotkey path itself wasn't the right tool for this one): a direct
        `QueueSplitTab` call → extension created a real second Brave window → a probe running
        the exact same plain-object `frameGeometry` code `waitAndSnapSplit` uses resized both
        windows → a later query confirmed the committed geometry. A direct `QueueMergeTabs` call
        afterward → back to one window. Cleaned up afterward with `setMaximize(true, true)` (a
        genuine `Window` method, confirmed working) to restore a sane size, since the exact
        pre-test geometry wasn't recorded up front.
      - **Testing note for future live verification of this feature**: driving this through the
        real hotkey (`kglobalaccel.invokeShortcut`, this project's usual most-faithful live test)
        turned out to be a poor fit specifically for `splitTab`/`mergeTabs`, because both
        functions gate on `workspace.activeWindow.resourceClass` — correct, deliberate behavior
        (mirrors AHK's `WinActive` early-return), but it means the test also depends on nothing
        *else* stealing focus between "activate the browser window" and "invoke the shortcut",
        which a fullscreen/exclusive app running at the same time can do. Calling
        `QueueSplitTab`/`QueueMergeTabs` directly (bypassing the resourceClass gate entirely)
        isolated the bridge/extension/geometry logic from that timing concern and is the more
        reliable way to test this specific pair of functions live in the future.
- [x] **Merge always rejoins into the real split source, and the resulting window is maximized**
      — the user's request directly: `mergeTabs` had no memory of which window a tab was split
      *from*, so with more than two windows open for a profile it picked "the other window" via
      `[...new Set(allTabs.map(t => t.windowId))].find(id => id !== sourceWindowId)` — effectively
      arbitrary, since Set/array ordering has nothing to do with which window is the real split
      origin.
      - **`background.js`** (shared by both Windows and Linux — this is browser-extension-side
        logic, not KWin/AHK-side, so the fix applies to both platforms at once) now keeps
        `splitRelations`, an in-memory `{ [profileName]: { sourceWindowId, splitWindowId } }` map.
        `splitTab` records the pair when it creates the new window; `mergeTabs` checks it first —
        if the currently-focused window is still one half of a live pair, it always collapses
        *into the recorded source*, regardless of which half is focused, falling back to the old
        "one other window" heuristic only when there's no live tracked relation (extension
        restarted, or merge invoked without a prior split). A `chrome.windows.onRemoved` listener
        drops a pair as soon as either half closes, so a stale id can't later get treated as a
        real source. Lives only in the service worker's memory by design — matches this file's
        existing `keepAlive()`-dependent state model; forgotten on a real browser/extension
        restart, same as before this feature existed.
      - **A real logic bug found and fixed via live testing, not caught by reading the code
        back**: the first version computed `sourceWindowId` (the side whose tabs get moved) with
        `focusedWindowId === rel.sourceWindowId ? rel.splitWindowId : rel.sourceWindowId` —
        backwards. Since `targetWindowId` is unconditionally `rel.sourceWindowId` in this branch,
        the "focused on the split window" case made `sourceWindowId` *also* resolve to
        `rel.sourceWindowId` — a silent self-merge no-op. Confirmed live: hitting merge while
        focused on the split-off window correctly moved focus and re-asserted maximize on the
        source (proving the command really was received and processed), but the split window's
        tab never actually moved and the window never closed — a very misleading partial-success
        signature that took a direct-D-Bus-bypass `QueueMergeTabs` call (isolating the extension
        logic from the KWin `kglobalaccel`/focus path per this feature's own testing note above)
        plus re-reading the ternary line by line to actually catch. Fix: direction is fixed by the
        tracked pair alone — `sourceWindowId = rel.splitWindowId` unconditionally, no ternary.
      - **`main.js`'s `mergeFocusedWindow`** now also polls (100ms/3s, same
        diff-the-window-list shape as `waitAndSnapSplit`, but watching a pre-merge window count
        *decrease* instead of increase) for the merge to actually complete, then calls KWin's own
        `setMaximize(true, true)` on whichever window is left focused — a redundant second pass
        alongside `background.js`'s existing `chrome.windows.update(..., state:'maximized')`
        request, not a fix for an observed failure: a live `frameGeometry`/`maximizeMode` probe
        confirmed the extension's own maximize request already lands correctly on its own. Kept
        anyway as cheap, KWin-native belt-and-suspenders, matching this file's established
        preference for KWin's own geometry APIs over trusting another process's state requests
        (same reasoning as `splitFocusedTab`'s explicit `frameGeometry` placement over simulating
        Win+Left/Right). Caught and corrected an initial version of this comment that overclaimed
        "confirmed live: not maximized" — that read turned out to be a misread of a screenshot
        spanning more than this session's one actual KWin-managed monitor (`workspace.screens`
        confirmed exactly one, 2560×1080), not a real defect; left uncorrected it would have been
        a false "confirmed live" claim sitting in shipped code.
      - **Verified live end to end, both focus directions**: real `kglobalaccel` shortcuts
        end-to-end (split, then merge with focus left on the split-off window; split again, then a
        `loadScript` probe explicitly re-focused the original source before merging) — both
        correctly rejoined the split tab into the same tracked source window, confirmed via
        `GET /debugtabs`. Maximize confirmed via both a direct KWin geometry probe
        (`frameGeometry`/`maximizeMode` matching `workspace.screens[0]`'s full area) and a
        full-screen screenshot. The old "one other window" fallback was separately exercised
        (and confirmed still correct) cleaning up stray windows left over from earlier rounds of
        this same live-testing session.
- [x] **hotkeys-ui grouped by binding type, one shared header row per group** — the user's
      complaint directly: every row repeated its own label-above-input for every field, so a
      page with a dozen `tabFocus` bindings (a real one — see below) was mostly whitespace, not
      data. Bindings are now grouped by `type` (fixed `TYPE_LABELS` order, not array order, so
      groups don't reshuffle just because of save order), each group getting one bold caption
      line plus one header row of column labels; every row under it is bare inputs only, one
      line tall instead of two.
      - **New `TYPE_COLUMNS` table**: one entry per binding type, listing exactly the fields
        that type uses (label + a `build(binding)` function returning the bare input/select) —
        the single source of truth for both `renderGroupHeader` (labels only) and
        `renderBindingRow` (inputs only), so a type's header and its own rows can't drift out of
        sync. `windowToggle`/`splitTab`/`mergeTabs` reuse `windowCycle`'s/`profileCycle`'s spec
        outright rather than repeating it, since their field lists are identical.
      - **Per-group "+ Add"** alongside the existing global "+ Add hotkey" — a natural fit once
        bindings are grouped (want one more of the same type you're already looking at), and
        also the only way to add the *first* binding of a type with none yet, since an unused
        type renders no section at all (zero bindings = zero vertical cost, not a collapsed
        header).
      - **Drag-and-drop reordering scoped to within a group** — dragging a binding onto a
        different type's row is now a no-op (guarded in `dragover`/`drop`) rather than silently
        doing nothing *visible*: array position alone no longer determines on-screen position
        once display order is grouped by type, so a cross-group drop would have moved the
        binding in the underlying array with no observable effect at all.
      - **A real, live-caught alignment bug, not just a visual nitpick**: the header/row column
        alignment trick relies on `spacer-handle`/`spacer-badge`/`spacer-type` CSS classes
        giving both a header's placeholder cell and a row's real control the same fixed width
        regardless of content. First attempt put `spacer-type` directly on the row's `<select>`
        element — which sits inside a `.field` div (`flex-direction: column`), where
        `flex: 0 0 160px` sets *height*, not width, since the main axis there is vertical, not
        horizontal like `.binding`/`.group-header`. Screenshotted live: every row rendered with
        a ~160px-tall dropdown and everything else vertically centered in the resulting gap.
        Fixed by moving the class onto the row's *wrapping* `.field` div instead (a direct,
        row-direction flex child of `.binding`) — matching how the header already did it,
        rather than putting the class on the leaf control.
      - **Verified live** against the real running server/extension, not a static mockup: opened
        the real `/hotkeys-ui` page in a fresh browser window (the existing tab's DOM was stale
        — no cache-busting way to force a hard reload without dev tools, so a disposable
        `--new-window` instance was used instead, closed again afterward) and confirmed against
        the *actual* `hotkeys.json` — 15 real bindings including a 10-entry `tabFocus` group —
        that every group renders compact, single-line rows with correctly aligned columns.
      - **User caught two more real misalignments the first round of live testing missed**
        ("the head rows' spacings aren't synced with the field widths") — both genuine flexbox
        mechanics bugs, not rendering flukes, each confirmed with a before/after screenshot of
        the same real page:
        1. The header row was missing trailing placeholder cells for the row's Dup/✕ buttons.
           Flexbox splits a row's *leftover* width (container width minus every item's own
           basis) among the `grow` columns proportionally — a header short by the row's ~80px of
           trailing button width hands its own `grow` columns (resourceClass, urlPatterns, ...)
           more leftover space than the row's actually get, so every `grow` column sat visibly
           wider in the header than the input below it. Fixed by giving `renderGroupHeader` the
           same trailing `spacer-dupe`/`spacer-remove` placeholder cells `renderBindingRow`'s
           real buttons get.
        2. `spacer-badge`/`spacer-type` (now `select-col`) were single-class selectors, but every
           real usage combines them with `.field.fixed` — a *two*-class selector, and therefore
           higher CSS specificity regardless of which rule comes later in the file. `.field.fixed`
           `{ flex: 0 0 auto }` was silently winning over the intended fixed pixel width every
           time, so e.g. the header's "Type" placeholder sized to its bare label's content width,
           not the row's real 160px `<select>`. Same root defect as the `Qt.rect` /
           `frameGeometry` snapshot-vs-reference lessons from the split/merge work above: trust
           what actually renders, not what the rule *looks* like it should do. Fixed by rewriting
           these as `.field.spacer-X` compound selectors, matching `.field.fixed`'s own
           specificity so declaration order (they come after it) decides the tie correctly.
           `spacer-handle` didn't need this — the drag handle is never wrapped in `.field`, so
           there's no competing `.field.fixed` rule to lose to.
        Re-verified the same way as the first round (a fresh disposable window against the real
        `hotkeys.json`): every header label now sits directly above its column's actual input
        across all four populated groups, `grow` columns included.
      - **`Dup` button removed** once the per-group `+ Add` button above made it redundant —
        the last real reason to duplicate an existing binding (start from a similar one instead
        of an empty row) is covered by `newBindingOfType`'s per-group `+ Add` just as well for
        same-type hotkeys, and cross-type duplication was never really what `Dup` was for
        anyway. Removed the button, its click handler, its trailing header/row placeholder cell
        (`spacer-dupe` — the row is one item shorter now, not just missing a label), and the
        no-longer-true "save/drag/dupe/remove" comment. Verified live (fresh disposable window
        again) that removing one placeholder cell from *both* sides together didn't reopen the
        same leftover-space misalignment the trailing-cell bug above was about — it doesn't,
        since header and row still match cell-for-cell either way.
      - **Type column removed too**, on the same reasoning applied one column further: with
        bindings grouped by type, a per-row Type `<select>` shows the *same* value on every row
        in a section — pure display redundancy, the group's own title already says it once. The
        real question wasn't the redundant display, though, it was the `<select>`'s other job:
        reassigning an existing binding to a different type in place (jumping it to that other
        group, Title/Key/resourceClass/etc. carried over rather than retyped) — asked the user
        given removing the column removes that capability too, confirmed removing it was fine
        (recreating under the target group's own `+ Add` is an acceptable replacement). Removed
        the `<select>`, its change handler, and its leading placeholder cell from both header and
        row (the same both-sides-together discipline as the `Dup` removal above, for the same
        alignment reason). Verified live: no "Type" column or header anywhere, remaining columns
        still line up.
      - **Real regression the Type-column removal introduced, caught by the user within
        minutes of live use**: `renderAll` only ever created a section for a type with at least
        one binding (deliberate at the time — an unused type cost zero vertical space). Once the
        Type `<select>` was gone, that became a dead end instead of just a minor space
        optimization: deleting a section's *last* binding took the whole section with it —
        title, header, and its `+ Add` button included — and with no per-row way to retype an
        existing binding into that type anymore either, there was no way back to it at all short
        of hand-editing `hotkeys.json`. Reported live: deleting the sole "Reload Hotkeys"
        `runCommand` binding made the entire Run Command section vanish, taking the binding
        itself with it (already saved by the time it was reported).
        - Fix: `renderAll` now iterates all of `TYPE_LABELS` unconditionally — every type gets
          its title/header/`+ Add` always, whether or not it currently has any bindings.
        - The lost "Reload Hotkeys" binding itself was restored too (recovered from this exact
          conversation's own earlier tool output, not guessed) — `installer.sh`'s own
          `reload-hotkeys` hotkey is load-bearing for this whole feature area, not just any
          binding, and simply making its *section* reappear wouldn't have given it back.
          Restored through the real `POST /hotkeys-config` save path (not a direct file write),
          then confirmed live via `kglobalaccel`'s own shortcut list that "Reload Hotkeys" is a
          real registered action again, not just present in `hotkeys.json`.
        - Verified live end to end: emptied the real Run Command group (server-side, via the
          same save path) and confirmed its section — header and `+ Add` included — still
          rendered with zero rows, in a fresh browser load.
- [x] **`manageAppWindows`'s launch-when-empty path never activated the window it launched** —
      reported live after switching the "Kate" binding from `windowToggle` to `windowCycle`:
      "works fine if already launched, but will not launch a new instance ... after closing it
      completely." Two distinct causes stacked on top of each other here, found one at a time:
      1. The binding had no `launchArgv` at all (missing on this specific binding, not a code
         bug — `manageAppWindows`'s documented behavior is a deliberate no-op with 0 windows and
         no `launchArgv` given). Added `["kate"]` directly via the real `POST /hotkeys-config`
         save path.
      2. Even with `launchArgv` now set, a real live test (close Kate completely, invoke the
         real `kglobalaccel` shortcut, check via a probe whether the resulting window was
         `workspace.activeWindow`) showed the window genuinely launched (`findAppWindows`
         found it) but was never the active one — confirmed visually too, sitting unfocused
         behind other windows. Root cause: `manageAppWindows`'s launch branch calls
         `LaunchCommand` and returns, with no follow-up wait-for-window-then-activate step at
         all — unlike every *other* "launch something, then find and activate its window" flow
         in this file (`waitAndActivateProfile`, `waitForTabOrOpen`), which already have one.
         Checked against `lib/window-management.ahk`'s `ManageAppWindows`: it does the exact
         same bare `Run(exePath)` with no wait/activate either — not a porting regression, this
         gap has always been there, just invisible on Windows, where a freshly hotkey-launched
         app's window generally grabs foreground on its own. KWin's focus-stealing prevention
         means a `Popen()`'d process's window does *not* get focus once it finally appears here,
         moments after the callback already returned — needed a real fix, not a faithful port
         of the original's absence of one.
      - Fix: new `waitAndActivateLaunchedWindow(resourceClass, deadline)`, called right after
        `LaunchCommand` — same 500ms/8s poll-then-activate tuning as
        `waitAndActivateProfile`/`waitForTabOrOpen`, not new numbers invented for this.
      - Verified live end to end, both fixes together: closed Kate completely, invoked the real
        "Kate" `kglobalaccel` shortcut, confirmed via a probe that the launched window was
        genuinely `workspace.activeWindow` this time (screenshotted too — Kate visibly in the
        foreground, not just reported active).
- [x] **`hotkeys.js`/`hotkeys.json` now tracked, not gitignored** — a deliberate deviation from
      the Windows side's own precedent (`lib/app-hotkeys.ahk` is gitignored there, with a whole
      pre-commit-hook-driven sanitization pipeline built specifically to keep real URLs/paths/
      profile names out of what *is* tracked, `lib/app-hotkeys.template.ahk`). Explicit ask: "for
      the meantime," a `git pull` on this port should bring the real, working hotkey config along
      with it rather than everyone starting from `hotkeys.template.js`'s placeholder examples.
      Checked the actual file content before committing rather than assuming it was fine to
      make public just because it was asked for — no secrets, no absolute filesystem paths
      currently present (the one binding that used to carry one, a `runCommand` "Reload Hotkeys"
      pointed at this exact clone's `installer.sh`, isn't in the current file at all), just
      ordinary URLs (`mail.google.com`, `ebay.com`, ...) and window resourceClasses. Removed both
      files' `.gitignore` entries and committed them as they stand — no sanitization pipeline
      built for these two the way `make-template.sh` exists for the AHK side, since that wasn't
      the ask and `hotkeys.template.js` already exists separately (hand-maintained, per its own
      long-standing follow-up note above) for anyone who wants placeholder examples instead.
      - **Superseded one turn later** by a better-reasoned version of the same goal — see
        directly below. Tracking `hotkeys.js`/`hotkeys.json` *directly* turned out to have a real
        downside the first version didn't account for: once a file is tracked, anyone else who
        clones this repo and starts personalizing that *same* tracked file risks exactly the
        merge conflicts / silently-clobbered-local-edits problems gitignoring it was always
        meant to avoid in the first place. Left as history here rather than rewritten away, same
        as every other "round 2 found the real problem" entry in this file.
- [x] **`hotkeys.js`/`hotkeys.json` gitignored again — mirrored unsanitized into their templates
      instead** — reconciles the previous entry's goal ("a `git pull` should bring the real,
      working config along") with not repeating `lib/app-hotkeys.ahk`'s own reason for staying
      gitignored on Windows (multiple people editing the *same tracked file* is a merge-conflict
      /clobbered-local-edits problem waiting to happen) by borrowing the AHK side's actual
      *mechanism* — a pre-commit hook mirroring a gitignored real file into a tracked template —
      while explicitly dropping the *sanitization* that mechanism also does there, since privacy
      was never the concern here (confirmed with the user last turn already).
      - `hotkeys.js`/`hotkeys.json` re-added to `.gitignore`, un-tracked (`git rm --cached`, kept
        on disk). `dev-scripts/make-template.sh` gained a new section: `hotkeys.js`/`hotkeys.json`
        → `hotkeys.template.js`/`hotkeys.template.json`, plain `cp`/`cat` (no sed sanitizer at
        all, unlike every other section in this script) — `hotkeys.template.js` gets a short
        prepended banner explaining what it is and that it's unsanitized (comments are valid
        JS; skipped for `hotkeys.template.json`, which has to stay parseable JSON with no
        comments allowed).
      - `hooks/pre-commit`'s trigger condition extended to fire when either Linux hotkeys file
        exists, not just the two AHK ones, and to `git add` the two new template outputs
        alongside the existing AHK ones.
      - **A real bug this exposed, not introduced but newly reachable**: `make-template.sh`'s
        AHK-generating section had *no* existence guard on `app-hotkeys.ahk` at all (unlike its
        own neighboring `config.ahk` section, which already checks) — it only ever got away with
        that because the pre-commit hook's trigger condition used to be AHK-files-only, so the
        script itself never ran anywhere lacking one. Extending that trigger to include the
        Linux files meant a pure-Linux dev box (this one — no `lib/app-hotkeys.ahk` on disk at
        all) would now hit that section on *every* commit and crash outright. Found by literally
        running the updated script here, not by inspection — fixed with the same
        `if [ -f ... ]` guard `config.ahk`'s section already had.
      - **A new secret-leak guard, not asked for explicitly but a direct consequence of removing
        sanitization**: the AHK side's existing pre-commit check blocks a commit if a
        credential-shaped pattern shows up in `app-hotkeys.ahk`'s marked-off sensitive section.
        There's no equivalent "sensitive section" concept for `hotkeys.js`/`hotkeys.json` — the
        *whole* file ships unsanitized now — so this scans each template's entire staged diff
        instead of a scoped-down section, blocking on the same category of credential-shaped
        keyword (`password`/`token`/`secret`/`api_key`/...) immediately followed by `:`/`=`.
        Verified both ways: a synthetic `api_key: sk-...` line in a throwaway git repo's staged
        diff correctly matched and would block; the real current `hotkeys.template.js`/
        `hotkeys.template.json` content (checked earlier this session — ordinary URLs and
        resourceClasses, nothing credential-shaped) does not.
      - `installer.sh`'s `ensure_hotkeys()` message updated to stop assuming the template still
        contains `YOUR_BROWSER_RESOURCE_CLASS`-style placeholders (it usually won't now) —
        checks with `grep` first rather than branching on `CHOSEN_RESOURCE_CLASS` alone, so the
        printed message stays accurate for either kind of template a given checkout might have.
      - Verified live end to end: ran `dev-scripts/make-template.sh` directly and confirmed both
        new template files were written unsanitized with the expected banner; temporarily moved
        the real `hotkeys.js` aside and re-ran `ensure_hotkeys()`'s exact new logic in isolation,
        confirming it seeds from the template with the new, accurate message and restores
        correctly afterward; ran the real `./installer.sh install` end to end again after all of
        the above with no regressions; installed the pre-commit hook for real in this clone
        (`dev-scripts/install-hooks.sh` — it hadn't been active for any of this session's many
        prior commits) so this very change's own commit exercises the real hook, not a simulation.
      - **Near-miss while testing, worth recording honestly**: running the *pre-fix* version of
        `make-template.sh` directly on this machine (before the guard existed) didn't just fail
        to generate `app-hotkeys.template.ahk` — bash's own `> "$root/app-hotkeys.template.ahk"`
        redirection truncates that file to empty as part of setting the redirection up, *before*
        `awk` ever runs, so `awk`'s subsequent failure to open the missing `app-hotkeys.ahk`
        didn't prevent the tracked template from being wiped to 0 bytes first. Caught immediately
        via `git status`/`git diff` (nothing this session skips verifying), restored with `git
        restore` before it went anywhere near a commit — but it's the concrete, already-happened
        version of exactly the risk the `if [ -f ... ]` guard exists to prevent, not a
        hypothetical one.
- [x] **Follow-up: `hotkeys.json` was never seeded at all — `ensure_hotkeys()` only ever handled
      `hotkeys.js`** — surfaced by testing this exact template-mirroring setup on a genuinely
      fresh machine for the first time (a second cachyos laptop): a fresh clone's Hotkeys UI
      showed zero bindings even after `./installer.sh install`, despite `hotkeys.js` itself
      having been correctly seeded and deployed with real, working shortcuts. Root cause: `GET
      /hotkeys-config` (the Hotkeys UI's own source of truth) reads `hotkeys.json` specifically,
      not `hotkeys.js` — and nothing in `installer.sh` had ever created that file if it didn't
      already exist, so `alttabsucks_server.py` silently fell back to an empty
      `{"bindings": []}` (a caught `OSError` on the missing file, not a crash — exactly the kind
      of failure that stays quiet until someone notices the UI looks empty).
      - This was a real, separate gap from the earlier "push was silently failing, so a fresh
        clone got a stale `hotkeys.template.js`" issue (see this session's own git-remote-auth
        troubleshooting) — fixing the push made the *content* current, but `hotkeys.json` itself
        was never being created in the first place, on any machine, stale or not.
      - Fix (`installer.sh`): new `ensure_hotkeys_json()`, mirroring `ensure_hotkeys()`'s own
        seed-once-and-never-touch-again contract exactly (seeds from `hotkeys.template.json` only
        if `hotkeys.json` doesn't already exist), called from `ensure_hotkeys()` so both
        `./installer.sh install` and `reload-hotkeys` seed it (both flow through
        `install_kwin_script` → `ensure_hotkeys`) — checked and seeded independently of
        `hotkeys.js`, since either file can go missing on its own. `build_staged_kwin_package`'s
        cleanup step also gained `hotkeys.json`/`hotkeys.template.json` alongside their existing
        `.js` counterparts — source material only, `main.js` never reads either JSON file, so
        neither belongs in the deployed KWin package.
      - **Verified live, not just by reading the diff**: confirmed `hotkeys.template.json` has no
        leftover `YOUR_...` placeholders needing a Linux-path substitution the way `hotkeys.js`'s
        `YOUR_REPO_ROOT` does (it's the same unsanitized-mirror content, already real values), and
        that `installer.sh`'s `HOTKEYS_JSON_PATH` and `alttabsucks_server.py`'s
        `HOTKEYS_CONFIG_PATH` genuinely resolve to the identical path. Then reproduced the exact
        bug end to end on the original dev machine: backed up the real `hotkeys.json`, moved it
        aside, ran `./installer.sh reload-hotkeys`, confirmed it printed the new seed message and
        recreated the file identical to `hotkeys.template.json`, confirmed `GET /hotkeys-config`
        against the real running server went from what would have been an empty list to 23 real
        bindings — then restored the original file byte-for-byte and redeployed, leaving the
        machine exactly as it was. Full Python test suite (68 tests) and `bash -n installer.sh`
        both still clean.
- [x] **Toast confirmations made required, and the whole install audited for one-shot
      reliability** — explicit ask: toasts stop being a best-effort extra (`check_toast_deps()`
      soft-skipping with a printed note if `gtk4-layer-shell` was missing, `install` still
      "succeeding" with silently no on-screen feedback for any hotkey ever) and become a hard
      requirement, checked alongside every other dependency; and a general pass over `do_install`
      to find and fix anything else standing between a fresh clone and a fully working install
      in exactly one `./installer.sh install` run.
      - `gtk4-layer-shell`'s Python-bindings check moved from the separate `check_toast_deps()`
        into `check_deps()` itself — a missing one now stops the install up front with the rest
        of the dependency list, same treatment as a missing `kpackagetool6`. `check_toast_deps()`
        removed entirely; `do_install`'s `check_toast_deps && install_toast_service` became a
        plain unconditional `install_toast_service` call. `install_toast_service`'s own internal
        fallback (unresolvable `libgtk4-layer-shell.so` path via `ldconfig`, a narrower and rarer
        case than the Python import failing) changed from a silent `return` to an `exit 1` with a
        clear message, for the same "required means required all the way down" reason.
      - **A real one-shot gap found during the audit, not assumed**: the final auth-token print
        used a flat `sleep 1` before checking whether `token.txt` existed yet. `token.txt` is
        written by the server process itself on its first run, not by anything in `installer.sh`
        — `systemctl --user enable --now` only guarantees the process has been *spawned*
        (`Type=simple`'s entire definition of "active"), not that it's gotten as far as importing
        `dbus`/`gi` and writing the file. A flat 1-second guess meant a slower first cold start
        (or, now, a slower `install_toast_service` run ahead of it) could plausibly leave a
        fresh, otherwise-successful install ending on "wait a moment, then run cat" instead of
        the token in hand — the opposite of one-shot. Replaced with an actual poll (100ms
        intervals, up to 10s) so the common case reliably gets the token printed immediately
        without guessing, with a real, more actionable failure message (pointing at
        `journalctl --user -u alttabsucks-server.service -e`) if it genuinely never appears.
      - Verified live: ran the real `./installer.sh install` end to end again after all of the
        above, confirmed it completed in ~1.3s with the toast daemon installed unconditionally
        and the token printed immediately (already-existing token, so the poll loop's very first
        check already succeeded) rather than falling through to the fallback message. Separately
        exercised the new hard-failure path itself — without touching the real, working
        `gtk4-layer-shell` install on this machine — by running `check_deps`'s exact
        dependency-detection logic in isolation against a deliberately-nonexistent GI module
        name, confirming it correctly reports the missing dependency, prints the `pacman` install
        line including `gtk4-layer-shell`, and exits non-zero.
- [x] **`alttabsucks-server.service` could start with no display environment at all — the
      launch-when-not-open codepath silently broken for every app on this exact machine, not a
      code bug** — reported live: cycling/toggling an already-open Kate/discord/vscode worked
      fine, but launching any of them fresh from closed never did. Every earlier check came back
      clean (the source fix from a previous session was intact in both `main.js` and the
      deployed KWin script, the shortcuts were genuinely registered, `hotkeys.js` genuinely had
      `launchArgv` set for all three) — even a *direct* `LaunchCommand` D-Bus call bypassing the
      KWin script entirely still failed to produce a running process, which is what actually
      pointed away from anything KWin-side and at the server itself.
      - Root cause found in `journalctl --user -u alttabsucks-server.service`: `kate` (and by the
        same mechanism, anything else `LaunchCommand`/`_spawn_detached` starts) was crashing
        instantly with `could not connect to display` / `Could not load the Qt platform plugin
        "xcb"`. Confirmed via `/proc/<server pid>/environ`: the *running* server process had
        `XDG_RUNTIME_DIR` but no `WAYLAND_DISPLAY`/`DISPLAY` at all, even though
        `systemctl --user show-environment` (the *manager's* current environment, used only for
        *newly started* services) had both set correctly. A process's own environment is fixed
        at its own start time and never updates after the fact — this service had started before
        the graphical session finished importing its display variables into `systemctl --user`,
        and every GUI app it spawned from then on inherited that same incomplete environment and
        crashed the same way, silently from the KWin script's perspective (the D-Bus call
        genuinely succeeds; the *child process* is what fails, moments later, with nothing to
        report the failure back through).
      - Root cause of the root cause: `alttabsucks-server.service`'s `[Unit]` section only had
        `After=network.target` — `alttabsucks-toast.service` already has
        `After=graphical-session.target` (needed for the exact same reason, a GTK4/Wayland app
        needing a real display to connect to), but the *server* never got that same dependency
        added, despite also spawning GUI apps via its own `LaunchCommand`. An asymmetry between
        two sibling services doing conceptually the same kind of thing, not a deliberate choice.
      - Fix: `systemctl --user restart alttabsucks-server.service` for the immediate problem
        (re-inherits the manager's by-then-correct environment); added
        `After=graphical-session.target` to `alttabsucks-server.service`'s tracked unit
        (alongside the existing `network.target`, not replacing it) so a fresh login doesn't hit
        this ordering race in the first place, matching the toast service's own proven-working
        ordering rather than guessing at a new one.
      - Verified live end to end, both apps the user could safely test with (asked to avoid the
        third, code-oss, since it's this exact session's own editor): closed Kate and Discord
        completely, restarted the server, confirmed via `/proc/<pid>/environ` that the new
        process actually has `WAYLAND_DISPLAY`/`DISPLAY` this time, then invoked both real
        `kglobalaccel` shortcuts and confirmed both actually launched (Kate additionally
        screenshotted genuinely in the foreground, exercising the earlier
        `waitAndActivateLaunchedWindow` fix's other half in the same pass).
- [x] **Follow-up: `After=graphical-session.target` alone was NOT sufficient — same bug came back
      on a real reboot** — reported live ("i rebooted and the launch app from scratch code path
      of hotkeys like ones for kate and code-oss did not launch the target apps. didn't we already
      try to address this?"). It was a fair question — the fix above was real and tested, but
      incomplete.
      - Root cause: `After=` only orders two units *within the same startup transaction* — it does
        nothing on its own to guarantee one unit even runs in the same transaction as another.
        Both services' `[Install]` sections still said `WantedBy=default.target`, so systemd pulls
        them in and starts them as part of *`default.target`'s* own transaction at login —
        entirely independent of whenever Plasma's session separately gets around to activating
        `graphical-session.target` once its own startup finishes importing the display
        environment. `After=graphical-session.target` had nothing to actually order against.
        Confirmed live, not just reasoned: after the reboot, `alttabsucks-server.service`'s
        `ActiveEnterTimestamp` was **15 seconds earlier** than `graphical-session.target`'s own —
        direct proof the server started first despite the `After=` line. The toast service, with
        the identical config, happened to start *after* on this particular boot (no visible bug
        reported for it this time) — which is exactly the problem: a race with no ordering
        guarantee, not a fix, so it was only ever going to be a matter of time before it lost the
        race visibly again, on either service.
      - Real fix: changed `[Install]` on both units from `WantedBy=default.target` to
        `WantedBy=graphical-session.target` (with `PartOf=graphical-session.target` added too, so
        they also stop cleanly with the session instead of lingering as orphans) — the documented
        `systemd.special(7)` pattern for a user service that needs the display session. This makes
        both services actually get pulled in and started *as part of* `graphical-session.target`'s
        own transaction, so `After=` finally has something real to order against. `installer.sh`'s
        `install_service()`/`install_toast_service()` now `systemctl --user disable` each unit
        right before redeploying it, so a stale `default.target.wants/` symlink from an
        already-installed older unit file gets cleaned up rather than left alongside the new
        `graphical-session.target.wants/` one.
      - Verified live: re-ran `./installer.sh install`, confirmed via `ls` that both stale
        `default.target.wants/` symlinks were gone and both new
        `graphical-session.target.wants/` symlinks existed, closed Kate completely, invoked the
        real `kglobalaccel` shortcut, and confirmed via `systemctl --user status` (showing `kate`
        as a live child process under the server's own cgroup) plus a screenshot that it actually
        launched and reached the foreground.
      - **Honestly incomplete**: this reproduces the documented systemd ordering guarantee and was
        confirmed to deploy correctly, but the previous fix *also* looked fixed until it lost the
        race on an actual reboot — a live restart can't fully stand in for that. Full confidence
        needs one more real reboot to confirm the new `[Install]` ordering actually holds at boot
        time; flagged to the user rather than claimed as fully proven.
- [x] **Toast corners rendered opaque black instead of transparent** — reported live. Root cause
      is a real GTK4/Wayland layer-shell gotcha, not anything specific to this codebase's own
      logic: `ToastWindow`'s CSS painted the solid background color *and* `border-radius`
      directly on the `window` CSS node (the toplevel `Gtk.Window` itself). That rounds how the
      window node's *own* background is drawn, but it doesn't punch real per-pixel alpha holes
      in the actual Wayland surface outside the rounded rect — a layer-shell surface's alpha
      compositing is derived from the window node specifically, so the corner regions outside
      the radius rendered as opaque (black — undefined surface content) instead of see-through.
      - Fix: the toplevel `window` node's CSS background is now unconditionally
        `background-color: transparent`, and the actual visible rounded box moved onto a *child*
        widget (`self.box`, given `set_name("toast-box")`, styled via `#toast-box` instead of
        `window`) — child widgets are always composited as textures over whatever the window
        node underneath already is, so an opaque rounded child sitting on a fully transparent
        window is what actually produces a clean rounded shape with genuinely transparent
        corners. Applied to both `show()` and `show_command_result()`'s stylesheets (the latter's
        border also moved from `window` to `#toast-box` alongside the background, so it still
        traces the same rounded shape).
      - Verified live, not just by re-reading the CSS: triggered both `ShowToast` and
        `ShowCommandResult` directly over D-Bus and screenshotted the result both times — one
        first attempt with an invalid test color (missing the leading `#` real callers always
        include, confirmed by checking `toast_colors.DEFAULT_BG`/`main.js`'s own `showToast`
        call) made the whole box vanish rather than prove anything, caught and redone correctly
        rather than left as a false signal. The corrected test showed a clean rounded rect for
        both toast modes; a pixel-level zoom into one corner (800% nearest-neighbor crop) showed
        a smooth anti-aliased curve straight from the desktop wallpaper's own color into the
        toast's background color, no black fringe anywhere.
- [x] **Toast: leftover dark pixels at the bottom two corners only, top corners clean** —
      follow-up report after the fix above ("that's a lot better! weirdly i still see a couple
      dark pixels in the very corner of each bottom corner (not the top corners)"). The
      background-color fix above only overrode that one property on `window` — GTK4's CSS
      cascade is per-property, not per-rule, so the active theme's own default `box-shadow` on
      `window` (Adwaita-style themes ship one with a downward offset, mimicking light from above)
      was still active and being rasterized into the otherwise-transparent surface, showing up as
      a faint dark cluster right at the rounded corners on the side the shadow falls toward —
      exactly the observed bottom-only asymmetry.
      - Fix: added `box-shadow: none;` alongside `background-color: transparent;` on the `window`
        rule in both `show()` and `show_command_result()`.
      - Verified live: restarted `alttabsucks-toast.service`, triggered both `ShowToast` (plain
        rounded box) and `ShowCommandResult` (rounded box + 1px border) over D-Bus, screenshotted
        each, and cropped/zoomed (800% nearest-neighbor) into all four corners of each — not just
        the two that were reported broken, to rule out a regression at the top. All eight corner
        crops (2 toast modes × 4 corners) showed a clean anti-aliased curve straight into the
        desktop background with no dark pixels anywhere.
- [ ] Settings persistence (`lib/settings.ahk` equivalent — plain config file is fine, no GUI
      required for v1)
- [x] **Linux install guide, `linux/README.md`** — a dedicated user-facing doc rather than a
      section bolted onto the root `README.md` (which stays Windows-focused), linked from both
      directions. Prerequisites, quick start (clone/install/extension/hotkeys), `installer.sh`
      action reference, known limitations (Firefox/window switcher/secrets manager/settings GUI
      not ported), and a troubleshooting section built from real failure modes hit and fixed
      earlier in this same checklist (resourceClass mismatches, the `kglobalaccel` sticky-key
      behavior, port conflicts, missing toast deps) — not speculative content.
      - **A real, previously-undocumented gotcha caught while researching for the guide, not
        assumed**: `linux/systemd/alttabsucks-server.service`'s `ExecStart` is a plain hardcoded
        `%h/git/alttabsucks/...` path — unlike the toast service, which `install_toast_service`
        templates from `YOUR_REPO_ROOT` at install time, `install_service` just `cp`s the server
        unit file verbatim, no substitution at all. Only worked out of the box cloned to exactly
        `~/git/alttabsucks`; flagged explicitly in the guide's Prerequisites at the time, then
        **fixed properly right after** (three options weighed — mirror the toast service's own
        sed-templating, a systemd drop-in override instead of rewriting the unit, or a symlink at
        `~/git/alttabsucks` pointing wherever the repo actually lives; picked the first, since
        the toast service already proves that exact approach with no downside, and the other two
        would've made these two sibling services *less* consistent with each other, not more).
        `alttabsucks-server.service`'s tracked `ExecStart` now reads `YOUR_REPO_ROOT/linux/...`
        and `install_service` gained the identical stage-into-a-tmpfile-then-sed-then-copy
        treatment `install_toast_service` already had — same pattern, not a new one. The
        Prerequisites callout was removed again once cloning anywhere genuinely worked. Verified
        live, not just re-read: re-ran `install_service`'s new logic directly, confirmed the
        deployed `~/.config/systemd/user/alttabsucks-server.service` had the real absolute path
        baked into `ExecStart` (not the placeholder), then ran the *real* `./installer.sh
        install` end to end and confirmed the same — service active, a real authenticated
        request to `GET /profiles` still returning 200 afterward.
      - Cross-checked specific command claims against the script rather than assumed from memory
        while drafting: caught that `./installer.sh stop` does *not* kill orphaned
        `alttabsucks_server.py` processes still holding the port (only `uninstall` does) — an
        early draft said otherwise for the "port already in use" case; corrected to the actual
        fix (`pkill` then `start`) after reading `do_stop`/`uninstall_service` side by side.
        Also confirmed the `kglobalaccel` sticky-key troubleshooting entry doesn't need a manual
        `qdbus6 unregister` fallback at all — `unregister_alttabsucks_shortcuts`'s prefix-based
        matching (`"AltTabSucks: "`) already unregisters *every* AltTabSucks-owned shortcut on
        every reload, orphaned ones included, not just ones still present in `hotkeys.json` —
        trimmed the fallback command out rather than document unnecessary complexity.
- [x] **Browser `resourceClass` moved from a per-binding field to one central config value** —
      the user's own observation: `profileCycle`/`tabFocus`/`splitTab`/`mergeTabs` all take a
      `profileName` (a *browser*-profile concept nothing else has), so their `resourceClass` was
      always going to be the one configured browser, never something that legitimately varied
      binding to binding — yet it was a retyped/reselected field on every single one, with nothing
      enforcing they all agreed. Asked directly: how is switching browsers actually done today,
      and (since it wasn't one command) design a concise refactor.
      - **How it worked before**: `./installer.sh configure`'s wizard already derived a real,
        live-verified window `resourceClass` (`choose_browser`'s `verify_resource_class`) — but
        only ever used it for a one-time `YOUR_BROWSER_RESOURCE_CLASS` text substitution into a
        *freshly seeded* `hotkeys.js`, then threw it away. Since the template pivoted to an
        unsanitized real mirror (no placeholder text left to substitute), that consumer had
        already been fully dead code for a while — the derived value was being computed and
        immediately discarded on every `configure` run, never persisted anywhere.
      - **Fix**: `config.py` gained `CHROMIUM_RESOURCE_CLASS`, written by `choose_browser()`
        (persisting the value it was already computing, not deriving anything new) — the same
        file `./installer.sh configure` already owns, so nothing new to remember to run.
        `hotkeys_generator.generate_binding_js`/`generate_hotkeys_js` gained a
        `browser_resource_class` parameter, used for `profileCycle`/`tabFocus`/`splitTab`/
        `mergeTabs` instead of `binding["resourceClass"]` (`windowCycle`/`windowToggle` keep
        their own per-binding field unchanged — those can target *any* app). `alttabsucks_server.py`
        reads `CHROMIUM_RESOURCE_CLASS` into `state.chromium_resource_class` alongside the
        already-existing `chromium_exe`, passes it into `generate_hotkeys_js` on
        `POST /hotkeys-config`, and layers it onto `GET /hotkeys-config`'s response as
        `browserResourceClass` — informational/read-only, never round-tripped back into
        `hotkeys.json` (the UI's `save()` always POSTs a fresh `{bindings}` it builds itself, not
        whatever a GET handed back). `hotkeys-ui.html` drops `resourceClassColumn()` from the four
        browser-scoped types' `TYPE_COLUMNS` entirely and shows the configured browser once, in a
        header readout, instead of a field on every row — red/`.warn`-styled if none is configured
        yet, so a fresh install with no browser configured is obvious rather than silently
        generating bindings client-side that the server will then reject.
      - **The one-click gap this would have otherwise left**: `choose_browser()` only ever wrote
        `config.py` — nothing re-read `hotkeys.json` and regenerated `hotkeys.js` from it, so
        switching browsers would correctly update *future* bindings but leave every *already-
        deployed* one calling with the *old* browser's resourceClass until someone happened to
        open the Hotkeys UI and hit Save at least once. Closed by having `choose_browser()` itself
        regenerate `hotkeys.js` from `hotkeys.json` (via a small inline `python3` invocation of
        `hotkeys_generator.generate_hotkeys_js`) immediately after writing the new config, if
        `hotkeys.json` already exists — deliberately *not* also redeploying the KWin script itself,
        matching `do_configure`'s own existing pattern of leaving that to an explicit `install`
        afterward. A generation failure (e.g. some unrelated already-broken binding) leaves the
        old `hotkeys.js` untouched and prints a warning rather than silently succeeding or
        half-writing a broken file.
      - Error message for the four browser-scoped types also changed to match: a binding can no
        longer be missing its *own* resourceClass (it doesn't have one to be missing), so instead
        of `binding {title} missing resourceClass` it's now "no browser configured — run
        ./installer.sh configure to set one" — pointing at the actual fix.
      - Verified live end to end, not just re-read: ran the real `./installer.sh configure` wizard
        twice — once normally (confirmed byte-identical `hotkeys.js` before/after, same browser)
        and once through the manual-entry path with a fake different browser/resourceClass,
        confirming all 18 browser-scoped `registerShortcut` calls in the real deployed
        `hotkeys.js` switched to the new value in that single command, with zero occurrences of
        the old one left — restored back to the real browser the same way afterward, confirmed
        byte-identical again. Also confirmed via `GET /hotkeys-config` that `browserResourceClass`
        reflects live state, confirmed the client-side inline script still parses
        (`node --check`), ran the full Python suite (108 tests, several new ones covering the
        missing-browser-config error path and the "leftover stale resourceClass field on an old
        binding is ignored, not silently trusted" case), and fired a real `gmail` `tabFocus`
        hotkey through the actual `kglobalaccel` → KWin → server → browser pipeline afterward to
        confirm a binding generated this new way still genuinely works, not just reads correctly.
- [x] **"All profiles" option for Cycle browser profile, with a separate launch-profile field** —
      the user's own follow-up request: the Profile dropdown couldn't express "cycle every open
      window of this browser, regardless of profile" — only one specific profile at a time — and
      asked for that as a real option, separating "what to cycle" from "what to launch fresh if
      nothing's open at all" (the latter can't just fall back to "the profile" once cycling isn't
      scoped to one).
      - `"__all__"` is the sentinel — duplicated by hand across three places that can't share a
        module (`hotkeys_generator.py`'s new `ALL_PROFILES` constant, `main.js`'s own copy,
        `shared/hotkeys-ui.html`'s own copy), each cross-referencing the other two so a future
        change to one doesn't quietly desync it from the rest — same pattern this file already
        uses for `DBUS_SERVICE`/`DBUS_PATH`/`DBUS_IFACE` between `dbus_bridge.py` and `main.js`.
      - **`main.js`**: `cycleChromiumProfile(resourceClass, profileName, launchProfileName)`
        gained a third parameter and now branches on `profileName === ALL_PROFILES` right at the
        top, delegating to a new `cycleAnyChromiumProfile(resourceClass, launchProfileName)` —
        skips the per-profile `GetActiveTitles` matching/caching entirely (there's no single
        profile to key that cache on) and just cycles `listBrowserWindows(resourceClass)`
        directly. This is exactly what the *existing* single-profile path's own
        `matching.length === 0` fallback already did as a last-resort safety net for stale/missing
        per-profile data — here it's the deliberate, primary behavior for this mode instead of an
        incidental fallback for another one. The toast can't name a specific profile the way the
        single-profile path's own does (there isn't one to name), so it just says "All profiles".
      - **`hotkeys_generator.py`**: the `profileCycle` branch now also reads `launchProfileName`,
        required (raises, pointing at the actual gap — "which one to open if nothing's running") only
        when `profileName == ALL_PROFILES`; otherwise defaults to `profileName` itself when unset
        or blank, so every binding saved before this field existed at all keeps generating
        identical output with zero migration needed — confirmed directly with a dedicated test
        asserting the 2-field-old-shape input still produces the 3-arg call, `launchProfileName`
        matching `profileName`.
      - **`shared/hotkeys-ui.html`**: new `profileCycleTargetSelect` (Profile column,
        `profileCycle` only — `tabFocus`/`splitTab`/`mergeTabs` stay on plain `profileSelect`,
        since "all profiles" isn't meaningful for a window-scoped or currently-focused-window
        operation) and `launchProfileSelect` (new "Launch profile (if none open)" column). Since
        `splitTab`/`mergeTabs` used to alias `TYPE_COLUMNS.profileCycle` directly, that alias was
        split out into its own `SPLIT_MERGE_COLUMNS` (Title/Key/Profile only) so they don't
        inherit fields that don't apply to them. "All profiles" is appended *last* in the Profile
        dropdown, not first, so a brand-new binding still defaults to a real profile, same as
        before this existed — an opt-in choice, not a new default.
      - **A real footgun caught and closed before it shipped, not just during review**: an early
        version let `launchProfileName` default independently (first real profile in the list) —
        meaning a normal, non-"all" binding could silently end up *cycling* one profile while
        *launching* a completely different one, just because the two `<select>`s happened to
        default differently, with nothing forcing them to agree. Fixed by having the Profile
        field's own `change` handler force `launchProfileName` to match it whenever the new value
        isn't `ALL_PROFILES` (deliberately overwriting any earlier divergence — cycling and
        launching the same profile is the only sane combination once you're not on "All profiles"
        anymore), covering both the very first render and every later change.
      - **A second real bug caught the same way**: that sync originally only updated
        `binding.launchProfileName` in memory — the Launch profile field is a *separate* `<select>`
        that only reads that value when it's built, so its on-screen display would silently go
        stale (still showing the old value) even though the data underneath, and what Save would
        actually send, was already correct. Fixed with a `renderAll()` call in that same branch —
        same reasoning, and the same already-proven-safe "call `renderAll()` from inside this
        element's own event handler" pattern, as the enabled-badge toggle's existing click handler.
      - Verified live end to end: real `POST /hotkeys-config` save round-trips confirmed both the
        normal case (`launchProfileName` defaults to `profileName`, e.g.
        `cycleChromiumProfile("brave-browser", "Personal", "Personal")`) and the "all profiles"
        case (`cycleChromiumProfile("brave-browser", "__all__", "Personal")`) generate correctly.
        Then, since this dev machine only has one real profile configured, used the already-proven
        split feature (not `brave --new-window`, which turned out not to actually create a second
        top-level window on this machine — confirmed via a direct KWin window-count probe before
        concluding that and switching approaches) to get two genuinely separate Brave windows,
        temporarily set the real "Cycle personal" binding to `"__all__"`, and fired the real
        deployed hotkey via `kglobalaccel` twice in a row — confirmed via a KWin `activeWindow`
        probe after each press that it correctly cycled *to* the other window and then *back*,
        proving `cycleAnyChromiumProfile` genuinely works end to end, not just that it generates
        the right JS text. Restored the real binding and merged the test window back afterward,
        confirmed the live config byte-for-byte identical to before testing. Full Python suite
        green throughout, plus a `node --check` syntax pass on both `main.js` and the extracted
        `hotkeys-ui.html` inline script.
- [x] **Steam's Cycle hotkey couldn't launch it from closed — a missing `launchArgv`, not a code
      bug** — reported live ("the launch/cycle steam shortcut is not currently working to launch
      steam from scratch"). Confirmed Steam wasn't running (`pgrep steam` empty), then found it
      immediately in the generated JS: `manageAppWindows("steam", "cycle")` — a bare two-argument
      call, no launch command at all, unlike every other `windowCycle` binding (e.g. Kate's
      `manageAppWindows("org.kde.kate", "cycle", ["kate"])`). `manageAppWindows`'s own launch
      branch is gated on `if (launchArgv)` — with it `undefined`, nothing-open silently no-ops,
      exactly the reported symptom. Not a bug: the binding was simply saved without ever filling
      in the "Launch command" field (present but left blank), most likely added at a time Steam
      happened to already be running, when a missing launch command has no visible effect at all.
      - Fix: `["steam"]` — confirmed `/usr/bin/steam` is directly on `PATH` on this machine, a
        native binary, no Flatpak wrapper needed.
      - Verified live end to end: confirmed Steam genuinely closed first, added `launchArgv` via
        the same `POST /hotkeys-config` round-trip this whole session already uses for live
        testing, confirmed the regenerated `hotkeys.js` now reads
        `manageAppWindows("steam", "cycle", ["steam"])`, then fired the real deployed hotkey via
        `kglobalaccel` — the actual Steam process came up (`pgrep` showing the real client/
        webhelper/runtime processes) and its window appeared with the correct `steam` resourceClass
        (confirmed via a direct KWin window probe, then a screenshot showing Steam's own Library
        genuinely on screen). One honest wrinkle, not silently glossed over: the very first
        post-launch check read `active=false` — Steam is a notably slow starter, and its window
        can take longer to actually appear than `waitAndActivateLaunchedWindow`'s shared 8s
        poll-then-activate window (the same mechanism already proven for faster-starting apps like
        Kate/Discord) accounts for. A second hotkey press once the window already existed
        confirmed the ordinary "already open, activate/cycle" path works correctly
        (`active=true`), so nothing about *that* mechanism is actually broken — just a possible
        gap specific to how long Steam itself takes to show up on a cold start, not something the
        user asked to be tuned further here.
- [x] **Follow-up: Shelly's Cycle hotkey had the exact same missing-launch-command gap** —
      reported live right after the Steam fix ("same issue with the shelly shortcut"). Not
      identical in shape, worth actually checking rather than assuming: Steam's binding had no
      `launchArgv` key at all, Shelly's had one but as an empty array (`"launchArgv": []`) — both
      falsy in JS/Python, so both hit `manageAppWindows`'s `if (launchArgv)` gate the same way and
      generated the same argument-less `manageAppWindows("com.shellyorg.shelly", "cycle")` call.
      Confirmed via `pgrep` that the main Shelly app itself wasn't running (only its separate
      `shelly-notifications` tray helper was, from a different `.desktop` file) — a real
      launch-from-scratch gap, not a stale assumption.
      - Fix: `["shelly-ui"]`, confirmed via `which shelly-ui` — the same binary name this
        session's earlier resourceClass-typeahead work already surfaced as Shelly's
        `resourceName` (`com.shellyorg.shelly` / `shelly-ui`), directly on `PATH`, no Flatpak
        wrapper.
      - Verified live end to end the same way as Steam's fix: `POST /hotkeys-config` round-trip,
        confirmed regenerated `hotkeys.js`, real `kglobalaccel` press — the actual `shelly-ui`
        process came up (`pgrep`) and its window appeared with the correct
        `com.shellyorg.shelly` resourceClass. Same honest wrinkle as Steam: `active=false` on the
        very first post-launch check, `active=true` confirmed on a second press once the window
        already existed and a screenshot showing it genuinely in the foreground — not a broken
        mechanism, same timing characteristic already noted for Steam.
- [x] **Follow-up: Bitwarden had the exact same gap, plus a real solution for it going forward —
      auto-suggesting the launch command instead of requiring it typed in by hand** — reported
      live ("same issue with the shelly shortcut" → "same issue with the bitwarden shortcut"),
      then asked directly for a proper fix to the underlying pattern, not a third one-off patch.
      - Bitwarden's own binding: `"launchArgv": []`, same shape as Shelly's, same fix
        (`["bitwarden-desktop"]`, from `bitwarden.desktop`'s `Exec=`). Verifying it live surfaced a
        real methodology gap of its own: the first "confirm it's actually closed" check
        (`pgrep -a bitwarden`) came back empty even though Bitwarden was genuinely already
        running (since Sep20) — `pgrep` matches against the kernel-truncated `comm` name, which
        for an Electron app launched as `/usr/lib/electron39/electron /usr/lib/bitwarden/app.asar`
        is "electron", not "bitwarden" at all, so a naive check silently missed it. Caught before
        it produced a false "confirmed launch from scratch" — the fix's actual live verification
        used `pkill -f`/`ps aux` (matching against full command lines, not truncated `comm`)
        instead, genuinely closed it, and confirmed it genuinely relaunched.
      - **Root cause, one level up**: every one of these three had a real, standard place its
        correct launch command already lived — the system's own `.desktop` files
        (`/usr/share/applications`), which every Linux launcher/dock/menu already reads for
        exactly this purpose. Nothing in this codebase had ever looked there; a hotkey's Launch
        command field was purely something a human had to already know (or go look up) and type
        in by hand, with no visible consequence to leaving it blank until the exact moment the
        app was actually closed and the hotkey silently did nothing.
      - New `linux/server/launch_command_suggester.py`: parses `.desktop` files (own
        `parse_desktop_entry`, unit-tested independent of any real filesystem) from the standard
        XDG data directories, with a hardcoded fallback (`/usr/local/share:/usr/share`) plus
        Flatpak export paths always checked regardless — confirmed live that
        `XDG_DATA_DIRS`/`XDG_DATA_HOME` are simply unset in this server's actual `systemd --user`
        environment on this machine, the same kind of environment-doesn't-propagate-the-way-
        you'd-hope gap this project has hit more than once already (the `graphical-session.target`
        entries above). `suggest_launch_command(resource_class, entries)` matches in priority
        order: (1) exact `StartupWMClass` (case-insensitive), (2) the launch command's own binary
        name matching resourceClass's last dot-segment, exactly or as a prefix in either
        direction, guarded to both strings being ≥3 characters so a short one can't loosely
        prefix-match half the installed system.
      - **Two real, live-caught bugs in the matching heuristic itself, not just in the bindings it
        was meant to fix** — exactly why this got verified against this machine's *real* installed
        apps before being called done, not just its own synthetic unit tests:
        - Querying `steam` returned `['steam', 'steam://rungameid/70']` — a *specific Half-Life
          shortcut*, not the real launcher. Steam auto-generates one `.desktop` file per installed
          game, and every single one shares the exact same binary name as the real
          `steam.desktop` entry; a plain first-match-wins pass 2 could land on any of them,
          purely by directory-scan order. Fixed by ranking candidates instead of first-match-wins:
          fewest leftover argv tokens first (a bare launch command outranks one carrying a
          specific deep-link/URI/target — exactly what marks a *specific*-shortcut rather than a
          generic one).
        - Querying `com.shellyorg.shelly` returned `['/bin/sh', '-c', 'sleep 3 && arch-update
          --tray']` — a completely unrelated Arch update-notifier tray icon. Its binary is `sh`
          (2 characters); `"shelly".startswith("sh")` is trivially true of nearly anything, so the
          existing "resourceClass segment ≥3 chars" guard wasn't enough on its own — the *other*
          string being compared needs the same floor. Fixed by requiring both strings ≥3
          characters, not just the resourceClass segment.
        - A **third** live-caught ambiguity, resolved without excluding anything outright: once
          the length-guard fix above correctly ruled out the arch-update false match, Shelly's
          *own* real background helper (`com.shellyorg.shelly-notifications.desktop`,
          `Exec=/usr/bin/shelly-notifications`) still tied with the real `shelly-ui` entry — same
          argv length, nothing left to rank on. Its one distinguishing field, `NoDisplay=true`,
          was originally going to be treated as an outright exclusion filter, then deliberately
          reconsidered: plenty of legitimately-launchable entries are hidden from menus without
          being any less launchable, so excluding on it outright risked eliminating genuinely
          correct matches elsewhere. Used as a ranking tiebreak instead (`NoDisplay=false` before
          `NoDisplay=true`) — resolves this exact case without ever discarding an entry that might
          still be the best available answer if nothing better exists.
      - `GET /suggest-launch-command?resourceClass=...` (behind the same auth check as every other
        endpoint) returns `{"argv": [...] | null}`; server-side, best-effort, scanned fresh per
        request (no caching — `.desktop` files essentially never change mid-session, and this is
        only ever hit interactively, never a hot path).
      - `shared/hotkeys-ui.html`: `resourceClassColumn` (windowCycle/windowToggle only — the only
        types with a Launch command field at all) now fires the suggestion lookup on `blur`, and
        only ever fills the field when it's currently empty — never overwrites a value the user
        already set, the same "don't second-guess an explicit choice" spirit as every self-
        initializing `<select>` elsewhere in this file.
      - Verified at every layer, not just the unit tests: 27 new `launch_command_suggester.py`
        tests plus live spot-checks against this machine's real, installed `.desktop` files for
        all 6 currently-configured `windowCycle` apps (confirmed each now resolves correctly,
        including the two fixed real-world ambiguities); 4 new server tests for the endpoint
        (patched `load_desktop_entries` rather than depending on what happens to be installed);
        and — since this is genuinely new interactive client-side behavior, not just generated
        text — a full headless DOM replay (jsdom, installed fresh into the scratchpad rather than
        the repo) against the **real running server**: loaded the real served page, pasted the
        real token exactly like a human would (`input` then `change`, matching the field's own
        listeners), clicked the real "+ Add" button for App windows, typed a fresh
        `com.shellyorg.shelly` resourceClass into the new row, dispatched `blur`, and confirmed
        the real `/usr/bin/shelly-ui` suggestion actually landed in that row's Launch command
        field on screen — not a mocked fetch, the genuine `GET /suggest-launch-command` round-trip
        against the real server. (Playwright's own browser wasn't installed in this environment
        and installing it was out of scope for one test; jsdom was already this project's
        established technique for exactly this kind of headless client-side verification.)
        Confirmed afterward the real saved `hotkeys.json` was untouched (the test only clicked
        into the DOM, never Save) — 25 bindings before and after, no stray entry left behind. Swept
        every remaining `windowCycle`/`windowToggle` binding by hand afterward and confirmed none
        of the other four have the same missing-`launchArgv` gap.

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
- [x] **Real physical keypresses confirmed working**: `Ctrl+Alt+Shift+E` ("Toggle File Manager")
      correctly focuses a backgrounded Dolphin window when pressed for real — the first
      confirmation all session that didn't go through `kglobalaccel invokeShortcut` (which
      bypasses the real key-press → dispatch path entirely, unlike every prior test). The
      `allShortcutInfos()` "empty active keys" oddity investigated alongside this was a red
      herring, not a real problem — no need to chase it further.
  - **What it surfaced instead**: pressed with no Dolphin window open at all, nothing happens —
    this is empirical confirmation of the already-tracked "launch when nothing's open" gap (see
    `manageAppWindows`'s TODO and the Phase 2 process-spawn escape-hatch item above), not a new
    bug. First time that gap's been hit via a real keypress rather than just reasoned about.
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
