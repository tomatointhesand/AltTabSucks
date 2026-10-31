# StartupItems.ps1 - hands Windows' own startup entries (Run keys, Startup folders) over to the
# startup manager (StartupManager.ahk), and back. Dot-sourced by installer.ps1:
#   install   -> Import-StartupItems: adds every enabled entry to startup.json and turns it off in
#                Windows (the same StartupApproved switch Task Manager's Startup tab flips), so
#                Explorer's delayed startup burst no longer launches it; the manager does instead
#   uninstall -> Restore-StartupItems: puts each switch back the way it was
# The pure parts (Test-StartupApproved, Get-StartupProcessName, Merge-StartupItems) are tested by
# tests/ps/test-startup-items.ps1.

$StartupConfigPath = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "AltTabSucks\startup.json" } else { "" }

# Where Windows keeps startup entries, and the StartupApproved key that switches each one on/off.
$StartupSources = @(
    @{ Kind = "run";    Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run";              Approved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" }
    @{ Kind = "run";    Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";              Approved = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" }
    @{ Kind = "run";    Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run";  Approved = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32" }
    @{ Kind = "folder"; Folder = "Startup";       Approved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" }
    @{ Kind = "folder"; Folder = "CommonStartup"; Approved = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" }
)

# A StartupApproved value: missing or an even first byte (02, 06) = on; odd (03, 07) = off.
function Test-StartupApproved([byte[]]$Value) {
    -not $Value -or $Value.Length -eq 0 -or ($Value[0] -band 1) -eq 0
}

# The process whose window marks a command as ready (same rules as StartupProcessFromCommand in
# lib/startup-logic.ahk): "--processStart X.exe" launchers name it; otherwise the program run.
function Get-StartupProcessName([string]$Command) {
    $Command = $Command.Trim()
    if ($Command -match '--processStart\s+"?([^"\s]+)') { return $Matches[1] }
    $exe = if ($Command.StartsWith('"')) { $Command.Substring(1, $Command.IndexOf('"', 1) - 1) }
           elseif ($Command -match '^.*?\.exe(?=\s|$)') { $Matches[0] }
           else { ($Command -split ' ')[0] }
    Split-Path $exe -Leaf
}

# Apps started with a flag like this usually go straight to the tray, so they never show a window:
# for them, "ready" means their process is running.
function Get-StartupReadyMode([string]$Command) {
    if ($Command -match '(?i)(^|\s)[-/]{1,2}[\w-]*(minimi[sz]ed|tray|background|silent|hidden|startup|autostart|autorun)\b') { "process" } else { "window" }
}

# Every startup entry Windows has, on or off: Source, Name, Command, WorkingDir, Process,
# ApprovedKey, Previous (the StartupApproved bytes, or $null if there are none).
function Read-WindowsStartupEntries {
    $shell = $null
    foreach ($src in $StartupSources) {
        $approved = if (Test-Path $src.Approved) { Get-ItemProperty $src.Approved } else { $null }
        if ($src.Kind -eq "run") {
            if (-not (Test-Path $src.Path)) { continue }
            $key = Get-Item $src.Path
            foreach ($name in $key.GetValueNames()) {
                if (-not $name) { continue }
                $cmd = [string]$key.GetValue($name)  # REG_EXPAND_SZ comes back expanded
                [PSCustomObject]@{ Source = $src.Path; Name = $name; Command = $cmd; WorkingDir = ""
                                   Process = Get-StartupProcessName $cmd; ApprovedKey = $src.Approved
                                   Previous = $approved.$name }
            }
        } else {
            $dir = [Environment]::GetFolderPath($src.Folder)
            if (-not $dir -or -not (Test-Path $dir)) { continue }
            foreach ($file in Get-ChildItem $dir -File) {
                if ($file.Name -eq "desktop.ini") { continue }
                $process = $file.Name; $workDir = ""
                if ($file.Extension -eq ".lnk") {
                    if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                    $lnk = $shell.CreateShortcut($file.FullName)
                    $process = Get-StartupProcessName "`"$($lnk.TargetPath)`" $($lnk.Arguments)"
                    if ($lnk.Arguments -match '--processStart') { $process = Get-StartupProcessName $lnk.Arguments }
                    $workDir = $lnk.WorkingDirectory
                }
                # The shortcut (or file) itself is the command: running it keeps its arguments,
                # working folder and window state.
                [PSCustomObject]@{ Source = $dir; Name = $file.Name; Command = "`"$($file.FullName)`""; WorkingDir = $workDir
                                   Process = $process; ApprovedKey = $src.Approved; Previous = $approved.($file.Name) }
            }
        }
    }
}

# Pure: adds the enabled entries to a startup.json config (a hashtable, or $null for a first run)
# and says which entries to switch off in Windows. Entries already in the config (by their
# StartupApproved key and name) aren't added again, but are switched off again if something turned
# them back on (an uninstall/reinstall, or Task Manager). The AltTabSucks item always exists, first
# on a new list. Old AltTabSucks.bat startup scripts are left to the installer, which deletes them.
# With -TakeOver:$false (the user said no at install) nothing is added or switched off, and the
# config remembers it (takeOver: false), so the manager only mentions the entries in its editor,
# not at every logon. Returns @{ Config; TakeOver = entries to switch off }.
function Merge-StartupItems($Config, $Entries, [bool]$TakeOver = $true) {
    if (-not $Config) { $Config = [ordered]@{ version = 1; autoCloseSeconds = 5; readyTimeoutSeconds = 30; items = @() } }
    $items = [Collections.ArrayList]@($Config.items | Where-Object { $_ })
    if (-not ($items | Where-Object { $_.builtin -eq "alttabsucks" })) {
        $items.Insert(0, [ordered]@{ name = "AltTabSucks"; builtin = "alttabsucks"; command = ""; workingDir = ""; process = "AltTabSucks.ahk"
                                     delay = 0; afterReady = $false; ready = "process"; enabled = $true })
    }
    $Config.takeOver = $TakeOver
    $switchOff = @()
    foreach ($e in $(if ($TakeOver) { $Entries } else { @() })) {
        if (-not (Test-StartupApproved $e.Previous)) { continue }  # off in Windows: the user doesn't want it
        if ($e.Name -eq "AltTabSucks.bat") { continue }
        $known = $items | Where-Object { $_.windows -and $_.windows.approvedKey -eq $e.ApprovedKey -and $_.windows.valueName -eq $e.Name }
        if (-not $known) {
            $name = if ($e.ApprovedKey -like "*StartupFolder") { [IO.Path]::GetFileNameWithoutExtension($e.Name) } else { $e.Name }
            $null = $items.Add([ordered]@{
                name = $name; command = $e.Command; workingDir = $e.WorkingDir; process = $e.Process
                delay = 1; afterReady = $false; ready = Get-StartupReadyMode $e.Command; enabled = $true
                windows = [ordered]@{ approvedKey = $e.ApprovedKey; valueName = $e.Name
                                      previous = if ($e.Previous) { [Convert]::ToHexString([byte[]]$e.Previous) } else { $null } }
            })
        }
        $switchOff += $e
    }
    $Config.items = @($items)
    @{ Config = $Config; TakeOver = $switchOff }
}

function Read-StartupConfig([string]$Path = $StartupConfigPath) {
    if (Test-Path $Path) { Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } else { $null }
}
function Save-StartupConfig($Config, [string]$Path = $StartupConfigPath) {
    New-Item (Split-Path $Path) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json $Config -Depth 10), [Text.UTF8Encoding]::new($false))
}

