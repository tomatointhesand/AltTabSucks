# AltTabSucks — Linux (KDE Plasma)

The Linux port of AltTabSucks, built for **KDE Plasma 6 on Wayland**. Same core idea as the
Windows version — keyboard-driven app window cycling/toggling and profile-aware, URL-based
browser tab focus — reimplemented on top of KWin's scripting API and a small Python bridge
server instead of AutoHotkey.

**Currently supported:** Chromium-family browsers only (Brave, Chrome, Edge, Vivaldi, Chromium —
tested against Brave). Firefox is not ported to Linux yet (see **Known limitations** below).

**Not this file:** for the Windows install, see the [root README](../README.md). For the
day-by-day engineering log of how this port was built — every bug found, every design decision,
and why — see [`alttabsucks_linux_porting_checklist.md`](../alttabsucks_linux_porting_checklist.md).

---

## Prerequisites

- **KDE Plasma 6** — this relies on `kpackagetool6`/`qdbus6`/`kwriteconfig6` specifically (Qt6
  tools), not Plasma 5's `kpackagetool5`/`qdbus`/`kwriteconfig5`. Wayland is assumed throughout;
  it hasn't been tested under X11.
- **Python 3**, plus the `dbus` and `gi` (PyGObject) modules, and **`gtk4-layer-shell`** (the
  on-screen toast confirmation after a hotkey fires — required, not optional, so you always get
  feedback that a hotkey actually did something). On Arch:
  ```bash
  sudo pacman -S python-dbus python-gobject gtk4-layer-shell
  ```
  (the `kpackagetool6`/`qdbus6`/`kwriteconfig6` trio and `systemctl` all come with a normal KDE
  Plasma install already.)
- **git**, to clone this repo. Clone it wherever you like — `installer.sh` bakes the actual
  clone path into the systemd units it installs, no fixed location required.

`./installer.sh install` checks all of the above up front and refuses to start if any are
missing (with exactly what to install), rather than partway through leaving you with, say, a
working server but silently no toast daemon.

---

## Quick Start

### 1. Clone and run the installer

```bash
git clone https://github.com/tomatointhesand/AltTabSucks ~/git/alttabsucks
cd ~/git/alttabsucks
./installer.sh install
```

No `sudo`/UAC needed anywhere — `systemd --user` and `kpackagetool6` are both ordinary per-user
operations, unlike Windows' Task Scheduler + elevation dance.

This walks you through an interactive **browser picker** (autodetects Brave/Chrome/Edge/
Vivaldi/Chromium user-data directories, and — if that browser happens to be open right now —
double-checks its real window `resourceClass` against a live window rather than trusting a
guessed table), then:

1. Installs and starts the bridge server as a `systemd --user` service (`alttabsucks-server`),
   listening on `localhost:9876` — same port as Windows.
2. Installs and enables the KWin script that owns your global hotkeys.
3. Installs the toast daemon.
4. Prints an **auth token** at the end — copy it (also saved to `Server/token.txt` for later).

### 2. Load the browser extension

Same extension as Windows, loaded the same way:

1. Go to your browser's extensions page (e.g. `brave://extensions`)
2. Enable **Developer mode**
3. **Load unpacked** → select the `BrowserExtension/` folder in this clone

