# e2e.ps1 - end-to-end tests on a real Windows desktop. Run inside the test VM by
# dev-scripts/run-windows-tests.sh (over SSH, as the auto-logged-on admin user, on a fresh
# snapshot with this repo at C:\alttabsucks and no lib\config.ahk / lib\app-hotkeys.ahk yet).
#
# SSH sessions have no desktop, so everything that needs one (the installer, AltTabSucks.ahk,
# the dialog driver, Explorer) is launched into the logged-on session through a one-off
# scheduled task (Start-OnDesktop). Windows PowerShell 5.1, like the real server.

$ErrorActionPreference = 'Stop'
$Repo    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Here    = $PSScriptRoot
$Ahk     = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$Pwsh    = "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
$Server  = "http://localhost:9876"
$Work    = Join-Path $env:TEMP "alttabsucks-e2e"
$AppHk   = Join-Path $Repo "lib\app-hotkeys.ahk"
New-Item $Work -ItemType Directory -Force | Out-Null

# A fixed token instead of the random one the server would generate on its first start: the VM
# snapshot's Edge has the extension configured with this one, and every run is a fresh install.
$TestToken = "alttabsucks-vm-test"
Set-Content (Join-Path $Repo "Server\token.txt") $TestToken -NoNewline -Encoding ASCII

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
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $workDir
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
function Get-Token { (Get-Content (Join-Path $Repo "Server\token.txt") -Raw).Trim() }
function Invoke-Api([string]$method, [string]$path, $body = $null) {
    $p = @{ Uri = "$Server$path"; Method = $method; Headers = @{ "X-AltTabSucks-Token" = (Get-Token) }; UseBasicParsing = $true; TimeoutSec = 20 }
    if ($null -ne $body) { $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 10 -Compress)); $p.ContentType = "application/json" }
    try {
        $r = Invoke-WebRequest @p
        [PSCustomObject]@{ Status = [int]$r.StatusCode; Json = $(try { $r.Content | ConvertFrom-Json } catch { $r.Content }) }  # /debugtabs is plain text
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        $text = if ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { $_.Exception.Message }
        [PSCustomObject]@{ Status = $(if ($resp) { [int]$resp.StatusCode } else { 0 }); Json = $(try { $text | ConvertFrom-Json } catch { $text }) }
    }
}