# The entries Import-StartupItems would take over now (on in Windows, not AltTabSucks'), for the
# manager's "new startup items" notice.
function Get-NewStartupEntries([string]$Path = $StartupConfigPath) {
    (Merge-StartupItems (Read-StartupConfig $Path) @(Read-WindowsStartupEntries)).TakeOver
}

function Import-StartupItems([bool]$TakeOver = $true, [string]$Path = $StartupConfigPath) {
    $r = Merge-StartupItems (Read-StartupConfig $Path) @(Read-WindowsStartupEntries) $TakeOver
    Save-StartupConfig $r.Config $Path
    # Off, the way Task Manager writes it: 03, then 3 zero bytes, then when (FILETIME).
    $off = [byte[]](3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
    foreach ($e in $r.TakeOver) {
        try {
            if (-not (Test-Path $e.ApprovedKey)) { New-Item $e.ApprovedKey -Force | Out-Null }
            Set-ItemProperty $e.ApprovedKey $e.Name $off -Type Binary
            Write-Host "Startup manager took over: $($e.Name)"
        } catch {
            Write-Warning "Couldn't turn off $($e.Name) in Windows startup ($($_.Exception.Message)); it may start twice."
        }
    }
    $r
}

# Puts every StartupApproved switch Import-StartupItems flipped back the way it was. The items stay
# in startup.json, so a reinstall takes them over again with their settings.
function Restore-StartupItems([string]$Path = $StartupConfigPath) {
    $config = Read-StartupConfig $Path
    if (-not $config) { return }
    foreach ($item in $config.items) {
        $w = $item.windows
        if (-not $w) { continue }
        try {
            if ($w.previous) { Set-ItemProperty $w.approvedKey $w.valueName ([Convert]::FromHexString($w.previous)) -Type Binary }
            elseif (Test-Path $w.approvedKey) { Remove-ItemProperty $w.approvedKey $w.valueName -ErrorAction SilentlyContinue }
            Write-Host "Restored Windows startup entry: $($w.valueName)"
        } catch {
            Write-Warning "Couldn't restore $($w.valueName) ($($_.Exception.Message))."
        }
    }
}
