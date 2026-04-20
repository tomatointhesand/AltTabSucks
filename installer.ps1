<#
.SYNOPSIS
    Installs or removes the full AltTabSucks setup: scheduled task + startup script.

.DESCRIPTION
    install   - Registers AltTabSucksServer.ps1 as a Task Scheduler task (auto-start at logon,
                restarts on crash) AND copies a startup script to shell:startup that
                waits for the repo drive to become available then launches AltTabSucks.ahk.
                Preferable to a Windows service because both the repo and the browser
                profile live on a mapped drive (G:) that is only available after logon.
    uninstall - Stops and removes the task; deletes the startup script.
    status    - Shows current task state.
    start     - Starts the task manually (if not already running).
    stop      - Stops the task and kills any orphaned AltTabSucksServer.ps1 processes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install-service.ps1
    powershell -ExecutionPolicy Bypass -File install-service.ps1 -Action uninstall
#>

param(
    [ValidateSet("install", "uninstall", "status", "start", "stop")]
    [string]$Action = "install"
)

# install and uninstall require admin (Register/Unregister-ScheduledTask with RunLevel Highest).
# Self-elevate via UAC rather than requiring the user to open an admin shell manually.
if ($Action -in "install","uninstall") {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $argList = "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action"
        Start-Process pwsh -Verb RunAs -ArgumentList $argList
        exit
    }
}

$TaskName      = "AltTabSucks"
$ScriptPath    = Join-Path $PSScriptRoot "Server\AltTabSucksServer.ps1"
$RepoRoot      = $PSScriptRoot
$AhkScript     = Join-Path $RepoRoot "AltTabSucks.ahk"
$StartupDir    = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$StartupScript = Join-Path $StartupDir "AltTabSucks.bat"

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
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
                   Where-Object { $_.CommandLine -like "*AltTabSucksServer.ps1*" }
        foreach ($proc in $orphans) {
            Stop-Process -Id $proc.ProcessId -Force
            Write-Host "Killed orphaned AltTabSucksServer.ps1 process (PID $($proc.ProcessId))."
        }

        # --- Scheduled task (AltTabSucksServer.ps1) ---

        $taskAction = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
            -WorkingDirectory (Join-Path $PSScriptRoot "Server")

        # Start at logon for the current user only
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

        # RunLevel Highest is required: HttpListener.Start() on localhost needs elevation
        # (no URL ACL registered). The self-elevation block above handles the UAC prompt.
        $principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -RunLevel Highest `
            -LogonType Interactive

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 10 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew

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
            $tokenPath = Join-Path $PSScriptRoot "Server\token.txt"
            if (Test-Path $tokenPath) {
                $token = (Get-Content $tokenPath -Raw -Encoding UTF8).Trim()
                Write-Host "Auth token (paste into extension Options): $token"
            } else {
                Write-Host "token.txt not yet created — the server generates it on first start."
                Write-Host "Wait a moment, then run: Get-Content '$tokenPath'"
            }
        } else {
            Write-Warning "Task did not reach Running state. Check Event Viewer > Task Scheduler."
        }

        # --- Startup script (AltTabSucks.ahk) ---

        $batContent = @"
@echo off
start "" "$RepoRoot\AltTabSucks.ahk"
"@
        Set-Content -Path $StartupScript -Value $batContent -Encoding ASCII
        Write-Host "Startup script written to: $StartupScript"

        # Re-initialize browser config so auto-detection always runs with the current
        # default browser. Deleting config.ahk causes _PromptBrowserChoice() to re-detect
        # on the next AltTabSucks.ahk launch.
        $configPath = Join-Path $RepoRoot "lib\config.ahk"
        if (Test-Path $configPath) {
            Remove-Item $configPath -Force
            Write-Host "Removed lib\config.ahk — browser will be re-detected on launch."
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
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Host "'$TaskName' task is not registered."
        } else {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Task removed."
        }

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
        $startupExists = Test-Path $StartupScript
        Write-Host "Startup script: $(if ($startupExists) { $StartupScript } else { 'not installed' })"

        Write-Host ""
        Write-Host "Running AltTabSucksServer.ps1 processes:"
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
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
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
                   Where-Object { $_.CommandLine -like "*AltTabSucksServer.ps1*" }
        foreach ($proc in $orphans) {
            Stop-Process -Id $proc.ProcessId -Force
            Write-Host "Killed orphaned AltTabSucksServer.ps1 process (PID $($proc.ProcessId))."
        }
    }
}