Open the extension's **Options** page and set:
- **Auth token** — paste the token the installer printed
- **Profile name** — pick from the dropdown (Linux self-discovers your browser's profiles each
  time the server starts — unlike Windows, there's no `P1`/`P2` variable to set by hand anywhere;
  a profile added after the server's already running needs a restart, `./installer.sh stop &&
  ./installer.sh start`, to show up)

### 3. Add your hotkeys

Unlike `lib/app-hotkeys.ahk` on Windows, `hotkeys.js`/`hotkeys.json` are **tracked, not
gitignored** — for the meantime, this repo's own real hotkey config comes along with a clone,
rather than everyone starting from placeholder examples. If `hotkeys.js` is somehow missing (a
very first install with a repo layout predating this, or a manual delete), it's seeded from
`hotkeys.template.js` instead. Two ways to edit either file:

**The Hotkeys UI (recommended)** — with the server running, open
**`http://localhost:9876/hotkeys-ui`**, paste your auth token, and edit bindings there. Saving
regenerates `hotkeys.js` and redeploys the KWin script automatically — no terminal step needed.
Bindings are grouped by type (app window cycling/toggling, browser profile cycling, tab focus,
split/merge, run-command), and the `resourceClass` field offers a live typeahead sourced from
whatever's actually running right now — the easiest way to find an app's `resourceClass` is
just to launch it once and start typing its name into that field.

**By hand** — edit `hotkeys.js` directly (see its own comments, and `hotkeys.template.js` for
every binding type with inline docs), then run `./installer.sh reload-hotkeys` to deploy.

Either way, the default **`Ctrl+Alt+Shift+'`** reloads hotkeys without a terminal at all (the
Linux equivalent of `AltTabSucks.ahk`'s built-in `^!+'::Reload`) — it's an ordinary
`runCommand` binding pointed at `installer.sh reload-hotkeys`, editable/removable like any other.
If your keyboard can't sense Shift+apostrophe held together (a real hardware limitation on some
keyboards' key matrices, not a bug — shows up as the hotkey silently never firing), rebind it to
something without Shift, e.g. `Ctrl+Alt+'`.

---

## Managing the service

```bash
./installer.sh status           # server + toast daemon + KWin script load state, plus the auth token
./installer.sh start            # start the server (and toast daemon, if installed)
./installer.sh stop             # stop them via systemd
./installer.sh configure        # re-run just the browser picker (e.g. after switching browsers)
./installer.sh reload-hotkeys   # rebuild + redeploy the KWin script from hotkeys.js
./installer.sh uninstall        # remove the service, toast daemon, and KWin script — also kills
                                 # any orphaned alttabsucks_server.py still holding port 9876,
                                 # which plain `stop` does not
```

You can also inspect the service directly:

```bash
systemctl --user status alttabsucks-server.service
journalctl --user -u alttabsucks-server.service -f   # live server logs
```

`uninstall` deliberately leaves `linux/server/config.py` and `Server/token.txt` in place (same
as the Windows uninstaller leaving `token.txt`) — remove them by hand for a clean slate.

To switch which browser AltTabSucks manages, run `./installer.sh configure`, then
`./installer.sh install` to redeploy the server with the new config.

---

## Known limitations

Ported so far: app window cycling/toggling (with auto-launch if nothing's open), browser profile
cycling, URL-pattern tab focus, split/merge browser windows, the Hotkeys UI, and toast
confirmations. Not yet:

- **Firefox** — Windows' `lib/firefox.ahk` equivalents aren't ported. Only Chromium-family
  browsers work on Linux right now.
- **Window switcher** (`lib/window-switcher*.ahk`'s typeahead Alt+Tab replacement) — not started.
- **Secrets manager** (`lib/secrets.ahk`/gopass integration) — deliberately not ported as-is;
  revisiting with a different approach later.
- **Settings GUI** — no equivalent of `lib/settings.ahk`'s settings window; everything's
  configured via `config.py`/`hotkeys.js`/the Hotkeys UI page directly.

See the [porting checklist](../alttabsucks_linux_porting_checklist.md) for the full, current
status of every feature area.

---

## Troubleshooting

**A hotkey does nothing**

Almost always a `resourceClass` mismatch — the single most common failure mode, and it fails
*silently* (no error anywhere, the hotkey just never matches a window). KDE apps in particular
often use reversed-domain names (`org.kde.dolphin`, `org.kde.kate`) rather than their binary
name. Open the Hotkeys UI, launch the target app, and check what the `resourceClass` typeahead
actually suggests for it — don't guess.

**Changed a hotkey's key, but the old key still fires (or the new one does nothing)**

`kglobalaccel` locks a shortcut's key to whatever it was on its *first-ever* registration under
that binding's title — by design, so a later script update can't clobber a customization you
made yourself in System Settings. Both saving from the Hotkeys UI and `./installer.sh
reload-hotkeys` already work around this on every single deploy (unregistering every
AltTabSucks-owned shortcut, by its `"AltTabSucks: "` friendly-name prefix, before re-registering
from scratch) — so this shouldn't come up at all through normal use. If it somehow does anyway,
`./installer.sh reload-hotkeys` is the fix.

**Extension shows "server offline"**

- `./installer.sh status` — confirm the server's actually running
- Confirm the extension Options page has the right profile name

**Extension shows a 403 / auth error**

Token mismatch. Get the real one and re-paste it into extension Options:
```bash
cat ~/git/alttabsucks/Server/token.txt
```

**Port 9876 already in use**

Plain `stop` only stops the systemd unit, so an orphaned process from before it was managed by
systemd (or a crash that left one behind) can still be holding the port:

```bash
pkill -f "python3 .*alttabsucks_server\.py"
./installer.sh start
```

**KWin script doesn't seem to be loaded**

```bash
./installer.sh status   # check the "loaded:" line
./installer.sh reload-hotkeys
```

**No toast appears after a hotkey fires**

`gtk4-layer-shell` is a required dependency (`./installer.sh install` refuses to run at all
without it), so if you got this far it should be installed and running. Check
`systemctl --user status alttabsucks-toast.service` — every hotkey's underlying action (window
focus, tab switch, ...) still works even if the toast daemon itself is somehow down, so this is
worth a look but isn't blocking anything else.
