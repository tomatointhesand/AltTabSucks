# helpers.ps1 - shared by the VM test scripts (e2e.ps1, logon.ps1): paths, Check / Wait-Until,
# and running things on the logged-on user's desktop from an SSH session.

$ErrorActionPreference = 'Stop'
$Repo    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Here    = $PSScriptRoot
$Ahk     = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$Pwsh    = "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"

$script:Passed = 0; $script:Failed = 0
function Check([bool]$ok, [string]$name, [string]$detail = "") {
    if ($ok) { $script:Passed++; Write-Host "PASS  $name" }
    else     { $script:Failed++; Write-Host "FAIL  $name$(if ($detail) { "`n        $detail" })" }
}
function Wait-Until([scriptblock]$cond, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $cond) { return $true } } catch {}
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Runs exe on the interactive desktop (session of the logged-on user) and returns right away.
function Start-OnDesktop([string]$exe, [string]$arguments, [string]$workDir = $Repo) {
    $name = "alttabsucks-e2e-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $action = if ($arguments) { New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $workDir }
              else { New-ScheduledTaskAction -Execute $exe -WorkingDirectory $workDir }
    # Not "$env:USERDOMAIN\$env:USERNAME": over SSH USERDOMAIN is "WORKGROUP", not the machine.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $name
    $name
}
# Same, but waits for it to finish (up to $seconds) and removes the task.
function Invoke-OnDesktop([string]$exe, [string]$arguments, [int]$seconds = 120) {
    $name = Start-OnDesktop $exe $arguments
    Wait-Until { (Get-ScheduledTask -TaskName $name).State -ne 'Running' } $seconds | Out-Null
    Start-Sleep -Milliseconds 500
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}
function Remove-E2eTasks {
    Get-ScheduledTask -TaskName "alttabsucks-e2e-*" -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
}

# The AltTabSucks.ahk process (AutoHotkey64.exe running it), or $null.
function Get-AltTabSucks {
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" |
        Where-Object { $_.CommandLine -like "*AltTabSucks.ahk*" } | Select-Object -First 1
}
