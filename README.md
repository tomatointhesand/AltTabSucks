# AltTabSucks

ATS is the alt-tab of the future: a keyboard shortcut based solution for app-specific window focus control, profile-aware URL-based browser tab focus control, and more.

**Features:**
- **App window management** — cycle or toggle any app's windows with a single hotkey; launch it if it isn't running
- **Browser tab focus** — jump to a tab by URL pattern for a given browser profile; opens the URL if no matching tab exists
- **Browser profile cycling** — cycle through all windows for a given browser profile, or across every profile at once
- **Split/merge tab snapping** — tear the active tab into its own window and snap both halves side-by-side; merge them back with another hotkey
- **Hotkeys config page** — a local web page (`http://localhost:9876/hotkeys-ui`) to add and edit all of the above, with a key recorder; saving applies immediately
- **Tab search** (Linux) — a Quick Tabs-style popup (Ctrl+Alt+Shift+A) over open tabs in every profile, recently closed tabs and bookmarks; Enter goes there, Ctrl+W closes a tab
- **Typeahead window switcher** (Windows) — an optional Alt+Tab replacement: type to filter open windows by app or title, with a live preview. Off by default; turn it on in Settings (Ctrl+Alt+Shift+,)

**Platforms:**

| | Windows | Linux (KDE Plasma 6, Wayland) |
|---|---|---|
| Browsers | Brave, Chrome, Edge, Vivaldi, Opera / Opera GX, Firefox | Chromium-family (Brave, Chrome, Edge, Vivaldi, Chromium) |
| Built on | AutoHotkey v2 + PowerShell server | KWin script + Python server |
| Install guide | [Windows](#windows) (below) | [linux/README.md](linux/README.md) |

Both use the same browser extension (`BrowserExtension/`) and the same hotkeys config page (`shared/hotkeys-ui.html`).

---

## Windows

### Quick Start

#### 1. Install prerequisites

**PowerShell 7.6+** is required:

```powershell
winget install AutoHotkey.AutoHotkey
winget install Microsoft.PowerShell
winget install Git.Git
```

#### 2. Clone the repo and run the installer

```powershell
cd "$env:USERPROFILE\Downloads"
git clone https://github.com/tomatointhesand/AltTabSucks
```

Then **double-click `Install.bat`** in the cloned folder. It will prompt for UAC (required to register the scheduled task) and display an auth token when done — **copy it to clipboard**. (Also saved to `Server\token.txt` for future reference.)

<details>
<summary>Advanced: run from PowerShell instead</summary>

```powershell
cd AltTabSucks
pwsh -ExecutionPolicy Bypass -File .\installer.ps1 -Action install
```
</details>

#### 3. Install and configure the browser extension

<details>
<summary>Chrome-like (Brave, Chrome, Edge, Opera)</summary>

1. Go to your browser's extensions page (e.g. `brave://extensions`, `chrome://extensions`)
1. Enable **Developer mode** (top-right toggle)
1. Click **Load unpacked** and select the `AltTabSucks/BrowserExtension` folder
</details>

<details>
<summary>Firefox</summary>

1. Go to `about:addons`
1. Install `AltTabSucks/AltTabSucks-firefox.xpi`
</details>

Open the extension **Options** and set:
- **Auth token** — paste the token from the installer, then click ↺ to refresh the profile dropdown
- **Profile name** — select the active profile from the dropdown
  - Firefox: see **about:profiles**
  - Chrome-like: the top-right Profile menu shows the active profile name

After the first install, everything starts automatically at logon. `Ctrl+Alt+Shift+'` restarts the server and reloads AltTabSucks (only needed after code changes — hotkey changes saved on the config page apply on their own).

#### 4. Try the starter hotkeys, then make them yours

On first launch, if `lib\app-hotkeys.ahk` has no hotkeys yet, AltTabSucks adds a set of suggested ones to it (from `lib\hotkeys.template.json`, using your browser's default profile) and shows a notification:

| Hotkey | Does |
|---|---|
| Ctrl+Alt+/ | Open the Hotkeys config page |
| Ctrl+Alt+Shift+B | Cycle your browser windows |
| Ctrl+Alt+Shift+G / C / Y / M | Jump to (or open) Gmail / Calendar / YouTube / Maps |
| Alt+X / Alt+Z | In the browser: split the tab into its own window / merge it back |
| Ctrl+Alt+Shift+N | Show/hide Notepad |
| Ctrl+Alt+Shift+Enter | Cycle Windows Terminal windows |
| Ctrl+Alt+Shift+Down | Open Downloads |

Open your browser and switch tabs once so the extension reports them, then try a few.

**To change them, press Ctrl+Alt+/** (or tray menu → Hotkeys UI), paste your auth token (`Server\token.txt`), and add or edit app-window / tab-focus / profile-cycle / split / merge / run-command hotkeys with a key recorder and a running-process typeahead. The page shows the hotkeys in `lib\app-hotkeys.ahk` itself: every single-line hotkey it recognizes, whether you wrote it by hand or saved it from the page. Saving rewrites just those lines, leaves the rest of the file alone (your own functions, multi-line hotkeys, comments) and keeps the previous version as `app-hotkeys.ahk.bak`; AltTabSucks then reloads itself within a second. Editing the file by hand works too. A change that wouldn't load is reported in a notification instead of reloading.

The config heals itself: a hotkey that's no longer valid (for example after an update removes or changes an action) is flagged on the page and removed on the next save, and a save drops and reports anything invalid or any key bound twice instead of writing it. Upgrading from the earlier version, where the page saved to `lib\hotkeys.json`: those hotkeys are moved back into `app-hotkeys.ahk` on the first start.

### What the installer does

`installer.ps1 -Action install`:

1. Registers a Task Scheduler task named **AltTabSucks** that runs `AltTabSucksServer.ps1`:
   - Starts automatically at logon (runs hidden, no console window)
   - Runs with elevated privileges so `HttpListener` can bind to port 9876
2. Writes `AltTabSucks.bat` to your `shell:startup` folder so `AltTabSucks.ahk` launches automatically on future logons.
3. Creates `lib\app-hotkeys.ahk` from the template if you don't have one yet, and deletes `lib\config.ahk` so the browser is detected again on the next launch (see below).
4. Disables the **Ctrl+Alt+Win+Shift** shortcut that opens Copilot/Office by redirecting the `ms-officeapp` protocol handler to a no-op (`rundll32`).
5. Launches `AltTabSucks.ahk` immediately so the current session is live without a logon cycle.

### Browser selection

On first launch (or after reinstalling), AltTabSucks scans for installed browsers and presents a choice dialog. Supported: **Brave, Chrome, Edge, Vivaldi, Opera / Opera GX, Firefox**. The choice is saved to `lib/config.ahk` (gitignored). To switch browsers later, re-run the installer — it deletes `lib/config.ahk` so the choice dialog reappears on next launch.

### Managing the server task

```powershell
.\installer.ps1 -Action status    # Check current state (Running / Ready / Disabled)
.\installer.ps1 -Action start     # Start manually (if stopped)
.\installer.ps1 -Action stop      # Stop task and kill orphaned processes
.\installer.ps1 -Action restart   # stop + start, waits until the server answers (what Ctrl+Alt+Shift+' runs)
.\installer.ps1 -Action uninstall # Stop the server, remove task and startup script
```

You can also manage it in **Task Scheduler** (`taskschd.msc`) under **Task Scheduler Library > AltTabSucks**.

To run the server manually without a task:

```powershell
.\Server\startServer.ps1
```

### Troubleshooting

**Task registers but does not reach Running state**

Open Event Viewer: `eventvwr.msc` → **Windows Logs > Application**, or **Applications and Services Logs > Microsoft > Windows > TaskScheduler > Operational**.

**Port 9876 already in use**

```powershell
.\installer.ps1 -Action stop
# or find the PID manually:
netstat -ano | findstr :9876
# then: taskkill /PID <pid> /F
```

**Extension shows "server offline"**

- Confirm the task is running: `.\installer.ps1 -Action status`
- Check the extension Options page has the correct profile name set

**Extension shows "server: error (403)"**

Auth token mismatch. Retrieve the correct token and paste it into extension Options:

```powershell
Get-Content ".\Server\token.txt"
```

**Extension shows "server offline" but the task is Running**

The port may be held by an orphaned process:

```powershell
.\installer.ps1 -Action restart
```

---

## Linux (KDE Plasma 6)

Same idea, rebuilt on a KWin script and a small Python server: a `systemd --user` service instead of Task Scheduler, no elevation needed, Chromium-family browsers only for now. Install, managing the service, and troubleshooting are all in **[linux/README.md](linux/README.md)**:

```bash
git clone https://github.com/tomatointhesand/AltTabSucks ~/git/alttabsucks
cd ~/git/alttabsucks
./installer.sh install
```

---

## For Developers

**Triggering template regeneration**

The pre-commit hook (`hooks/pre-commit`) runs `dev-scripts/make-template.sh` automatically on every commit, keeping the templates in sync with your gitignored local files: `lib/app-hotkeys.template.ahk` and `lib/config.template.ahk` (sanitized: URLs, paths and profile names redacted) and, on Linux, `hotkeys.template.js` (an unsanitized copy, checked for anything that looks like a credential). After editing `lib/app-hotkeys.ahk`:

```bash
git commit --amend --no-edit
# Hook fires, regenerates the templates, stages them into the amend automatically.
```

To regenerate manually without committing:

```bash
./dev-scripts/make-template.sh
```

Run `bash dev-scripts/install-hooks.sh` once after cloning to activate the hook.

**Running the tests**

Everything runs from a Linux checkout; the Windows parts run under Wine, portable PowerShell, or a local Windows 11 VM.

| Suite | Command | Covers |
|---|---|---|
| Linux server, toast | `python3 -m unittest discover -s linux/server/tests` and `-s linux/toast/tests` | The Python server and its endpoints, `hotkeys.js` parsing/rewriting (`hotkeys_generator.py`), launch-command suggestions, profile discovery, toast colors |
| AHK logic | `bash dev-scripts/run-ahk-tests.sh` | Pure AHK decision logic (`tests/ahk/`, e.g. which Explorer window a folder hotkey should use). Runs under Wine on Linux, fetching a portable AutoHotkey v2 into its own Wine prefix on first use; natively from Git Bash on Windows |
| Windows server logic | `bash dev-scripts/run-ps-tests.sh` | `Server/AppHotkeys.ps1`: parsing and rewriting `app-hotkeys.ahk` (`tests/ps/`). Uses `pwsh` if installed, else fetches portable PowerShell 7 on first use |
| Real Windows | `bash dev-scripts/run-windows-tests.sh` | The two suites above natively (PowerShell 7, what the server runs on), plus end-to-end tests on a Windows desktop: install and first-run dialogs, the Hotkeys UI and its page in Edge, tab focus / profile cycling / split / merge through the extension, Explorer folder hotkeys, uninstall. Needs a one-time VM setup: [tests/windows/README.md](tests/windows/README.md) |

Things that need a real Windows shell (COM, real windows, `WinActivate`) only show up in the last one, so keep testable decision logic in its own pure file (like `lib/explorer-logic.ahk`) where the faster suites can reach it.

**Packaging the Firefox extension**

```powershell
# Unsigned zip (for local testing via about:debugging):
.\dev-scripts\package-firefox-extension.ps1

# Signed xpi (auto-increments patch version, outputs AltTabSucks-firefox.xpi):
.\dev-scripts\package-firefox-extension.ps1 -Sign
```

Requires Node.js (offered via `winget` if missing) and AMO credentials (prompted on first run, stored in `.amo-credentials`).
