# AltTabSucks

ATS is the alt-tab of the future: a keyboard shortcut based solution for app-specific window focus control, profile-aware URL-based browser tab focus control, and more. Supports Brave, Chrome, Edge, Opera, and Firefox at the moment.

**Features:**
- **App window management** — cycle or toggle any app's windows with a single hotkey; launch it if it isn't running
- **Browser tab focus** — jump to a tab by URL pattern for a given browser profile; opens the URL if no matching tab exists
- **Browser profile cycling** — cycle through all windows for a given browser profile
- **Split/merge tab snapping** — tear the active tab into its own window and snap both halves side-by-side; merge them back with another hotkey

**Platforms:** Windows (below) and Linux/KDE Plasma 6 (Chromium-family browsers only for now —
see **[linux/README.md](linux/README.md)** for the Linux install guide).

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

### 4. Try the starter hotkeys, then make them yours

On first launch AltTabSucks adds a set of suggested hotkeys (from `lib\hotkeys.template.json`, using your browser's default profile) and shows a notification:

| Hotkey | Does |
|---|---|
| Ctrl+Alt+/ | Open the Hotkeys config page |
| Ctrl+Alt+Shift+B | Cycle your browser windows |
| Ctrl+Alt+Shift+G / C / Y / M | Jump to (or open) Gmail / Calendar / YouTube / Maps |
| Alt+X / Alt+Z | In the browser: split the tab into its own window / merge it back |
| Ctrl+Alt+Shift+N | Show/hide Notepad |
| Ctrl+Alt+Shift+Enter | Cycle Windows Terminal windows |
| Ctrl+Alt+Shift+Down | Open Downloads |
| Ctrl+Alt+Shift+/ | Quick reference of every hotkey |

Open your browser and switch tabs once so the extension reports them, then try a few.

**Upgrading with your own hotkeys in `lib\app-hotkeys.ahk`?** On startup AltTabSucks moves its single-line `FocusTab` / `CycleChromiumProfile` / `ManageAppWindows` / split / merge hotkeys into the Hotkeys UI instead (they replace any suggested hotkey on the same key). The originals are commented out with a `[migrated to Hotkeys UI]` marker and the file is backed up as `app-hotkeys.ahk.pre-ui-migration-<timestamp>`. A `#HotIf !WinActive(...)` block around them becomes `UI_HOTKEYS_SUPPRESS_WHEN`. Hotkeys that call your own functions or run multi-line blocks stay where they are.

**To change them, press Ctrl+Alt+/** (or tray menu → Hotkeys UI), paste your auth token (`Server\token.txt`), and add or edit app-window / tab-focus / profile-cycle / split / merge / run-command hotkeys with a key recorder and a running-process typeahead. Save writes `lib\hotkeys.json` and regenerates `lib\hotkeys-ui.generated.ahk` (both gitignored); AltTabSucks reloads itself within a second. Hand-written hotkeys in `app-hotkeys.ahk` keep working alongside; just don't bind the same key in both places (the static one wins). Set `UI_HOTKEYS_SUPPRESS_WHEN` (e.g. `"ahk_exe Moonlight.exe"`) in `app-hotkeys.ahk` to disable UI hotkeys while that window is active. Same page as the Linux port (`shared/hotkeys-ui.html`).

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

**Secure secrets (recommended)**

Store credentials outside source files using gopass (cross-platform, bash-based).

1. Install gopass and GPG once:

```powershell
winget install gopass.gopass
winget install GnuPG.GnuPG
```

> **Note:** The gopass MSI does not add itself to PATH. After installing, create a Git Bash wrapper:
> ```bash
> mkdir -p ~/bin && printf '#!/bin/sh\nexec "$LOCALAPPDATA/gopass/gopass.exe" "$@"\n' > ~/bin/gopass && chmod +x ~/bin/gopass
> ```

2. Initialize the password store and create secrets:

```bash
bash dev-scripts/manage-secrets.sh
# Choose option 2
```

This will prompt you for each `PasswordSecretNameN` entry defined in `lib/app-hotkeys.ahk`.
Non-secret values like usernames can remain ordinary variables in the sensitive section.

Then it will store them encrypted in your gopass store (location depends on gopass configuration; on some Windows setups this is under `%LOCALAPPDATA%\gopass\stores\root`).

**Managing Secrets**

Open the secrets manager with the AHK hotkey:
```text
Ctrl+Win+Shift+'
```

Or run it directly:
```bash
bash dev-scripts/manage-secrets.sh
```

View all secrets:
```bash
bash dev-scripts/manage-secrets.sh
```

Update a secret:
```bash
bash dev-scripts/manage-secrets.sh
# Choose option 4
```

Delete a secret:
```bash
bash dev-scripts/manage-secrets.sh
# Choose option 5
```

Lock secrets (kill gpg-agent cache):
```bash
bash dev-scripts/manage-secrets.sh
# Choose option 6
```

`lib/secrets.ahk` calls `lib/secret-bridge.sh` to read secrets on demand. Secrets are cached in memory briefly for smooth hotkey flows, then purged. On workstation lock, the cache is cleared and the gpg-agent is killed.

When locking via `manage-secrets.sh` option 6, gpg-agent is killed and a local lock signal is emitted so the running AHK process clears its in-memory secret cache immediately.

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
