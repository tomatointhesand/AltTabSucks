# AltTabSucks

AutoHotkey v2 automation scripts for Windows productivity — window cycling, Chromium browser profile switching, and profile-aware tab control via a local HTTP bridge. Works with any Chromium-based browser (Brave, Chrome, Edge, Vivaldi).

## Components

| Path | Purpose |
|---|---|
| `AltTabSucks.ahk` | Entry point — self-elevates and includes all libs |
| `lib/utils.ahk` | Window management (`ManageAppWindows`, `ShowTextGui`) |
| `lib/config.ahk` | Machine-local config: `CHROMIUM_EXE`, `CHROMIUM_USERDATA` (**gitignored**, see `config.template.ahk`) |
| `lib/config.template.ahk` | Sanitized config template, tracked in git |
| `lib/chromium.ahk` | Chromium profile cycling + tab focus via AltTabSucks |
| `lib/toast.ahk` | Visual feedback overlays |
| `lib/star-citizen.ahk` | Star Citizen–scoped hotkeys |
| `lib/app-hotkeys.ahk` | General app/browser hotkeys (**gitignored** — contains real paths/URLs) |
| `lib/app-hotkeys.template.ahk` | Sanitized version of above, tracked in git |
| `BrowserExtension/server.ps1` | PowerShell HTTP server on `localhost:9876` |
| `BrowserExtension/background.js` | Chromium MV3 extension service worker |
| `BrowserExtension/install-service.ps1` | Registers `server.ps1` as a Windows scheduled task |
| `startServer.ps1` | Manually start the server (no scheduled task) |
| `screenOff.ps1` | Turn off monitor |
| `make-template.sh` | Regenerate sanitized templates from the gitignored source files |
| `hooks/pre-commit` | Git pre-commit hook — auto-runs `make-template.sh` on commit |
| `install-hooks.sh` | Install tracked hooks into `.git/hooks/` (run once after cloning) |

---

## Requirements

- Windows with [AutoHotkey v2](https://www.autohotkey.com/)
- PowerShell 5+ (for AltTabSucks server)
- A Chromium-based browser (Brave, Chrome, Edge, Vivaldi) for tab-switching features

## Quick Start

### 1. Run the AHK script

Double-click `AltTabSucks.ahk` in Windows Explorer. It self-elevates to admin.

- **Reload**: `Ctrl+Alt+Shift+'`
- **Debug**: Right-click tray icon → Window Spy

### 2. Configure your browser

Copy `lib/config.template.ahk` to `lib/config.ahk` and fill in the paths for your Chromium-based browser:

```ahk
global CHROMIUM_EXE      := "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
global CHROMIUM_USERDATA := "C:\Users\YourName\AppData\Local\BraveSoftware\Brave-Browser\User Data"
```

### 3. Register the AltTabSucks server

Run from any PowerShell prompt (triggers a UAC prompt):

```powershell
powershell -ExecutionPolicy Bypass -File ".\BrowserExtension\install-service.ps1"
```

This does two things:

1. Registers a Task Scheduler task named **AltTabSucks** that runs `server.ps1`:
   - Starts automatically at logon (runs hidden, no console window)
   - Restarts automatically if it crashes (up to 10 times, 1 minute apart)
   - Runs with elevated privileges so `HttpListener` can bind to port 9876

2. Writes `AltTabSucks.bat` to your `shell:startup` folder. This script polls every second for the repo directory to appear (the mapped drive may not be ready immediately at logon), then launches `AltTabSucks.ahk` automatically.

On first run the server generates a random auth token and saves it to `BrowserExtension\token.txt` (gitignored). The token is printed to the console — copy it for the next step. To retrieve it later:

```powershell
Get-Content ".\BrowserExtension\token.txt"
```

### 4. Load the browser extension

1. Go to your browser's extensions page (e.g. `brave://extensions`, `chrome://extensions`)
2. Enable **Developer mode** (top-right toggle)
3. Click **Load unpacked** and select the `BrowserExtension/` folder
4. Open the extension **Options** — set your profile name (e.g. `Default`) and paste the auth token from step 3

---

## Managing the server task

```powershell
# Check current state (Running / Ready / Disabled)
.\BrowserExtension\install-service.ps1 -Action status

# Start manually (if stopped)
.\BrowserExtension\install-service.ps1 -Action start

# Stop the task and kill any orphaned server.ps1 processes
.\BrowserExtension\install-service.ps1 -Action stop

# Remove the task and startup script
.\BrowserExtension\install-service.ps1 -Action uninstall
```

You can also manage it in **Task Scheduler** (`taskschd.msc`) under **Task Scheduler Library > AltTabSucks**.

To run the server manually without a task:

```powershell
powershell -ExecutionPolicy Bypass -File ".\BrowserExtension\server.ps1"
```

---

## Hotkey Conventions

| Modifier | Meaning |
|---|---|
| `^` | Ctrl |
| `!` | Alt |
| `+` | Shift |
| `#` | Win |
| `~` | Pass-through |

General hotkeys use `Ctrl+Alt+Shift+<key>`. App-scoped hotkeys are wrapped in `#HotIf WinActive(...)`.

---

## Adding Hotkeys

Edit `lib/app-hotkeys.ahk` (gitignored — contains real URLs/paths, never committed directly). The tracked counterpart is `lib/app-hotkeys.template.ahk`, which has all sensitive values redacted.

**Triggering template regeneration**

The pre-commit hook (`hooks/pre-commit`) runs `make-template.sh` automatically whenever a commit or amend is made, so the templates are always in sync at commit time. The typical workflow after editing `lib/app-hotkeys.ahk`:

```bash
# Stage any other tracked changes, then amend the top commit to include the template update:
git commit --amend --no-edit
# The hook fires, regenerates both templates, and stages them into the amend automatically.
```

To regenerate templates manually without committing:

```bash
./make-template.sh
```

Run `bash install-hooks.sh` once after cloning to activate the hook.

---

## Troubleshooting

**Task registers but does not reach Running state**

Open Event Viewer: `eventvwr.msc` → **Windows Logs > Application**, or
**Applications and Services Logs > Microsoft > Windows > TaskScheduler > Operational**.
Look for errors referencing the AltTabSucks task.

**Port 9876 already in use**

Another instance of `server.ps1` is running. Stop it:

```powershell
.\BrowserExtension\install-service.ps1 -Action stop
# or find the PID manually:
netstat -ano | findstr :9876
# then: taskkill /PID <pid> /F
```

**Extension shows "server offline"**

- Confirm the task is running: `.\BrowserExtension\install-service.ps1 -Action status`
- Check the extension Options page has the correct profile name set

**Extension shows "server: error (403)"**

The auth token in the extension Options doesn't match `token.txt`. Retrieve the correct token:

```powershell
Get-Content ".\BrowserExtension\token.txt"
```

Paste it into the extension **Options** page and save.

**Extension shows "server offline" but the task is Running**

The port may be held by an orphaned process from a previous manual run:

```powershell
.\BrowserExtension\install-service.ps1 -Action stop
.\BrowserExtension\install-service.ps1 -Action start
```
