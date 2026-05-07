# AltTabSucks

ATS is the alt-tab of the future: a keyboard shortcut based solution for app-specific window focus control, profile-aware URL-based browser tab focus control, and more. Supports Brave, Chrome, Edge, Opera, and Firefox at the moment. Windows only for now.

**Features:**
- **App window management** — cycle or toggle any app's windows with a single hotkey; launch it if it isn't running
- **Browser tab focus** — jump to a tab by URL pattern for a given browser profile; opens the URL if no matching tab exists
- **Browser profile cycling** — cycle through all windows for a given browser profile
- **Split/merge tab snapping** — tear the active tab into its own window and snap both halves side-by-side; merge them back with another hotkey

---

## Quick Start

### 1. Install prerequisites

**PowerShell 7.6+** is required:

```powershell
winget install AutoHotkey.AutoHotkey
winget install Microsoft.PowerShell
winget install Git.Git
```

### 2. Clone the repo and run the installer

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

### 3. Install and configure the browser extension

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

After the first install, everything starts automatically at logon. To reload the AHK script manually: `Ctrl+Alt+Shift+'`.

### 4. Open lib\app-hotkeys.ahk

1. Set the `P1` var to the same profile name as in the extension Options. Set `P2` for a second browser profile if you use one.
1. Open your browser and switch tabs to hydrate the extension's local server.
   - **Press Ctrl+Alt+Shift+/** to see a quick reference for all mapped hotkeys
   - Press Ctrl+Alt+Shift+L to see a debug readout of your current tab state
1. Edit hotkey triggers, add apps, URLs, etc. as desired.

---

## More Info

`installer.ps1 -Action install` does four things:

1. Registers a Task Scheduler task named **AltTabSucks** that runs `AltTabSucksServer.ps1`:
   - Starts automatically at logon (runs hidden, no console window)
   - Runs with elevated privileges so `HttpListener` can bind to port 9876
2. Writes `AltTabSucks.bat` to your `shell:startup` folder so `AltTabSucks.ahk` launches automatically on future logons.
3. Disables the **Ctrl+Alt+Win+Shift** shortcut that opens Copilot/Office by redirecting the `ms-officeapp` protocol handler to a no-op (`rundll32`).
4. Launches `AltTabSucks.ahk` immediately so the current session is live without a logon cycle.

---

**Browser selection**

On first launch (or after reinstalling), AltTabSucks scans for installed browsers and presents a choice dialog. Supported: **Brave, Chrome, Edge, Opera, Firefox**. The choice is saved to `lib/config.ahk` (gitignored). To switch browsers later, re-run the installer — it deletes `lib/config.ahk` so the choice dialog reappears on next launch.

---

## Managing the server task

```powershell
.\installer.ps1 -Action status    # Check current state (Running / Ready / Disabled)
.\installer.ps1 -Action start     # Start manually (if stopped)
.\installer.ps1 -Action stop      # Stop task and kill orphaned processes
.\installer.ps1 -Action uninstall # Remove task and startup script
```

You can also manage it in **Task Scheduler** (`taskschd.msc`) under **Task Scheduler Library > AltTabSucks**.

To run the server manually without a task:

```powershell
.\Server\startServer.ps1
```

---

## For Developers

**Triggering template regeneration**

The pre-commit hook (`hooks/pre-commit`) runs `dev-scripts/make-template.sh` automatically on every commit, keeping templates in sync. After editing `lib/app-hotkeys.ahk`:

```bash
git commit --amend --no-edit
# Hook fires, regenerates both templates, stages them into the amend automatically.
```

To regenerate manually without committing:

```bash
./dev-scripts/make-template.sh
```

Run `bash dev-scripts/install-hooks.sh` once after cloning to activate the hook.

**Packaging the Firefox extension**

```powershell
# Unsigned zip (for local testing via about:debugging):
.\dev-scripts\package-firefox-extension.ps1

# Signed xpi (auto-increments patch version, outputs AltTabSucks-firefox.xpi):
.\dev-scripts\package-firefox-extension.ps1 -Sign
```

Requires Node.js (offered via `winget` if missing) and AMO credentials (prompted on first run, stored in `.amo-credentials`).

---

## Troubleshooting

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
.\installer.ps1 -Action stop
.\installer.ps1 -Action start
```
