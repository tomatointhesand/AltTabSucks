<#
.SYNOPSIS
    Installs or removes the full AltTabSucks setup: scheduled task + startup script.

.DESCRIPTION
    install   - Registers AltTabSucksServer.ps1 as a Task Scheduler task (auto-start at logon,
                restarts on crash), and the startup manager (StartupManager.ahk), which launches
                AltTabSucks.ahk and the rest of the startup apps at logon: a logon task for it, an
                on-demand elevated task it starts AltTabSucks.ahk through (no UAC prompt), and the
                Windows startup entries (Run keys, Startup folders) moved into its list and turned
                off in Windows (Server/StartupItems.ps1). Tasks rather than a Windows service
                because both the repo and the browser profile can live on a drive that's only
                mapped after logon.
    uninstall - Stops and removes the tasks; turns the Windows startup entries back on.
    status    - Shows current task state.
    start     - Starts the task manually (if not already running).
    stop      - Stops the task and kills any orphaned AltTabSucksServer.ps1 processes.
    restart   - stop + start, then waits (up to 15s) until the server answers. Used by the
                Ctrl+Alt+Shift+' reload hotkey so server changes apply along with AHK ones.
    startup-scan   - Lists ("NEW<tab>name") the Windows startup entries that are on and not taken
                     over yet. Used by the startup manager's "not in this list yet" notice.
    startup-import - Takes those over (what install does). The notice's Take over button.
    startup-setup  - Just the startup manager part of install (tasks, startup items, removing the old
                     AltTabSucks.bat), leaving everything else alone. AltTabSucks.ahk offers it
                     to installs from before the startup manager existed.

    -TakeOverStartup Ask|Yes|No: whether install / startup-setup moves the Windows startup apps into
    the startup manager. Ask (the default) lists them and asks; with no console to ask on, No.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File installer.ps1
    pwsh -ExecutionPolicy Bypass -File installer.ps1 -Action uninstall
#>

param(
    [ValidateSet("install", "uninstall", "status", "start", "stop", "restart", "pair", "startup-scan", "startup-import", "startup-setup")]
    [string]$Action = "install",
    [ValidateSet("Ask", "Yes", "No")]
    [string]$TakeOverStartup = "Ask"
)

# install and uninstall require admin (Register/Unregister-ScheduledTask with RunLevel Highest).
# Self-elevate via UAC rather than requiring the user to open an admin shell manually.
# startup-import too: entries under HKLM can only be switched off by an admin.
if ($Action -in "install","uninstall","startup-import","startup-setup") {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $argList = "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action -TakeOverStartup $TakeOverStartup"
        Start-Process pwsh -Verb RunAs -ArgumentList $argList
        exit
    }
}

$TaskName      = "AltTabSucks"
$ScriptPath    = Join-Path $PSScriptRoot "Server\AltTabSucksServer.ps1"
$RepoRoot      = $PSScriptRoot
$AhkScript     = Join-Path $RepoRoot "AltTabSucks.ahk"
$StartupDir    = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$StartupScript = Join-Path $StartupDir "AltTabSucks.bat"  # how AltTabSucks.ahk used to start; replaced by the startup manager
$StartupTask   = "AltTabSucks Startup"
$AhkTask       = "AltTabSucks AHK"
$DataDir       = Join-Path $env:LOCALAPPDATA "AltTabSucks"
$StartupVbs    = Join-Path $DataDir "start-startup-manager.vbs"
. (Join-Path $PSScriptRoot "Server\StartupItems.ps1")

function Find-AutoHotkey {
    foreach ($root in "HKLM:\SOFTWARE\AutoHotkey", "HKCU:\SOFTWARE\AutoHotkey") {
        $dir = (Get-ItemProperty $root -ErrorAction SilentlyContinue).InstallDir
        if ($dir -and (Test-Path "$dir\v2\AutoHotkey64.exe")) { return "$dir\v2\AutoHotkey64.exe" }
    }
    foreach ($p in "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe", "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe") {
        if (Test-Path $p) { return $p }
    }
    $null
}

# Whether to move the Windows startup apps into the startup manager (switching them off in Windows).
function Confirm-StartupTakeOver {
    if ($TakeOverStartup -ne "Ask") { return $TakeOverStartup -eq "Yes" }
    $entries = @(Get-NewStartupEntries)
    if (-not $entries) { return $true }  # nothing to move yet; later ones get the manager's Take over notice
    if ([Console]::IsInputRedirected) { return $false }
    Write-Host ""
    Write-Host "Windows starts these apps at logon, late and all at once:"
    foreach ($e in $entries) { Write-Host "  - $($e.Name)" }
    Write-Host "AltTabSucks' startup manager can start them instead, one after another with delays you set, and"
    Write-Host "show how long each takes. They're switched off in Windows' own startup (uninstall switches them back on)."
    (Read-Host "Let the startup manager start them? [Y/n]") -notmatch '^\s*n'
}

