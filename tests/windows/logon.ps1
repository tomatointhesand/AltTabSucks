# logon.ps1 - the startup manager at a real logon, with UAC on. dev-scripts/run-windows-tests.sh
# runs it after e2e.ps1, in two phases around a reboot (the VM logs on by itself):
#   prepare - a fresh install that takes over a Windows startup entry (Notepad), the other startup
#             items switched off, the history cleared, and UAC switched on (it needs the reboot)
#   check   - the logon task ran the manager, which recorded a "logon" run; AltTabSucks.ahk runs
#             elevated with no UAC prompt waiting (started through the AltTabSucks AHK task by a
#             manager that isn't elevated itself); Notepad started, and not elevated
param([Parameter(Mandatory)][ValidateSet("prepare", "check")][string]$Phase)

. "$PSScriptRoot\helpers.ps1"
$Work      = Join-Path $env:TEMP "alttabsucks-logon"
$SmDir     = "$env:LOCALAPPDATA\AltTabSucks"
$SmConfig  = "$SmDir\startup.json"
$SmHistory = "$SmDir\startup-history.jsonl"
$SmErrors  = "$SmDir\startup-errors.log"
$Uac       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
New-Item $Work -ItemType Directory -Force | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Elevation {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr t, int cls, out int value, int len, out int ret);
    // 1 elevated, 0 not, -1 couldn't tell
    public static int Of(int pid) {
        IntPtr p = OpenProcess(0x1000, false, pid), t;  // PROCESS_QUERY_LIMITED_INFORMATION
        if (p == IntPtr.Zero) return -1;
        try {
            if (!OpenProcessToken(p, 0x8, out t)) return -1;  // TOKEN_QUERY
            int v, r;
            bool ok = GetTokenInformation(t, 20, out v, 4, out r);  // TokenElevation
            CloseHandle(t);
            return ok ? (v != 0 ? 1 : 0) : -1;
        } finally { CloseHandle(p); }
    }
}
"@

try {
    if ($Phase -eq "prepare") {
        # e2e.ps1 left lib\config.ahk (its browser choice) behind; the installer deletes it so the
        # browser dialog would come back. Keep it, so AltTabSucks starts quietly after the reboot.
        $config = Join-Path $Repo "lib\config.ahk"
        $keep = Get-Content $config -Raw
        Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" "E2E Notepad" "notepad.exe"
        $log = Join-Path $Work "install.log"
        Invoke-OnDesktop "cmd.exe" "/c `"`"$Pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$Repo\installer.ps1`" -Action install -TakeOverStartup Yes < nul > `"$log`" 2>&1`"" 180
        if ($p = Get-AltTabSucks) { Stop-Process -Id $p.ProcessId -Force }
        Get-Process AutoHotkey64 -ErrorAction SilentlyContinue | Stop-Process -Force  # the browser dialog's script, if it got that far
        Set-Content $config $keep -NoNewline

        $sm = Get-Content $SmConfig -Raw | ConvertFrom-Json -AsHashtable
        foreach ($i in $sm.items) { $i.enabled = $i.builtin -eq "alttabsucks" -or $i.name -eq "E2E Notepad" }
        [IO.File]::WriteAllText($SmConfig, (ConvertTo-Json $sm -Depth 10))
        Remove-Item $SmHistory, $SmErrors -ErrorAction SilentlyContinue
        Stop-Process -Name notepad -ErrorAction SilentlyContinue
        Check ((Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue) -and @($sm.items | Where-Object { $_.name -eq "E2E Notepad" }).Count -eq 1) `
            "prepare: installed, with Notepad taken over from Windows startup" (Get-Content $log -Raw -ErrorAction SilentlyContinue)

        Set-ItemProperty $Uac EnableLUA 1 -Type DWord
        Set-ItemProperty $Uac ConsentPromptBehaviorAdmin 5 -Type DWord  # Windows' default: prompt for non-Windows binaries
        Set-ItemProperty $Uac PromptOnSecureDesktop 1 -Type DWord
        Check ((Get-ItemProperty $Uac).EnableLUA -eq 1) "prepare: UAC switched on for the next logon"
    } else {
        Check ((Get-ItemProperty $Uac).EnableLUA -eq 1) "UAC is on"
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        Check (Wait-Until { Test-Path $SmHistory } 120) "at logon, the startup manager runs and records the run" `
            "task: $(Get-ScheduledTaskInfo -TaskName 'AltTabSucks Startup' | Select-Object LastRunTime, LastTaskResult | Out-String) errors: $(Get-Content $SmErrors -Raw -ErrorAction SilentlyContinue)"
        $row = Get-Content $SmHistory -Tail 1 -ErrorAction SilentlyContinue | ConvertFrom-Json
        $it = @{}; foreach ($x in $row.items) { $it[$x.name] = $x }
        Write-Host "      row: $($row | ConvertTo-Json -Depth 5 -Compress)"
        Check ($row.trigger -eq "logon" -and $row.logonToStartMs -is [long] -and $row.logonToStartMs -lt 60000 -and $row.bootToStartMs -gt $row.logonToStartMs) `
            "  ...as a logon run, with its time since logon and boot" "trigger $($row.trigger), logonToStartMs $($row.logonToStartMs), bootToStartMs $($row.bootToStartMs)"

        $ats = Get-AltTabSucks
        Check ($it["AltTabSucks"].status -eq "ready" -and $ats) "AltTabSucks.ahk started"
        Check ($it["AltTabSucks"].readyMs -gt $it["AltTabSucks"].launchMs) "  ...ready after it was launched (each time is taken when it happens)" ($it["AltTabSucks"] | ConvertTo-Json -Compress)
        Check ($ats -and [Elevation]::Of($ats.ProcessId) -eq 1) "  ...elevated"
        Check ((Get-ScheduledTaskInfo -TaskName "AltTabSucks AHK").LastRunTime -ge $boot) "  ...through the AltTabSucks AHK task"
        # It starts within a second or so of Explorer, before the taskbar: its tray icon has to get
        # there anyway (lib\tray-icon.ahk), and the manager only calls it ready once it has.
        $trayOut = Join-Path $Work "tray-icon.txt"
        Remove-Item $trayOut -ErrorAction SilentlyContinue
        Invoke-OnDesktop $Ahk "`"$Repo\tests\windows\tray-icon.ahk`" `"$trayOut`"" 30 | Out-Null
        Check ((Get-Content $trayOut -Raw -ErrorAction SilentlyContinue) -eq "1") "  ...with its tray icon in the taskbar"
        Check (-not (Get-Process consent -ErrorAction SilentlyContinue)) "  ...with no UAC prompt waiting"

        $notepad = Get-Process notepad -ErrorAction SilentlyContinue | Select-Object -First 1
        Check ($it["E2E Notepad"].status -eq "ready" -and $notepad) "Notepad, taken over from Windows startup, started and showed its window" ($it["E2E Notepad"] | ConvertTo-Json -Compress)
        Check ($notepad -and [Elevation]::Of($notepad.Id) -eq 0) "  ...not elevated"
        Check (Wait-Until { (Invoke-WebRequest "http://localhost:9876/hotkeys-ui" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } 30) "the server's logon task started it too"
        Check (Wait-Until { -not (Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" | Where-Object { $_.CommandLine -like "*StartupManager.ahk*" }) } 20) "the manager closed itself"
        Check (-not (Test-Path $SmErrors)) "  ...without errors" (Get-Content $SmErrors -Raw -ErrorAction SilentlyContinue)
    }
} finally {
    Remove-E2eTasks
    Write-Host "`n$script:Passed passed, $script:Failed failed"
}
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