try {
    # ---- fresh install, as a new user would do it -------------------------------------------
    $driverOut = Join-Path $Work "first-run.txt"
    Start-OnDesktop $Ahk "`"$Here\drive-first-run.ahk`" `"$driverOut`"" | Out-Null
    $installLog = Join-Path $Work "install.log"
    Invoke-OnDesktop "cmd.exe" "/c `"`"$Pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$Repo\installer.ps1`" -Action install > `"$installLog`" 2>&1`"" 180

    $task = Get-ScheduledTask -TaskName "AltTabSucks" -ErrorAction SilentlyContinue
    Check ($null -ne $task) "installer registers the AltTabSucks scheduled task" (Get-Content $installLog -Raw -ErrorAction SilentlyContinue)
    Check (Wait-Until { (Invoke-WebRequest "$Server/hotkeys-ui" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } 30) "server answers on :9876"
    Check ((Get-Token) -eq $TestToken) "server keeps an existing token.txt"
    Check (Test-Path $AppHk) "installer created lib\app-hotkeys.ahk from the template"

    Check (Wait-Until { (Get-Content $driverOut -Raw) -match "answered both" } 60) "first launch asks for a browser, then about the default browser" (Get-Content $driverOut -Raw -ErrorAction SilentlyContinue)
    Check (Wait-Until { Test-Path (Join-Path $Repo "lib\config.ahk") } 10) "choosing a browser writes lib\config.ahk"
    $ats = $null
    Check (Wait-Until { ($script:ats = Get-AltTabSucks) -ne $null } 20) "AltTabSucks.ahk is running"
    Check ((Get-Process -Id $ats.ProcessId).SessionId -ne 0) "  ...on the desktop session"

    # ---- starter hotkeys --------------------------------------------------------------------
    # The template has no UI-recognizable hotkeys, so _InitUiHotkeys (3s after start) adds the
    # starter set from lib\hotkeys.template.json, and the watcher reloads to apply it.
    Check (Wait-Until { (Get-Content $AppHk -Raw) -match "\[Hotkeys UI\] starter hotkeys added" } 30) "first start adds the starter hotkeys to app-hotkeys.ahk"
    Check (Wait-Until { ($p = Get-AltTabSucks) -and $p.ProcessId -ne $ats.ProcessId } 15) "  ...and reloads to apply them"
    Start-Sleep -Seconds 3
    $ats = Get-AltTabSucks

    # ---- browser extension ------------------------------------------------------------------
    # The VM's "browser" snapshot has Edge with the extension loaded unpacked from
    # C:\alttabsucks\BrowserExtension (so it runs this working tree's code) and $TestToken set.
    Start-OnDesktop "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" "about:blank" | Out-Null
    Check (Wait-Until { (Invoke-Api GET "/debugtabs").Json -match "=== Profile 1 ===" } 30) "the extension in Edge connects to a freshly installed server" ((Invoke-Api GET "/debugtabs").Json)

    # ---- Hotkeys UI round trip ----------------------------------------------------------------
    $get = Invoke-API GET "/hotkeys-config"
    Check ($get.Status -eq 200) "GET /hotkeys-config" "HTTP $($get.Status): $($get.Json | ConvertTo-Json -Compress -Depth 5)"
    # Where-Object: in 5.1 @($null) has one element, so a failed GET would look like one binding.
    $bindings = @($get.Json.bindings | Where-Object { $_ })
    $invalid = @($get.Json.invalid | Where-Object { $_ })
    Check ($bindings.Count -ge 10 -and $invalid.Count -eq 0 -and "$($get.Json.fileHash)" -ne "") "  ...shows the starter hotkeys, none invalid, with a fileHash" "$($bindings.Count) bindings, $($invalid.Count) invalid: $($invalid | ConvertTo-Json -Compress)"

    if ($bindings.Count -gt 0) {
        $bindings[0].title = "E2E renamed"
        $post = Invoke-API POST "/hotkeys-config" @{ bindings = $bindings; fileHash = $get.Json.fileHash }
        Check ($post.Status -eq 200 -and @($post.Json.dropped).Count -eq 0) "POST /hotkeys-config saves" "HTTP $($post.Status): $($post.Json | ConvertTo-Json -Compress -Depth 5)"
        Check ((Get-Content $AppHk -Raw) -match "; E2E renamed") "  ...rewriting the line in app-hotkeys.ahk"
        Check (Test-Path "$AppHk.bak") "  ...keeping app-hotkeys.ahk.bak"
        $reloaded = Wait-Until { ($p = Get-AltTabSucks) -and $p.ProcessId -ne $ats.ProcessId } 15
        Check $reloaded "  ...and AltTabSucks reloads itself"

        $stale = Invoke-API POST "/hotkeys-config" @{ bindings = $bindings; fileHash = $get.Json.fileHash }
        Check ($stale.Status -eq 409) "a save based on an outdated page is refused (409)" "HTTP $($stale.Status)"
    }

    # ---- a broken hand edit doesn't reload --------------------------------------------------------
    Start-Sleep -Seconds 2
    $ats = Get-AltTabSucks
    $good = Get-Content $AppHk -Raw
    [IO.File]::WriteAllText($AppHk, $good + "`r`n^!+F12:: MsgBox(`r`n")
    Start-Sleep -Seconds 6
    $now = Get-AltTabSucks
    Check ($now -and $now.ProcessId -eq $ats.ProcessId) "a broken app-hotkeys.ahk edit is not reloaded; the running script keeps going"
    Check (-not (Get-Process AutoHotkey64 -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match "AltTabSucks.ahk" -and $_.Id -ne $ats.ProcessId })) "  ...and no error dialog is left open"
    [IO.File]::WriteAllText($AppHk, $good)
    Check (Wait-Until { ($p = Get-AltTabSucks) -and $p.ProcessId -ne $ats.ProcessId } 15) "fixing it reloads again"

    # ---- leftover lib\hotkeys.json from the JSON-based UI is folded in once ------------------
    $legacy = Join-Path $Repo "lib\hotkeys.json"
    Set-Content $legacy '{ "bindings": [ { "type": "windowToggle", "title": "E2E Notepad", "key": "Ctrl+Alt+Shift+F11", "resourceClass": "notepad.exe", "launchArgv": ["notepad.exe"], "enabled": true } ] }' -Encoding UTF8
    $fold = Invoke-API POST "/init-hotkeys" @{ profile = "Default" }
    Check ($fold.Status -eq 200 -and $fold.Json.folded -eq 1) "/init-hotkeys folds a leftover lib\hotkeys.json into app-hotkeys.ahk" "HTTP $($fold.Status): $($fold.Json | ConvertTo-Json -Compress)"
    Check ((Get-Content $AppHk -Raw) -match '\^!\+F11:: ManageAppWindows\("notepad\.exe"') "  ...as a real hotkey line"
    Check (-not (Test-Path $legacy) -and @(Get-ChildItem "$legacy.folded-*").Count -eq 1) "  ...and renames hotkeys.json aside"
    $again = Invoke-API POST "/init-hotkeys" @{ profile = "Default" }
    Check ($again.Json.folded -eq 0 -and $again.Json.seeded -eq 0) "  ...only once"
    Check (Wait-Until { (Get-AltTabSucks) -ne $null } 15) "AltTabSucks is still running after all that"

    # ---- folder hotkeys don't open duplicate Explorer windows --------------------------------
    $folder = Join-Path $Work "folder-under-test"
    New-Item $folder -ItemType Directory -Force | Out-Null
    $mashOut = Join-Path $Work "explorer-mash.txt"
    Start-OnDesktop $Ahk "`"$Here\explorer-mash.ahk`" `"$folder`" `"$mashOut`"" | Out-Null
    Wait-Until { (Get-Content $mashOut -Raw) -match "active_is_explorer" } 30 | Out-Null
    $mash = @{}; foreach ($l in (Get-Content $mashOut -ErrorAction SilentlyContinue)) { $k, $v = $l -split '=', 2; if ($v) { $mash[$k] = $v } }
    Check ($mash["after_mash"] -eq "1") "mashing a folder hotkey opens exactly one Explorer window" "got $($mash['after_mash'])"
    Check ($mash["after_second_press"] -eq "1") "  ...and a later press focuses it instead of opening another" "got $($mash['after_second_press'])"
    # ---- uninstall ------------------------------------------------------------------------------
    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File "$Repo\installer.ps1" -Action uninstall | Out-Null
    Check (-not (Get-ScheduledTask -TaskName "AltTabSucks" -ErrorAction SilentlyContinue)) "uninstall removes the scheduled task"
    Check (Wait-Until { -not (Get-NetTCPConnection -LocalPort 9876 -State Listen -ErrorAction SilentlyContinue) } 10) "  ...and stops the server"
} finally {
    Remove-E2eTasks
    Write-Host "`n$script:Passed passed, $script:Failed failed"
}
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
