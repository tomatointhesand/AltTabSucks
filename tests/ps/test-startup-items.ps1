# test-startup-items.ps1 - tests for Server/StartupItems.ps1: which Windows startup entries the
# startup manager takes over, and the startup.json items it makes of them.
# Run with: bash dev-scripts/run-ps-tests.sh

. "$PSScriptRoot/assert.ps1"
. "$PSScriptRoot/../../Server/StartupItems.ps1"

$runKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
$folder  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
function Entry([string]$name, [string]$cmd, $previous = $null, [string]$approved = $runKey) {
    [PSCustomObject]@{ Source = "x"; Name = $name; Command = $cmd; WorkingDir = ""; Process = Get-StartupProcessName $cmd
                       ApprovedKey = $approved; Previous = $previous }
}

# ---- StartupApproved values -------------------------------------------------------------------
Assert-Equal (Test-StartupApproved $null) $true "no StartupApproved value: on"
Assert-Equal (Test-StartupApproved ([byte[]](2,0,0,0,0,0,0,0,0,0,0,0))) $true "02...: on"
Assert-Equal (Test-StartupApproved ([byte[]](6,0,0,0))) $true "06...: on"
Assert-Equal (Test-StartupApproved ([byte[]](3,0,0,0,1,2,3,4,5,6,7,8))) $false "03...: off"
Assert-Equal (Test-StartupApproved ([byte[]](7,0,0,0))) $false "07...: off"

# ---- process names and ready modes ------------------------------------------------------------
Assert-Equal (Get-StartupProcessName '"C:\Program Files (x86)\Steam\steam.exe" -silent') "steam.exe" "quoted exe"
Assert-Equal (Get-StartupProcessName 'C:\Program Files\App\app.exe /min') "app.exe" "unquoted exe with spaces"
Assert-Equal (Get-StartupProcessName 'C:\Users\me\AppData\Local\Discord\Update.exe --processStart Discord.exe') "Discord.exe" "--processStart"
Assert-Equal (Get-StartupReadyMode '"C:\x\steam.exe" -silent') "process" "-silent: ready when the process runs"
Assert-Equal (Get-StartupReadyMode '"C:\x\app.exe" --start-minimized') "process" "--start-minimized"
Assert-Equal (Get-StartupReadyMode '"C:\x\app.exe" /tray') "process" "/tray"
Assert-Equal (Get-StartupReadyMode '"C:\x\app.exe" --processStart app.exe') "window" "--processStart isn't a tray flag"
Assert-Equal (Get-StartupReadyMode '"C:\Program Files\Hidden Gem\gem.exe"') "window" "a word in the path isn't a flag"

# ---- Merge-StartupItems -----------------------------------------------------------------------
$entries = @(
    Entry "Steam" '"C:\Steam\steam.exe" -silent'
    Entry "Discord" 'C:\Users\me\AppData\Local\Discord\Update.exe --processStart Discord.exe'
    Entry "Already off" 'C:\x\off.exe' ([byte[]](3,0,0,0))
    Entry "Slack.lnk" '"C:\Users\me\Startup\Slack.lnk"' $null $folder
    Entry "AltTabSucks.bat" '"C:\Users\me\Startup\AltTabSucks.bat"' $null $folder
)
$r = Merge-StartupItems $null $entries
$names = @($r.Config.items | ForEach-Object { $_.name })
Assert-Equal $names @("AltTabSucks", "Steam", "Discord", "Slack") "first run: AltTabSucks first, then the entries that are on (shortcut names without .lnk)"
Assert-Equal @($r.TakeOver | ForEach-Object { $_.Name }) @("Steam", "Discord", "Slack.lnk") "  ...and those get switched off in Windows (not the old AltTabSucks.bat, which the installer deletes)"
$steam = $r.Config.items[1]
Assert-Equal ([ordered]@{ process = $steam.process; ready = $steam.ready; delay = $steam.delay; enabled = $steam.enabled }) ([ordered]@{ process = "steam.exe"; ready = "process"; delay = 1; enabled = $true }) "an imported item"
Assert-Equal $steam.windows ([ordered]@{ approvedKey = $runKey; valueName = "Steam"; previous = $null }) "  ...remembers which Windows switch it came from"
Assert-Equal $r.Config.items[2].process "Discord.exe" "Discord's real process"
Assert-Equal $r.Config.items[0].ready "process" "AltTabSucks has no window: ready when it runs"

# Second import, as after a reinstall: nothing new, but Steam was switched back on, Discord is still off.
$config = (ConvertTo-Json $r.Config -Depth 10) | ConvertFrom-Json -AsHashtable
$config.items[1].delay = 7
$again = @(
    Entry "Steam" '"C:\Steam\steam.exe" -silent'
    Entry "Discord" 'C:\Users\me\AppData\Local\Discord\Update.exe --processStart Discord.exe' ([byte[]](3,0,0,0))
    Entry "New app" '"C:\New\new.exe"'
)
$r2 = Merge-StartupItems $config $again
Assert-Equal @($r2.Config.items | ForEach-Object { $_.name }) @("AltTabSucks", "Steam", "Discord", "Slack", "New app") "re-import: only the new entry is added, at the end"
Assert-Equal $r2.Config.items[1].delay 7 "  ...existing items keep their settings"
Assert-Equal @($r2.TakeOver | ForEach-Object { $_.Name }) @("Steam", "New app") "  ...a known entry that's back on is switched off again"
Assert-Equal @($r2.Config.items | Where-Object { $_.builtin -eq "alttabsucks" }).Count 1 "  ...and AltTabSucks isn't added twice"

$moved = [ordered]@{ version = 1; items = @([ordered]@{ name = "Steam"; command = "x"; windows = [ordered]@{ approvedKey = $runKey; valueName = "Steam" } }) }
Assert-Equal @((Merge-StartupItems $moved @()).Config.items | ForEach-Object { $_.name }) @("AltTabSucks", "Steam") "a list without AltTabSucks gets it back, first"

# Declined at install: just AltTabSucks, nothing switched off, and the choice remembered.
$no = Merge-StartupItems $null $entries $false
Assert-Equal @($no.Config.items | ForEach-Object { $_.name }) @("AltTabSucks") "declined: only AltTabSucks in the list"
Assert-Equal @($no.TakeOver).Count 0 "  ...nothing switched off in Windows"
Assert-Equal $no.Config.takeOver $false "  ...and the config remembers the choice"
$yes = Merge-StartupItems ((ConvertTo-Json $no.Config -Depth 10) | ConvertFrom-Json -AsHashtable) $entries
Assert-Equal @($yes.Config.items | ForEach-Object { $_.name }) @("AltTabSucks", "Steam", "Discord", "Slack") "a later Take over adds them after all"
Assert-Equal $yes.Config.takeOver $true "  ...and flips the choice"

Complete-Asserts