# The startup manager: its logon task, the elevated task it starts AltTabSucks.ahk through, and
# startup.json (with the Windows startup apps moved in, if the user agrees).
function Install-StartupManager {
    $ahkExe = Find-AutoHotkey
    if (-not $ahkExe) {
        # No AutoHotkey64.exe to point the tasks at: start AltTabSucks.ahk the old way.
        Write-Warning "AutoHotkey v2 not found; AltTabSucks.ahk starts from the Startup folder instead of the startup manager."
        Set-Content -Path $StartupScript -Value "@echo off`r`nstart `"`" `"$AhkScript`"" -Encoding ASCII
    } else {
        if (Test-Path $StartupScript) {
            Remove-Item $StartupScript -Force
            Write-Host "Removed the old startup script ($StartupScript): the startup manager launches AltTabSucks.ahk now."
        }
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                            -Priority 4 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        # On demand, elevated: the startup manager runs as a normal user (so the apps it starts
        # aren't elevated) and starts AltTabSucks.ahk through this, without a UAC prompt.
        Register-ScheduledTask -TaskName $AhkTask -Force `
            -Action (New-ScheduledTaskAction -Execute $ahkExe -Argument "`"$AhkScript`"" -WorkingDirectory $RepoRoot) `
            -Principal (New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive) `
            -Settings $taskSettings `
            -Description "Starts AltTabSucks.ahk elevated; run by the AltTabSucks startup manager" | Out-Null

        # At logon, no delay, unlike the Run keys and Startup folder, which Explorer starts
        # late and all at once. Through a small script on the local disk that waits for
        # StartupManager.ahk, in case the repo's drive is mapped a moment after logon.
        New-Item $DataDir -ItemType Directory -Force | Out-Null
        $managerScript = Join-Path $RepoRoot "StartupManager.ahk"
        Set-Content $StartupVbs -Encoding ASCII -Value @"
' Written by AltTabSucks' installer.ps1: starts the startup manager at logon (the AltTabSucks Startup task).
Set fso = CreateObject("Scripting.FileSystemObject")
For i = 1 To 240
    If fso.FileExists("$managerScript") Then Exit For
    WScript.Sleep 250
Next
CreateObject("WScript.Shell").Run """$ahkExe"" ""$managerScript"" --logon", 1, False
"@
        Register-ScheduledTask -TaskName $StartupTask -Force `
            -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$StartupVbs`"" -WorkingDirectory $env:USERPROFILE) `
            -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
            -Principal (New-ScheduledTaskPrincipal -UserId $user -RunLevel Limited -LogonType Interactive) `
            -Settings $taskSettings `
            -Description "AltTabSucks startup manager: launches the startup apps at logon" | Out-Null
        Write-Host "Startup manager registered ('$StartupTask' at logon, '$AhkTask' for AltTabSucks.ahk)."

        Import-StartupItems -TakeOver (Confirm-StartupTakeOver) | Out-Null
        Write-Host "Startup items: $StartupConfigPath (edit them from the tray menu's Startup items)."
    }
}

if ($Action -eq "startup-scan") {
    foreach ($e in @(Get-NewStartupEntries)) { "NEW`t$($e.Name)" }
    exit 0
}
if ($Action -eq "startup-import") {
    Import-StartupItems -TakeOver $true | Out-Null
    exit 0
}
if ($Action -eq "startup-setup") {
    Install-StartupManager
    if (-not [Console]::IsInputRedirected) { Read-Host "Done. Press Enter to close" | Out-Null }
    exit 0
}

# Opens pairing: for the next few minutes the browser extension fetches the token from the server
# by itself (POST /extension-token), so nobody has to paste it into its Options page.
function Open-ExtensionPairing {
    $tokenPath = Join-Path $PSScriptRoot "Server\token.txt"
    $deadline = (Get-Date).AddSeconds(15)
    while ($true) {
        try {
            $token = (Get-Content $tokenPath -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            $r = Invoke-RestMethod "http://localhost:9876/extension-pairing" -Method Post -Headers @{ "X-AltTabSucks-Token" = $token } -TimeoutSec 2
            Write-Host "Browser extension: load BrowserExtension\ unpacked in your browser (extensions page,"
            Write-Host "Developer mode, Load unpacked) within the next $($r.minutes) minutes, and it connects by itself."
            Write-Host "Already loaded? It connects within a few seconds. Later: tray menu > Connect browser extension."
            return
        } catch {
            if ((Get-Date) -gt $deadline) { Write-Warning "Couldn't reach the server to connect the browser extension ($($_.Exception.Message))."; return }
            Start-Sleep -Milliseconds 250
        }
    }
}
if ($Action -eq "pair") {
    Open-ExtensionPairing
    exit 0
}

if ($Action -eq "restart") {
    & $PSCommandPath -Action stop
    & $PSCommandPath -Action start
    # Wait for the listener so callers (the AHK reload hotkey) don't race a half-started server.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest "http://localhost:9876/hotkeys-ui" -UseBasicParsing -TimeoutSec 1 | Out-Null
            Write-Host "Server is up."
            exit 0
        } catch { Start-Sleep -Milliseconds 250 }
    }
    Write-Error "Server didn't answer within 15s."
    exit 1
}

switch ($Action) {

    "install" {
        if (-not (Test-Path $ScriptPath)) {
            Write-Error "AltTabSucksServer.ps1 not found at: $ScriptPath"
            exit 1
        }
        if (-not (Test-Path $AhkScript)) {
            Write-Error "AltTabSucks.ahk not found at: $AhkScript"
            exit 1
        }

        # --- Stop any existing task and orphaned processes first ---
        # Ensures the port is free before registering the new task, regardless of
        # whether the previous AltTabSucksServer.ps1 lived in a different directory.

        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed existing '$TaskName' task."
        }
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" |
                   Where-Object { $_.CommandLine -like "*AltTabSucksServer.ps1*" }
        foreach ($proc in $orphans) {
            Stop-Process -Id $proc.ProcessId -Force
            Write-Host "Killed orphaned AltTabSucksServer.ps1 process (PID $($proc.ProcessId))."
        }
        $wscriptOrphans = Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" |
                          Where-Object { $_.CommandLine -like "*launch-hidden.vbs*" }
        foreach ($proc in $wscriptOrphans) {
            Stop-Process -Id $proc.ProcessId -Force
            Write-Host "Killed orphaned wscript.exe/launch-hidden.vbs process (PID $($proc.ProcessId))."
        }

        # --- Scheduled task (AltTabSucksServer.ps1) ---

        # Use wscript.exe + VBScript shim rather than powershell.exe -WindowStyle Hidden.
        # -WindowStyle Hidden is unreliable for elevated Task Scheduler tasks on some Windows
        # builds/policies; wscript.exe's Run(..., 0, False) always launches without a window.
        $vbsLauncher = Join-Path $PSScriptRoot "Server\launch-hidden.vbs"
        $taskAction = New-ScheduledTaskAction `
            -Execute "wscript.exe" `
            -Argument "`"$vbsLauncher`"" `
            -WorkingDirectory (Join-Path $PSScriptRoot "Server")

        # Start at logon for the current user only
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

        # RunLevel Highest is required: HttpListener.Start() on localhost needs elevation
        # (no URL ACL registered). The self-elevation block above handles the UAC prompt.
        $principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -RunLevel Highest `
            -LogonType Interactive

        # Priority 4: tasks default to 7 (below normal), which everything they start inherits.
        # Batteries: by default a task doesn't start on battery power, or stops when unplugged.
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 10 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -Priority 4 `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $taskAction `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "AltTabSucks HTTP server for Chromium/AHK tab integration" `
            -Force | Out-Null

        Write-Host "Task registered. Starting now..."
        Start-ScheduledTask -TaskName $TaskName

        Start-Sleep -Seconds 2
        $info  = Get-ScheduledTask -TaskName $TaskName
        $state = $info.State
        Write-Host "Task state: $state"
        if ($state -eq "Running") {
            Write-Host "AltTabSucks server is running."
            Open-ExtensionPairing
        } else {
            Write-Warning "Task did not reach Running state. Check Event Viewer > Task Scheduler."
        }

        # --- Startup manager (StartupManager.ahk, which launches AltTabSucks.ahk) ---
        Install-StartupManager

        # Re-initialize browser config so auto-detection always runs with the current
        # default browser. Deleting config.ahk causes _PromptBrowserChoice() to re-detect
        # on the next AltTabSucks.ahk launch. Detection covers both system-level installs
        # (Program Files) and user-level installs (LOCALAPPDATA, HKCU registry for Firefox).
        $configPath = Join-Path $RepoRoot "lib\config.ahk"
        if (Test-Path $configPath) {
            Remove-Item $configPath -Force
            Write-Host "Removed lib\config.ahk — browser will be re-detected on launch (includes user-level installs)."
        }

        # Seed app-hotkeys.ahk from the template if the user doesn't have one yet.
        $hotkeysPath   = Join-Path $RepoRoot "lib\app-hotkeys.ahk"
        $templatePath  = Join-Path $RepoRoot "lib\app-hotkeys.template.ahk"
        if (-not (Test-Path $hotkeysPath)) {
            Copy-Item $templatePath $hotkeysPath
            Write-Host "Created lib\app-hotkeys.ahk from template — edit it to add your hotkeys."
        }

        # Disable the Ctrl+Alt+Win+Shift shortcut that opens Copilot/Office by redirecting
        # the ms-officeapp protocol handler to a no-op (rundll32 with no arguments).
        $regPath = "HKCU:\Software\Classes\ms-officeapp\Shell\Open\Command"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "(default)" -Value "rundll32"
        Write-Host "Disabled Copilot/Office Ctrl+Alt+Win+Shift shortcut."

        Write-Host "Launching AltTabSucks.ahk..."
        Start-Process $AhkScript
    }

    "uninstall" {
        # stop, not just Stop-ScheduledTask: the task only runs wscript.exe, and the server's own
        # pwsh.exe outlives it, leaving the port held after an uninstall.
        & $PSCommandPath -Action stop
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Host "'$TaskName' task is not registered."
        } else {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Task removed."
        }
        foreach ($t in $StartupTask, $AhkTask) {
            if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $t -Confirm:$false
                Write-Host "'$t' task removed."
            }
        }
        # The startup apps go back to Windows; startup.json and the history stay, for a reinstall.
        Restore-StartupItems
        Remove-Item $StartupVbs -Force -ErrorAction SilentlyContinue

        if (Test-Path $StartupScript) {
            Remove-Item $StartupScript -Force
            Write-Host "Startup script removed: $StartupScript"
        } else {
            Write-Host "Startup script not found (already removed?)."
        }
    }

    "status" {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "'$TaskName' is not registered."
        } else {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            Write-Host "State      : $($task.State)"
            Write-Host "Last run   : $($info.LastRunTime)"
            Write-Host "Last result: $($info.LastTaskResult)"
            Write-Host "Next run   : $($info.NextRunTime)"
        }
        foreach ($t in $StartupTask, $AhkTask) {
            $st = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Write-Host "$($t.PadRight(19)): $(if ($st) { "$($st.State), last run $((Get-ScheduledTaskInfo -TaskName $t).LastRunTime)" } else { 'not registered' })"
        }
        if (Test-Path $StartupScript) { Write-Host "Startup script: $StartupScript" }

        Write-Host ""
        Write-Host "Running AltTabSucksServer.ps1 processes:"
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" |
                 Where-Object { $_.CommandLine -like "*AltTabSucksServer.ps1*" } |
                 Select-Object ProcessId, CommandLine
        if ($procs) { $procs | Format-Table -AutoSize } else { Write-Host "  (none)" }
    }

    "start" {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Error "'$TaskName' task is not registered. Run install first."
            exit 1
        }
        if ($task.State -eq "Running") {
            Write-Host "Already running."
        } else {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host "Started."
        }
    }

    "stop" {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $task.State -eq "Running") {
            Stop-ScheduledTask -TaskName $TaskName
            Write-Host "Task stopped."
        } else {
            Write-Host "Task is not running."
        }
        # Kill any orphaned PowerShell processes still holding the port
        # (e.g. from a manual startServer.ps1 run alongside the scheduled task).
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" |
                   Where-Object { $_.CommandLine -like "*AltTabSucksServer.ps1*" }
        foreach ($proc in $orphans) {
            Stop-Process -Id $proc.ProcessId -Force
            Write-Host "Killed orphaned AltTabSucksServer.ps1 process (PID $($proc.ProcessId))."
        }
        $wscriptOrphans = Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" |
                          Where-Object { $_.CommandLine -like "*launch-hidden.vbs*" }
        foreach ($proc in $wscriptOrphans) {
            Stop-Process -Id $proc.ProcessId -Force
            Write-Host "Killed orphaned wscript.exe/launch-hidden.vbs process (PID $($proc.ProcessId))."
        }
    }
}
