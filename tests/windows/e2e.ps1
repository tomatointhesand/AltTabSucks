# e2e.ps1 - end-to-end tests on a real Windows desktop. Run inside the test VM by
# dev-scripts/run-windows-tests.sh (over SSH, as the auto-logged-on admin user, on a fresh
# snapshot with this repo at C:\alttabsucks and no lib\config.ahk / lib\app-hotkeys.ahk yet).
#
# SSH sessions have no desktop, so everything that needs one (the installer, AltTabSucks.ahk,
# the dialog driver, Explorer) is launched into the logged-on session through a one-off
# scheduled task (Start-OnDesktop). PowerShell 7, like the real server.

. "$PSScriptRoot\helpers.ps1"  # $Repo, $Here, $Ahk, $Pwsh, Check, Wait-Until, Start-OnDesktop...
$Server  = "http://localhost:9876"
$Work    = Join-Path $env:TEMP "alttabsucks-e2e"
$AppHk   = Join-Path $Repo "lib\app-hotkeys.ahk"
New-Item $Work -ItemType Directory -Force | Out-Null

# A fixed token instead of the random one the server would generate on its first start: the VM
# snapshot's Edge has the extension configured with this one, and every run is a fresh install.
$TestToken = "alttabsucks-vm-test"
Set-Content (Join-Path $Repo "Server\token.txt") $TestToken -NoNewline -Encoding ASCII

function Get-Token { (Get-Content (Join-Path $Repo "Server\token.txt") -Raw).Trim() }
function Invoke-Api([string]$method, [string]$path, $body = $null) {
    $p = @{ Uri = "$Server$path"; Method = $method; Headers = @{ "X-AltTabSucks-Token" = (Get-Token) }; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($null -ne $body) { $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 10 -Compress)); $p.ContentType = "application/json" }
    try {
        $r = Invoke-WebRequest @p -SkipHttpErrorCheck  # 4xx/5xx come back as results, not exceptions
        [PSCustomObject]@{ Status = [int]$r.StatusCode; Json = $(try { $r.Content | ConvertFrom-Json } catch { $r.Content }) }  # /debugtabs is plain text
    } catch {
        [PSCustomObject]@{ Status = 0; Json = $_.Exception.Message }  # couldn't connect at all
    }
}

# The startup manager's files, and two Windows startup entries for the installer to take over.
$SmConfig    = "$env:LOCALAPPDATA\AltTabSucks\startup.json"
$SmHistory   = "$env:LOCALAPPDATA\AltTabSucks\startup-history.jsonl"
$SmErrors    = "$env:LOCALAPPDATA\AltTabSucks\startup-errors.log"
$RunKey      = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$ApprovedRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
Set-ItemProperty $RunKey "E2E Notepad" "notepad.exe"
Set-ItemProperty $RunKey "E2E Charmap" "$env:windir\System32\charmap.exe"

try {
    # ---- fresh install, as a new user would do it -------------------------------------------
    $driverOut = Join-Path $Work "first-run.txt"
    Start-OnDesktop $Ahk "`"$Here\drive-first-run.ahk`" `"$driverOut`"" | Out-Null
    $installLog = Join-Path $Work "install.log"
    Invoke-OnDesktop "cmd.exe" "/c `"`"$Pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$Repo\installer.ps1`" -Action install > `"$installLog`" 2>&1`"" 180

    $task = Get-ScheduledTask -TaskName "AltTabSucks" -ErrorAction SilentlyContinue
    Check ($null -ne $task) "installer registers the AltTabSucks scheduled task" (Get-Content $installLog -Raw -ErrorAction SilentlyContinue)
    Check (Wait-Until { (Invoke-WebRequest "$Server/hotkeys-ui" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } 30) "server answers on :9876"
    $serverProc = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*AltTabSucksServer.ps1*" } | Select-Object -First 1
    Check ($serverProc.Name -eq "pwsh.exe") "  ...running under PowerShell 7" "process: $($serverProc.Name)"
    Check ((Get-Token) -eq $TestToken) "server keeps an existing token.txt"
    Check ((Get-Content $installLog -Raw) -match "connects by itself") "  ...and the installer says the extension connects by itself (no token to paste)" (Get-Content $installLog -Raw)

    # ---- who may call without the token (Server/RequestAuth.ps1) -----------------------------
    # Headers a browser sets itself, faked here; the page and extension sections below send real ones.
    function Get-Status([string]$method, [string]$path, [hashtable]$headers) {
        try { [int](Invoke-WebRequest "$Server$path" -Method $method -Headers $headers -UseBasicParsing -TimeoutSec 10 -SkipHttpErrorCheck).StatusCode } catch { 0 }
    }
    Check ((Get-Status GET "/hotkeys-config" @{}) -eq 403) "no token: refused"
    Check ((Get-Status GET "/hotkeys-config" @{ "Sec-Fetch-Site" = "same-origin" }) -eq 200) "  ...but the Hotkeys page's own requests (same-origin) need none"
    Check ((Get-Status GET "/hotkeys-config" @{ "Sec-Fetch-Site" = "cross-site"; Origin = "https://evil.example.com" }) -eq 403) "  ...while another site's are refused"
    Check ((Get-Status POST "/extension-pairing" @{}) -eq 403) "opening extension pairing needs the token"
    $pair = Invoke-Api POST "/extension-pairing"
    Check ($pair.Status -eq 200 -and $pair.Json.minutes -eq 10) "  ...with it, it opens for 10 minutes" "HTTP $($pair.Status): $($pair.Json | ConvertTo-Json -Compress)"
    $given = try { (Invoke-RestMethod "$Server/extension-token" -Method Post -Headers @{ Origin = "chrome-extension://e2e" } -TimeoutSec 10).token } catch { $_.Exception.Message }
    Check ($given -eq $TestToken) "  ...and a browser extension asking for the token gets it" $given
    Check ((Get-Status POST "/extension-token" @{ Origin = "https://evil.example.com" }) -eq 403) "  ...but a web page doesn't"
    Check (Test-Path $AppHk) "installer created lib\app-hotkeys.ahk from the template"

    # The startup manager is off by default: AltTabSucks.ahk starts at logon through its own task.
    $ahkTask = Get-ScheduledTask -TaskName "AltTabSucks AHK" -ErrorAction SilentlyContinue
    Check (-not (Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue)) "the startup manager is off after install"
    Check ($ahkTask -and "$($ahkTask.Principal.RunLevel)" -eq "Highest" -and $ahkTask.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger") `
        "  ...AltTabSucks.ahk starts at logon through its own elevated task" "$($ahkTask.Triggers | Out-String) $($ahkTask.Principal | Out-String)"
    Check (-not (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\AltTabSucks.bat")) "  ...instead of a Startup folder script"
    Check ($null -eq (Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Notepad") "  ...and the Windows startup entries are left alone"
    $settings = Invoke-Api GET "/settings"
    Check ($settings.Status -eq 200 -and $settings.Json.platform -eq "windows" -and $settings.Json.startupManager.enabled -eq $false) "  ...and GET /settings says so" ($settings.Json | ConvertTo-Json -Compress)

    # Switched on (the Hotkeys page's settings switch; the page itself is driven further down).
    $on = Invoke-Api POST "/settings" @{ startupManager = $true }
    Check ($on.Status -eq 200 -and $on.Json.startupManager.enabled -eq $true) "POST /settings switches the startup manager on" ($on.Json | ConvertTo-Json -Compress)
    $smTask = Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue
    Check ($smTask -and $smTask.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" -and "$($smTask.Principal.RunLevel)" -eq "Limited" -and $smTask.Settings.Priority -eq 4) `
        "  ...its logon task (not elevated, normal priority)" "$($smTask.Triggers | Out-String) $($smTask.Principal | Out-String) priority $($smTask.Settings.Priority)"
    $ahkTask = Get-ScheduledTask -TaskName "AltTabSucks AHK" -ErrorAction SilentlyContinue
    Check ($ahkTask -and "$($ahkTask.Principal.RunLevel)" -eq "Highest" -and -not $ahkTask.Triggers) "  ...and AltTabSucks.ahk's task now runs on demand (the manager starts it)"
    $sm = Get-Content $SmConfig -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable
    Check ($sm.items[0].builtin -eq "alttabsucks" -and -not $sm.Contains("takeOver") -and ($null -eq (Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Notepad")) `
        "  ...with no console to ask on, the Windows startup apps are left for its notice" (Get-Content $SmConfig -Raw -ErrorAction SilentlyContinue)
    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File "$Repo\installer.ps1" -Action startup-import | Out-Null
    $sm = Get-Content $SmConfig -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    $smNotepad = @($sm.items | Where-Object { $_.name -eq "E2E Notepad" })[0]
    Check ($sm.items[0].builtin -eq "alttabsucks" -and $smNotepad.process -eq "notepad.exe" -and $smNotepad.windows.valueName -eq "E2E Notepad") `
        "taking them over moves the Windows startup entries into startup.json, after AltTabSucks" (Get-Content $SmConfig -Raw -ErrorAction SilentlyContinue)
    Check ((Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Notepad"[0] -eq 3) "  ...and turns them off in Windows startup"

    Check (Wait-Until { (Get-Content $driverOut -Raw) -match "answered both" } 60) "first launch asks for a browser, then about the default browser" (Get-Content $driverOut -Raw -ErrorAction SilentlyContinue)
    Check (Wait-Until { Test-Path (Join-Path $Repo "lib\config.ahk") } 10) "choosing a browser writes lib\config.ahk"
    # Edge only runs this working tree's extension when started with --load-extension (see the
    # "browser extension" section below), and an extension loaded that way is dropped again by a
    # normal launch. So every Edge AltTabSucks itself launches gets the flag too (it's read at
    # AltTabSucks' next reload, long before the launch tests).
    Add-Content (Join-Path $Repo "lib\config.ahk") "`r`nglobal CHROMIUM_EXTRA_FLAGS := `"--load-extension=$Repo\BrowserExtension`""
    $ats = $null
    Check (Wait-Until { ($script:ats = Get-AltTabSucks) -ne $null } 20) "AltTabSucks.ahk is running"
    Check ((Get-Process -Id $ats.ProcessId).SessionId -ne 0) "  ...on the desktop session"

    # ---- starter hotkeys --------------------------------------------------------------------
    # The template has no UI-recognizable hotkeys, so _InitUiHotkeys (3s after start) adds the
    # starter set from lib\hotkeys.template.json, and the watcher reloads to apply it.
    Check (Wait-Until { (Get-Content $AppHk -Raw) -match "\[Hotkeys UI\] starter hotkeys: notepad " } 30) "first start adds the starter hotkeys to app-hotkeys.ahk"
    # Not "the process ID changed": the reload can happen before $ats was read. The running script
    # must have started after the starter hotkeys were written.
    Check (Wait-Until { ($p = Get-AltTabSucks) -and $p.CreationDate -ge (Get-Item $AppHk).LastWriteTime.AddSeconds(-1) } 15) "  ...and reloads to apply them" `
        "process started $((Get-AltTabSucks).CreationDate), file written $((Get-Item $AppHk).LastWriteTime)"
    Start-Sleep -Seconds 3
    $ats = Get-AltTabSucks

    # ---- browser extension ------------------------------------------------------------------
    # The VM's "browser" snapshot has Edge with the extension loaded unpacked from
    # C:\alttabsucks\BrowserExtension and $TestToken set. --load-extension makes Edge load this
    # working tree's code: Chromium doesn't re-read an unpacked extension's files when it starts
    # (that takes Reload on the extensions page), so without it Edge ran the snapshot's old copy.
    Start-OnDesktop "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" "--load-extension=`"$Repo\BrowserExtension`" about:blank" | Out-Null
    Check (Wait-Until { (Invoke-Api GET "/debugtabs").Json -match "=== Profile 1 ===" } 30) "the extension in Edge connects to a freshly installed server" ((Invoke-Api GET "/debugtabs").Json)

    # The Hotkeys page's "Manage extension" link: the server asks the extension to open its own
    # entry in Edge's extension manager (a web page can't open edge://extensions itself).
    $open = Invoke-Api POST "/open-extension-page"
    Check ($open.Status -eq 200 -and $open.Json.profile -eq "Profile 1") "the Manage extension link asks Edge's extension" "HTTP $($open.Status): $($open.Json | ConvertTo-Json -Compress)"
    Check (Wait-Until { @((Invoke-Api GET "/tabs").Json."Profile 1" | ForEach-Object { @($_.tabs) } | Where-Object { "$($_.fullUrl)$($_.url)" -match "^(edge|chrome)://extensions" }).Count -gt 0 } 15) `
        "  ...which opens its page in Edge's extension manager"

    # ---- Hotkeys UI round trip ----------------------------------------------------------------
    $get = Invoke-API GET "/hotkeys-config"
    Check ($get.Status -eq 200) "GET /hotkeys-config" "HTTP $($get.Status): $($get.Json | ConvertTo-Json -Compress -Depth 5)"
    # Where-Object: in 5.1 @($null) has one element, so a failed GET would look like one binding.
    $bindings = @($get.Json.bindings | Where-Object { $_ })
    $invalid = @($get.Json.invalid | Where-Object { $_ })
    Check ($bindings.Count -ge 10 -and $invalid.Count -eq 0 -and "$($get.Json.fileHash)" -ne "") "  ...shows the starter hotkeys, none invalid, with a fileHash" "$($bindings.Count) bindings, $($invalid.Count) invalid: $($invalid | ConvertTo-Json -Compress)"

    $dl = @($bindings | Where-Object { $_.type -eq "folder" })
    Check ($dl.Count -eq 1 -and $dl[0].path -eq (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path) "  ...Downloads as a folder hotkey, with the real Downloads folder" ($dl | ConvertTo-Json -Compress)

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

    # ---- a starter hotkey that comes with an update, on a key that's taken ----------------------
    # As if tab search were new: its line becomes a hand-written hotkey on the same key, and the
    # marker forgets it was offered. That edit reloads AltTabSucks, whose startup /init-hotkeys
    # call then offers it.
    Start-Sleep -Seconds 2
    $before = Get-Content $AppHk -Raw
    $upd = $before -replace '(?m)^\^!\+a:: ShowTabSearch\(\)[^\r\n]*', '^!+a:: Send("e2e")' -replace '(starter hotkeys: [^\r\n]*?)tabSearch ', '$1'
    Check ($upd -cne $before -and $upd -notmatch 'starter hotkeys: [^\r\n]*tabSearch') "(set up: tab search's key taken by a hand-written hotkey)"
    [IO.File]::WriteAllText($AppHk, $upd)
    Check (Wait-Until { (Get-Content $AppHk -Raw) -match '(?m)^; \[disabled\] \^!\+a:: ShowTabSearch\(\)' } 30) "after an update, AltTabSucks adds a new starter hotkey whose key is taken switched off"
    $text = Get-Content $AppHk -Raw
    Check ($text.Contains('^!+a:: Send("e2e")') -and $text -match 'starter hotkeys: [^\r\n]*tabSearch') "  ...leaving the hotkey on its key alone, and remembering it"
    $st = Invoke-API POST "/init-hotkeys" @{ profile = "Default" }
    Check ($st.Status -eq 200 -and "$($st.Json.notice)" -eq "" -and (Get-Content $AppHk -Raw) -ceq $text) "  ...once" "HTTP $($st.Status): $($st.Json | ConvertTo-Json -Compress)"
    Check (Wait-Until { ($p = Get-AltTabSucks) -and $p.CreationDate -ge (Get-Item $AppHk).LastWriteTime.AddSeconds(-1) } 15) "  ...and reloads with it"
    Start-Sleep -Seconds 4
    $ats = Get-AltTabSucks
    [IO.File]::WriteAllText($AppHk, $before)
    Check (Wait-Until { ($p = Get-AltTabSucks) -and $p.ProcessId -ne $ats.ProcessId } 15) "(tab search's starter hotkey put back)"
    # Let the reloaded script take its first look at the file: a save before that wouldn't reload it.
    Start-Sleep -Seconds 4

    # ---- tab focus hotkeys (FocusTab through the extension in Edge) ---------------------------
    # Two bindings added through the API, on local pages so nothing depends on the internet:
    # F9 matches either of two pages (several matching tabs -> cycles), F8 matches a page that
    # isn't open (-> opens it). Keys are pressed on the desktop by press.ahk.
    $cfg = Invoke-Api GET "/hotkeys-config"
    $tabBindings = @($cfg.Json.bindings | Where-Object { $_ }) + @(
        [PSCustomObject]@{ type = "tabFocus"; title = "E2E tabs"; key = "Ctrl+Alt+Shift+F9"; enabled = $true; profileName = "Profile 1"
                           urlPatterns = @("localhost:9876/hotkeys-ui", "localhost:9876/debugtabs"); openUrl = "http://localhost:9876/hotkeys-ui" }
        [PSCustomObject]@{ type = "tabFocus"; title = "E2E missing tab"; key = "Ctrl+Alt+Shift+F8"; enabled = $true; profileName = "Profile 1"
                           urlPatterns = @("localhost:9876/profiles"); openUrl = "http://localhost:9876/profiles" }
        [PSCustomObject]@{ type = "profileCycle"; title = "E2E cycle profile"; key = "Ctrl+Alt+Shift+F7"; enabled = $true; profileName = "Profile 1" })
    $ats = Get-AltTabSucks
    $save = Invoke-Api POST "/hotkeys-config" @{ bindings = $tabBindings; fileHash = $cfg.Json.fileHash }
    Check ($save.Status -eq 200 -and @($save.Json.dropped).Count -eq 0) "tab focus hotkeys can be added through the API" "HTTP $($save.Status): $($save.Json | ConvertTo-Json -Compress -Depth 5)"
    Wait-Until { ($p = Get-AltTabSucks) -and $p.ProcessId -ne $ats.ProcessId } 15 | Out-Null
    Start-Sleep -Seconds 3

    function Get-ActiveTabUrl {  # the active tab of Edge's focused window, as the extension reports it
        $wins = @((Invoke-Api GET "/tabs").Json."Profile 1")
        $w = @($wins | Where-Object { $_.focused }) + @($wins) | Select-Object -First 1
        "$((@($w.tabs) | Where-Object { $_.active } | Select-Object -First 1).url)"
    }
    function Open-Tab([string]$url) { Invoke-Api POST "/switchtab" @{ profile = "Profile 1"; openUrl = $url } | Out-Null }
    function Press([string]$keys, [string]$fromExe = "") {
        $o = Join-Path $Work "press.txt"
        Remove-Item $o -ErrorAction SilentlyContinue
        $argLine = "`"$Here\press.ahk`" `"$o`" `"$keys`"" + $(if ($fromExe) { " `"$fromExe`"" } else { "" })
        Start-OnDesktop $Ahk $argLine | Out-Null
        Wait-Until { (Get-Content $o -Raw) -match "active=" } 30 | Out-Null
        $r = @{}; foreach ($l in (Get-Content $o -ErrorAction SilentlyContinue)) { $k, $v = $l -split '=', 2; $r[$k] = $v }
        $r
    }

    Open-Tab "http://localhost:9876/hotkeys-ui"
    Wait-Until { (Get-ActiveTabUrl) -match "hotkeys-ui" } 15 | Out-Null
    Open-Tab "http://localhost:9876/activetitles"   # a page neither hotkey matches
    Check (Wait-Until { (Get-ActiveTabUrl) -notmatch "hotkeys-ui" } 15) "setup: another tab is active" (Get-ActiveTabUrl)

    Start-OnDesktop "notepad.exe" "" | Out-Null
    $r = Press "^!+{F9}" "Notepad.exe"
    Check ($r["before"] -match "notepad") "  (pressed from Notepad)" "before=$($r['before']) $($r['error'])"
    Check ($r["active"] -eq "msedge.exe") "a tab focus hotkey pressed in another app brings Edge to the front" "active=$($r['active'])"
    Check (Wait-Until { (Get-ActiveTabUrl) -match "localhost:9876/hotkeys-ui" } 10) "  ...on the matching tab" (Get-ActiveTabUrl)

    Open-Tab "http://localhost:9876/activetitles"
    Wait-Until { (Get-ActiveTabUrl) -notmatch "hotkeys-ui" } 10 | Out-Null
    $r = Press "^!+{F9}"
    Check (Wait-Until { (Get-ActiveTabUrl) -match "localhost:9876/hotkeys-ui" } 10) "pressed inside Edge, it switches to the matching tab" "$(Get-ActiveTabUrl), active window $($r['active'])"

    Open-Tab "http://localhost:9876/debugtabs"
    Wait-Until { (Get-ActiveTabUrl) -match "debugtabs" } 10 | Out-Null
    $seen = @()
    foreach ($i in 1..2) { Press "^!+{F9}" | Out-Null; Start-Sleep -Milliseconds 500; $seen += (Get-ActiveTabUrl) }
    Check (($seen -match "hotkeys-ui").Count -eq 1 -and ($seen -match "debugtabs").Count -eq 1) "with two matching tabs, repeated presses cycle between them" ($seen -join " -> ")

    $r = Press "^!+{F8}"
    Check (Wait-Until { (Get-ActiveTabUrl) -match "localhost:9876/profiles" } 10) "with no matching tab, it opens the URL in a new tab" "$(Get-ActiveTabUrl), active window $($r['active'])"
    Get-Process Notepad -ErrorAction SilentlyContinue | Stop-Process -Force

    # ---- split / merge, and cycling browser windows -------------------------------------------
    # Through the starter hotkeys: Alt+X split, Alt+Z merge, Ctrl+Alt+Shift+B all browser windows;
    # plus the single-profile Ctrl+Alt+Shift+F7 added above.
    $starter = @((Invoke-Api GET "/hotkeys-config").Json.bindings | Where-Object { $_ })
    Check ((@($starter | Where-Object { $_.type -eq "splitTab" -and $_.key -eq "Alt+X" }).Count -eq 1) -and
           (@($starter | Where-Object { $_.type -eq "mergeTabs" -and $_.key -eq "Alt+Z" }).Count -eq 1) -and
           (@($starter | Where-Object { $_.type -eq "profileCycle" -and $_.key -eq "Ctrl+Alt+Shift+B" -and $_.profileName -eq "__all__" }).Count -eq 1)) `
        "the starter set has split, merge and cycle-all-browser-windows hotkeys"

    function Get-EdgeWindows { @((Invoke-Api GET "/tabs").Json."Profile 1" | Where-Object { $_ }) }
    function Get-TabCount { (@(Get-EdgeWindows | ForEach-Object { @($_.tabs) }) | Measure-Object).Count }
    function Get-EdgeRects([hashtable]$r) {  # press.ahk's "edge=hwnd:x,y,w,h;..." -> objects
        @("$($r['edge'])" -split ';' | Where-Object { $_ } | ForEach-Object {
            $h, $rect = $_ -split ':'; $x, $y, $w, $hh = $rect -split ','
            [PSCustomObject]@{ Hwnd = $h; X = [int]$x; W = [int]$w; H = [int]$hh } })
    }
    # @(...).Count throughout: in 5.1 a function returning one object hands back the object itself,
    # and a lone PSCustomObject has no .Count.
    Check (@(Get-EdgeWindows).Count -eq 1) "setup: one Edge window" "$(@(Get-EdgeWindows).Count) windows"
    $tabsBefore = Get-TabCount
    $focused = @(Get-EdgeWindows)[0]
    $splitTabId = (@($focused.tabs) | Where-Object { $_.active } | Select-Object -First 1).id

    $r = Press "!x"
    Check (Wait-Until { @(Get-EdgeWindows).Count -eq 2 } 10) "Alt+X splits the active tab into its own window" "$(@(Get-EdgeWindows).Count) windows"
    $splitWin = @(Get-EdgeWindows | Where-Object { @($_.tabs).Count -eq 1 -and @($_.tabs)[0].id -eq $splitTabId })
    Check ($splitWin.Count -eq 1) "  ...holding just that tab"
    $r = Press ""
    # Browser windows only: Edge sometimes has a small popup or bubble window up as well.
    $rects = @(Get-EdgeRects $r | Where-Object { $_.W -ge 400 -and $_.H -ge 300 })
    $half = [int]$r["screen"] * 0.6
    # Two Edge windows only fit side by side on a reasonably wide screen (Edge won't go much
    # narrower than ~500px), and the VM's resolution follows its window on the host.
    if ([int]$r["screen"] -lt 1100) {
        Write-Host "SKIP    ...and snaps the two windows side by side (VM screen only $($r['screen'])px wide; widen the VM window)"
    } else {
        Check ($rects.Count -eq 2 -and @($rects | Where-Object { $_.W -lt $half }).Count -eq 2 -and [Math]::Abs($rects[0].X - $rects[1].X) -gt 100) `
            "  ...and snaps the two windows side by side" "screen $($r['screen']): $($r['edge'])"
    }

    $a = Press "^!+b"; $b = Press "^!+b"
    Check ($a["active"] -eq "msedge.exe" -and $b["active"] -eq "msedge.exe" -and $a["hwnd"] -ne $b["hwnd"]) `
        "Ctrl+Alt+Shift+B cycles between the browser windows" "$($a['active']) $($a['hwnd']) -> $($b['active']) $($b['hwnd'])"
    $a = Press "^!+{F7}"; $b = Press "^!+{F7}"
    Check ($a["active"] -eq "msedge.exe" -and $b["active"] -eq "msedge.exe" -and $a["hwnd"] -ne $b["hwnd"]) `
        "a single-profile cycle hotkey cycles that profile's windows" "$($a['active']) $($a['hwnd']) -> $($b['active']) $($b['hwnd'])"
    Start-OnDesktop "notepad.exe" "" | Out-Null
    $r = Press "^!+{F7}" "Notepad.exe"
    Check ($r["before"] -match "notepad" -and $r["active"] -eq "msedge.exe") "  ...and brings the browser forward from another app" "before=$($r['before']) active=$($r['active'])"
    Get-Process Notepad -ErrorAction SilentlyContinue | Stop-Process -Force

    $r = Press "!z"
    Check (Wait-Until { @(Get-EdgeWindows).Count -eq 1 } 10) "Alt+Z merges the split tab back" "$(@(Get-EdgeWindows).Count) windows"
    Check ((Get-TabCount) -eq $tabsBefore) "  ...with every tab kept" "$tabsBefore before, $(Get-TabCount) after"

    # ---- tab search popup (Ctrl+Alt+Shift+A, from the starter set) ------------------------------
    # Driven by tab-search.ahk: open the popup, type, press keys, read its list.
    function Drive-TabSearch([string[]]$steps) {
        $o = Join-Path $Work "tab-search.txt"
        Remove-Item $o -ErrorAction SilentlyContinue
        Start-OnDesktop $Ahk ("`"$Here\tab-search.ahk`" `"$o`" " + (($steps | ForEach-Object { "`"$_`"" }) -join " ")) | Out-Null
        Wait-Until { (Get-Content $o -Raw) -match "(?m)^done" } 60 | Out-Null
        $lines = @(Get-Content $o -ErrorAction SilentlyContinue)
        [PSCustomObject]@{
            Rows   = @($lines | Where-Object { $_ -like "row=*" } | ForEach-Object { $_.Substring(4) })
            Popup  = @($lines | Where-Object { $_ -like "popup=*" } | ForEach-Object { $_.Substring(6) })
            Errors = @($lines | Where-Object { $_ -like "error=*" })
        }
    }
    function Get-AllTabUrls { @(Get-EdgeWindows | ForEach-Object { @($_.tabs) } | ForEach-Object { "$($_.fullUrl)" }) }

    Open-Tab "http://localhost:9876/hotkeys-ui"  # be on a known tab, so it's the one left out
    Wait-Until { (Get-ActiveTabUrl) -match "hotkeys-ui" } 10 | Out-Null
    $d = Drive-TabSearch @("open", "read", "key:{Esc}")
    $urls = @($d.Rows | ForEach-Object { ($_ -split "`t")[-1] })
    Check ($d.Popup[0] -eq "open" -and $d.Rows.Count -ge 2) "Ctrl+Alt+Shift+A opens the tab search popup, listing open tabs" "$($d.Errors) rows: $($d.Rows -join ' | ')"
    Check (-not ($urls -match "hotkeys-ui")) "  ...without the tab you're on" ($urls -join " | ")
    Check ($d.Popup[-1] -eq "closed") "  ...and Esc closes it"

    $d = Drive-TabSearch @("open", "type:activetitles", "read", "key:{Enter}")
    Check ($d.Rows.Count -ge 1 -and @($d.Rows | Where-Object { $_ -notmatch "activetitles" }).Count -eq 0) "typing filters the list" ($d.Rows -join " | ")
    Check ($d.Popup[-1] -eq "closed" -and (Wait-Until { (Get-ActiveTabUrl) -match "activetitles" } 10)) "  ...and Enter switches Edge to that tab" "$(Get-ActiveTabUrl)"

    $d = Drive-TabSearch @("open", "type:debugtabs", "key:^w", "read")
    Check ($d.Popup[-1] -eq "open" -and $d.Rows.Count -eq 0) "Ctrl+W removes the tab from the list and keeps the popup open" "$($d.Popup -join ',') rows: $($d.Rows -join ' | ')"
    Check (Wait-Until { -not ((Get-AllTabUrls) -match "debugtabs") } 10) "  ...and closes it in Edge" ((Get-AllTabUrls) -join " | ")
    Start-OnDesktop $Ahk "`"$Here\press.ahk`" `"$Work\esc.txt`" `"{Esc}`" `"AutoHotkey64.exe`"" | Out-Null
    Start-Sleep -Seconds 3

    $d = Drive-TabSearch @("open", "type:debugtabs", "read", "key:{Enter}")
    Check ($d.Rows.Count -ge 1) "the closed tab is offered under Recently closed" ($d.Rows -join " | ")
    Check (Wait-Until { (Get-AllTabUrls) -match "debugtabs" } 10) "  ...and Enter restores it" ((Get-AllTabUrls) -join " | ")

    Check (Wait-Until { (Invoke-Api GET "/favicon?key=localhost%3A9876%2Fhotkeys-ui").Status -eq 200 } 15) "the extension uploads favicons for the popup"

    # ---- hotkeys launch Edge when it isn't running ---------------------------------------------
    function Close-Edge {
        # Invoke-, not Start-OnDesktop: wait for taskkill itself to finish. Otherwise, with Edge already
        # closed, the wait below passes at once and the still-pending taskkill fires a moment later,
        # killing the Edge the next hotkey launches. No /F: a normal close, no "restore pages?".
        Invoke-OnDesktop "taskkill.exe" "/IM msedge.exe" 30
        Wait-Until { -not (Get-Process msedge -ErrorAction SilentlyContinue) } 30
    }
    function Wait-EdgeInFront([int]$seconds) {
        Wait-Until { (Press "")["active"] -eq "msedge.exe" } $seconds
    }
    function Get-Diag {  # why a launch didn't happen
        $r = Press ""
        "AltTabSucks running: $([bool](Get-AltTabSucks)); msedge processes: $(@(Get-Process msedge -ErrorAction SilentlyContinue).Count); " +
        "front: $($r['active']) '$($r['title'])'; popups: $($r['guis'])"
    }
    Check (Close-Edge) "setup: Edge closed"
    Press "^!+{F9}" | Out-Null
    Check (Wait-Until { (Get-ActiveTabUrl) -match "localhost:9876/hotkeys-ui" } 30) "a tab focus hotkey with Edge closed launches it and opens the page" "$(Get-ActiveTabUrl); $(Get-Diag)"
    Check (Wait-EdgeInFront 15) "  ...in front"

    Check (Close-Edge) "setup: Edge closed again"
    Press "^!+{F7}" | Out-Null
    Check (Wait-Until { Get-Process msedge -ErrorAction SilentlyContinue } 15) "a profile cycle hotkey with Edge closed launches that profile" (Get-Diag)
    Check (Wait-EdgeInFront 20) "  ...in front"

    Check (Close-Edge) "setup: Edge closed again"
    Press "^!+b" | Out-Null
    Check (Wait-Until { Get-Process msedge -ErrorAction SilentlyContinue } 15) "Ctrl+Alt+Shift+B with no browser open launches the default profile" (Get-Diag)
    Check (Wait-EdgeInFront 20) "  ...in front"

    # ---- the Hotkeys page itself, in Edge --------------------------------------------------------
    # CalculateNativeWinOcclusion off: otherwise a tab counts as hidden whenever another window
    # covers this one, and "brought to the front" checks would depend on what earlier tests left open.
    # Drives shared/hotkeys-ui.html like a user (typing into fields, clicking buttons) through Edge's
    # DevTools protocol (cdp.ps1), in a throwaway Edge profile: remote debugging doesn't work on
    # the default one.
    . (Join-Path $Here "cdp.ps1")
    $cdpPort = 9229
    Start-OnDesktop "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" `
        "--remote-debugging-port=$cdpPort --user-data-dir=`"$Work\edge-cdp`" --no-first-run --no-default-browser-check --load-extension=`"$Repo\BrowserExtension`" --disable-features=CalculateNativeWinOcclusion http://localhost:9876/hotkeys-ui" | Out-Null
    Connect-Cdp $cdpPort "*localhost:9876/hotkeys-ui*" 30
    # Edge lists the tab under its URL while still navigating, with a blank placeholder document.
    Wait-Until { (Invoke-Js 'location.origin + " " + document.readyState') -eq "http://localhost:9876 complete" } 20 | Out-Null
    # Page helpers, prefixed to each script: a row by its title, a row's text inputs, typing, status.
    # Assignments rather than const: every evaluation runs in the page's global scope, so these are
    # re-run before each script. statusEl, not status: window.status is a built-in string property.
    $js = @'
row = (t) => [...document.querySelectorAll(".binding")].find(r => { const i = r.querySelector("input[type=text]"); return i && i.value === t; });
inputs = (r) => [...r.querySelectorAll("input[type=text]")];
type = (i, v) => { i.value = v; i.dispatchEvent(new Event("input", { bubbles: true })); };
statusEl = () => document.getElementById("status");
addTo = (group) => document.querySelector(`button.group-add-btn[title='Add a "${group}" hotkey']`).click();
blankRow = () => [...document.querySelectorAll(".binding")].find(r => inputs(r).every(i => !i.value));

'@
    function Page([string]$script) { Invoke-Js ($js + $script) }
    function Wait-Status([string]$pattern, [int]$seconds = 15) { Wait-Until { (Page 'statusEl().textContent') -match $pattern } $seconds }
    function Save-Page { Page 'document.getElementById("save").click(); true' | Out-Null }

    # A new Edge profile: the page has never been given a token, and needs none.
    Check (Wait-Status "^Loaded \d+ hotkey") "the Hotkeys page loads with no token" (Page 'statusEl().textContent')
    Check ((Page '!document.getElementById("token") && !document.querySelector("input[placeholder*=token]")') -eq $true) "  ...and has no token box"
    Check ((Page 'fetch([...document.querySelectorAll("link[rel=icon]")].find(l => l.sizes.value === "48x48").href).then(r => r.status + " " + r.headers.get("content-type"))') -eq "200 image/png") `
        "  ...with the extension's icon as its favicon"
    $apiCount = @((Invoke-Api GET "/hotkeys-config").Json.bindings | Where-Object { $_ }).Count
    Check ((Page 'document.querySelectorAll(".binding").length') -eq $apiCount) "  ...showing every hotkey in app-hotkeys.ahk" "page $(Page 'document.querySelectorAll(".binding").length'), API $apiCount"

    Page 'type(inputs(row("Gmail"))[0], "Gmail (renamed on the page)"); true' | Out-Null
    Save-Page
    Check (Wait-Status "^Saved \d+ hotkey") "editing a title and clicking Save saves" (Page 'statusEl().textContent')
    Check ((Get-Content $AppHk -Raw) -match "; Gmail \(renamed on the page\)") "  ...into app-hotkeys.ahk"
    Check ((Page 'statusEl().className') -notmatch "err") "  ...reported as a success"

    Start-Sleep -Seconds 2
    Page 'row("Gmail (renamed on the page)").querySelector(".remove-btn").click(); true' | Out-Null
    Save-Page
    Wait-Status "^Saved" | Out-Null
    Check ((Get-Content $AppHk -Raw) -notmatch "Gmail \(renamed on the page\)") "removing a row (X) and saving deletes the line"

    Start-Sleep -Seconds 2
    Page 'addTo("Run command"); const r = blankRow(); const [t, k, cmd] = inputs(r); type(t, "Added on the page"); k.focus(); k.dispatchEvent(new KeyboardEvent("keydown", { key: "F2", ctrlKey: true, altKey: true, shiftKey: true, bubbles: true })); type(cmd, "notepad.exe"); k.value' | Out-Null
    Check ((Page 'inputs(row("Added on the page"))[1].value') -eq "Ctrl+Alt+Shift+F2") "the key recorder records Ctrl+Alt+Shift+F2" (Page 'inputs(row("Added on the page"))[1].value')
    Save-Page
    Wait-Status "^Saved" | Out-Null
    Check ((Get-Content $AppHk -Raw) -match '\^!\+F2:: Run\("notepad\.exe"\)\s+; Added on the page') "  ...and a new Run command row saves as a hotkey line" ((Get-Content $AppHk) -match "Added on the page" -join " | ")

    Start-Sleep -Seconds 2
    Page 'addTo("Run command"); type(inputs(blankRow())[0], "Half filled in"); true' | Out-Null
    Save-Page
    Check (Wait-Status "Removed 1 invalid hotkey") "saving an incomplete row reports it as dropped" (Page 'statusEl().textContent')
    Check ((Page 'statusEl().textContent') -match "Half filled in" -and (Page 'statusEl().className') -match "err") "  ...by name, as a warning" (Page 'statusEl().textContent')
    Check (-not (Page 'Boolean(row("Half filled in"))')) "  ...and the page reloads without it"

    Start-Sleep -Seconds 2
    Add-Content $AppHk '^!+F3:: FocusTab("Profile 1", [], "https://example.com")  ; Broken in the file'
    # The page has no Reload button (the browser's own refresh does the same); deferred so the
    # evaluation returns before the navigation tears the page's context down.
    Page 'setTimeout(() => location.reload(), 0); true' | Out-Null
    Check (Wait-Status "aren't valid any more") "an invalid hotkey in the file is flagged on load" (Page 'statusEl().textContent')
    Check ((Page 'statusEl().textContent') -match "Broken in the file") "  ...by name"
    Save-Page
    Wait-Status "^Saved" | Out-Null
    Check ((Get-Content $AppHk -Raw) -notmatch "Broken in the file") "  ...and the next save removes it"

    Start-Sleep -Seconds 2
    Add-Content $AppHk "; edited by hand while the page was open"
    Page 'type(inputs(row("Added on the page"))[0], "Renamed after a hand edit"); true' | Out-Null
    Save-Page
    Check (Wait-Status "^Not saved") "saving after the file was edited elsewhere is refused on the page" (Page 'statusEl().textContent')
    $text = Get-Content $AppHk -Raw
    Check ($text -match "edited by hand while the page was open" -and $text -notmatch "Renamed after a hand edit") "  ...leaving the hand edit intact"

    # The settings panel: hidden until the Settings button opens it; the startup manager switch.
    function Wait-SettingsStatus([string]$pattern) { Wait-Until { (Page 'document.getElementById("settingsStatus").textContent') -match $pattern } 60 }
    Check ((Page 'document.getElementById("settingsPanel").hidden') -eq $true) "the settings panel starts hidden"
    Page 'document.getElementById("settingsToggle").click(); true' | Out-Null
    Check (Wait-Until { (Page '(s => !document.getElementById("settingsPanel").hidden && !s.disabled && s.checked)(document.getElementById("startupManagerSwitch"))') -eq $true } 15) `
        "  ...Settings opens it, showing the startup manager on" (Page 'document.getElementById("settingsTitle").textContent + " / " + document.getElementById("startupManagerState").textContent')
    Check ((Page 'document.getElementById("settingsTitle").textContent') -eq "Settings — Windows") "  ...with the Windows settings"
    Page 'document.getElementById("startupManagerSwitch").click(); true' | Out-Null
    Check ((Wait-SettingsStatus "^Startup manager off") -and -not (Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue)) `
        "  ...switching it off removes its logon task" (Page 'document.getElementById("settingsStatus").textContent')
    Page 'document.getElementById("startupManagerSwitch").click(); true' | Out-Null
    Check ((Wait-SettingsStatus "^Startup manager on") -and (Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue)) `
        "  ...and on again registers it" (Page 'document.getElementById("settingsStatus").textContent')
    Disconnect-Cdp

    # ---- a new browser profile's extension connects by itself -------------------------------------
    # This Edge profile's extension has never been given a token. With pairing open (the tray
    # menu's "Connect browser extension", like the installer), it fetches it and starts reporting
    # tabs, under the profile name it hasn't been told yet: "Default".
    Invoke-Api POST "/extension-pairing" | Out-Null
    Check (Wait-Until { (Invoke-Api GET "/debugtabs").Json -match "=== Default ===" } 30) "an extension with no token, in a new Edge profile, connects by itself" ((Invoke-Api GET "/debugtabs").Json)

    # ---- the extension popup's "Hotkeys page" link ----------------------------------------------
    # This Edge loaded the extension too (--load-extension), so its popup page can be opened as a
    # tab and its link clicked.
    function Get-CdpTargets { $list = Invoke-RestMethod "http://127.0.0.1:$cdpPort/json" -TimeoutSec 5; $list }  # 5.1: see Connect-Cdp
    function Get-HotkeysTabs { @(Get-CdpTargets | Where-Object { $_.type -eq "page" -and $_.url -like "http://localhost:9876/hotkeys-ui*" }) }
    $extId = $null
    Wait-Until { ($script:extId = (Get-CdpTargets | Where-Object { $_.url -like "chrome-extension://*/background.js" } |
        Select-Object -First 1).url -replace '^chrome-extension://([^/]+)/.*', '$1') } 15 | Out-Null
    Check ([bool]$extId) "the extension runs in the test Edge"
    function Click-PopupLink {
        $popup = "chrome-extension://$extId/popup.html"
        Invoke-RestMethod -Method Put "http://127.0.0.1:$cdpPort/json/new?$popup" -TimeoutSec 5 | Out-Null
        Connect-Cdp $cdpPort "$popup*" 10
        Wait-Until { (Invoke-Js 'document.readyState') -eq "complete" } 10 | Out-Null
        Invoke-Js 'document.getElementById("hotkeys-page").click(); true' | Out-Null
        Disconnect-Cdp
    }
    Click-PopupLink
    Start-Sleep -Seconds 2
    $tabsNow = @(Get-HotkeysTabs)  # @(): in 5.1 a lone result comes back without .Count
    Check ($tabsNow.Count -eq 1) "the popup's Hotkeys page link switches to the open Hotkeys tab instead of opening another" "$($tabsNow.Count) Hotkeys tabs"
    if ($tabsNow.Count -ge 1) {
        Connect-Cdp $cdpPort "http://localhost:9876/hotkeys-ui*" 10
        Check ((Invoke-Js 'document.visibilityState') -eq "visible") "  ...and brings it to the front"
        Disconnect-Cdp
    }
    # Keep a blank tab: closing a window's last tab closes the browser.
    Invoke-RestMethod -Method Put "http://127.0.0.1:$cdpPort/json/new?about:blank" -TimeoutSec 5 | Out-Null
    foreach ($t in @(Get-HotkeysTabs)) { Invoke-RestMethod "http://127.0.0.1:$cdpPort/json/close/$($t.id)" -TimeoutSec 5 | Out-Null }
    Start-Sleep -Seconds 1
    Click-PopupLink
    Check (Wait-Until { @(Get-HotkeysTabs).Count -eq 1 } 10) "with no Hotkeys tab open, the link opens one" "$(@(Get-HotkeysTabs).Count) Hotkeys tabs"

    # ---- folder hotkeys don't open duplicate Explorer windows --------------------------------
    $folder = Join-Path $Work "folder-under-test"
    New-Item $folder -ItemType Directory -Force | Out-Null
    $mashOut = Join-Path $Work "explorer-mash.txt"
    Start-OnDesktop $Ahk "`"$Here\explorer-mash.ahk`" `"$folder`" `"$mashOut`"" | Out-Null
    Wait-Until { (Get-Content $mashOut -Raw) -match "active_is_explorer" } 30 | Out-Null
    $mash = @{}; foreach ($l in (Get-Content $mashOut -ErrorAction SilentlyContinue)) { $k, $v = $l -split '=', 2; if ($v) { $mash[$k] = $v } }
    Check ($mash["after_mash"] -eq "1") "mashing a folder hotkey opens exactly one Explorer window" "got $($mash['after_mash'])"
    Check ($mash["after_second_press"] -eq "1") "  ...and a later press focuses it instead of opening another" "got $($mash['after_second_press'])"

    # ---- startup manager ----------------------------------------------------------------------
    # A run like the one at logon (--run: same thing, recorded as manual), with AltTabSucks.ahk
    # stopped so it's started again, then Notepad, then Charmap 1 s after Notepad's window shows.
    # The VM's own startup apps (Edge, OneDrive...) were taken over too; they stay off here.
    $sm = Get-Content $SmConfig -Raw | ConvertFrom-Json -AsHashtable
    foreach ($i in $sm.items) {
        $i.enabled = $i.builtin -eq "alttabsucks" -or $i.name -like "E2E *"
        if ($i.name -eq "E2E Notepad") { $i.delay = 0 }
        if ($i.name -eq "E2E Charmap") { $i.delay = 1; $i.afterReady = $true }
    }
    $sm.autoCloseSeconds = 3
    [IO.File]::WriteAllText($SmConfig, (ConvertTo-Json $sm -Depth 10))
    Stop-Process -Name notepad, charmap -ErrorAction SilentlyContinue
    if ($ats = Get-AltTabSucks) { Stop-Process -Id $ats.ProcessId -Force }
    Start-Sleep -Seconds 1
    $smStarted = Get-Date
    Start-OnDesktop $Ahk "`"$Repo\StartupManager.ahk`" --run" | Out-Null
    Check (Wait-Until { Test-Path $SmHistory } 60) "the startup manager launches the startup items and adds a row to startup-history.jsonl" (Get-Content $SmErrors -Raw -ErrorAction SilentlyContinue)
    $row = Get-Content $SmHistory -Tail 1 -ErrorAction SilentlyContinue | ConvertFrom-Json
    $it = @{}; foreach ($x in $row.items) { $it[$x.name] = $x }
    $n = $it["E2E Notepad"]; $c = $it["E2E Charmap"]
    Check ($it["AltTabSucks"].status -eq "ready" -and (Get-AltTabSucks)) "  ...AltTabSucks.ahk started again" ($row | ConvertTo-Json -Depth 5 -Compress)
    Check ((Get-ScheduledTaskInfo -TaskName "AltTabSucks AHK").LastRunTime -ge $smStarted.AddSeconds(-2)) "  ...through its elevated task"
    Check ($n.status -eq "ready" -and $n.processMs -ge $n.launchMs -and $n.readyMs -ge $n.processMs) "  ...Notepad's process and first window timed" ($n | ConvertTo-Json -Compress)
    Check ($c.status -eq "ready" -and $c.launchMs -ge $n.readyMs + 950) "  ...Charmap launched 1 s after Notepad was ready" ($c | ConvertTo-Json -Compress)
    Check ($row.trigger -eq "manual" -and $row.allReadyMs -ge $c.readyMs -and @($row.items | Where-Object { $_.status -eq "off" }).Count -eq $row.items.Count - 3) "  ...the row has the run's totals, the other items off"
    Check (Wait-Until { -not (Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" | Where-Object { $_.CommandLine -like "*StartupManager.ahk*" }) } 20) "  ...and the manager closes itself once everything is ready"
    Check (-not (Test-Path $SmErrors)) "  ...without errors" (Get-Content $SmErrors -Raw -ErrorAction SilentlyContinue)
    Stop-Process -Name notepad, charmap -ErrorAction SilentlyContinue

    # A slow item: Notepad shows up 8 s after its launch, with a 2 s timeout. The run finishes at
    # the timeout (the history row says so), but the window waits for Notepad, then closes itself.
    function Get-StartupManager { Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" | Where-Object { $_.CommandLine -like "*StartupManager.ahk*" } }
    $smSaved = Get-Content $SmConfig -Raw
    $sm = $smSaved | ConvertFrom-Json -AsHashtable
    foreach ($i in $sm.items) { $i.enabled = $false }
    $sm.items += @{ name = "E2E Slow Notepad"; command = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Sleep 8; Start-Process notepad.exe"'
                    workingDir = ""; process = "notepad.exe"; delay = 0; afterReady = 0; ready = "window"; enabled = 1 }
    $sm.readyTimeoutSeconds = 2; $sm.autoCloseSeconds = 2
    [IO.File]::WriteAllText($SmConfig, (ConvertTo-Json $sm -Depth 10))
    $runs = @(Get-Content $SmHistory).Count
    Start-OnDesktop $Ahk "`"$Repo\StartupManager.ahk`" --run" | Out-Null
    Check (Wait-Until { @(Get-Content $SmHistory).Count -gt $runs } 20) "a slow item times out, and the run is recorded"
    $slow = (Get-Content $SmHistory -Tail 1 | ConvertFrom-Json).items | Where-Object name -eq "E2E Slow Notepad"
    Check ($slow.status -eq "noprocess") "  ...as not seen in time" ($slow | ConvertTo-Json -Compress)
    Start-Sleep -Seconds 3  # past the 2 s auto-close
    Check ((Get-StartupManager) -and -not (Get-Process notepad -ErrorAction SilentlyContinue)) "  ...but the window stays open while it's missing"
    Check ((Wait-Until { Get-Process notepad -ErrorAction SilentlyContinue } 15) -and (Wait-Until { -not (Get-StartupManager) } 15)) `
        "  ...and closes itself once it shows up"
    Stop-Process -Name notepad -ErrorAction SilentlyContinue

    # "Keep this window open after startup" (stayOpen): everything is up, and it stays anyway.
    $sm.items[-1].command = "notepad.exe"
    $sm.stayOpen = 1
    [IO.File]::WriteAllText($SmConfig, (ConvertTo-Json $sm -Depth 10))
    $runs = @(Get-Content $SmHistory).Count
    Start-OnDesktop $Ahk "`"$Repo\StartupManager.ahk`" --run" | Out-Null
    Check (Wait-Until { @(Get-Content $SmHistory).Count -gt $runs } 20) "with stayOpen set, the run finishes"
    Start-Sleep -Seconds 5
    Check ([bool](Get-StartupManager)) "  ...and the window stays open"
    Get-StartupManager | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Stop-Process -Name notepad -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($SmConfig, $smSaved)
    Check (-not (Test-Path $SmErrors)) "  ...without errors" (Get-Content $SmErrors -Raw -ErrorAction SilentlyContinue)

    # ---- switching the startup manager off and on again ----------------------------------------
    $off = Invoke-Api POST "/settings" @{ startupManager = $false }
    Check ($off.Status -eq 200 -and $off.Json.startupManager.enabled -eq $false -and -not (Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue)) `
        "switched off, the startup manager's logon task is gone" ($off.Json | ConvertTo-Json -Compress)
    Check ((Get-ScheduledTask -TaskName "AltTabSucks AHK").Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger") "  ...AltTabSucks.ahk's task starts it at logon again"
    Check ($null -eq (Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Notepad") "  ...and the Windows startup entries it took over are back on"
    $on = Invoke-Api POST "/settings" @{ startupManager = $true }
    Check ($on.Json.startupManager.enabled -eq $true -and (Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Notepad"[0] -eq 3) `
        "switched on again, it takes them over again (the earlier answer)" ($on.Json | ConvertTo-Json -Compress)

    Set-ItemProperty $RunKey "E2E Later" "notepad.exe"
    $scan = @(& $Pwsh -NoProfile -ExecutionPolicy Bypass -File "$Repo\installer.ps1" -Action startup-scan)
    Check (($scan -join "|") -eq "NEW`tE2E Later") "startup-scan finds a Windows startup entry added after install (for the manager's notice)" ($scan -join "|")

    # Saying no to the takeover: the entry stays on in Windows, and the choice is remembered.
    Invoke-OnDesktop "cmd.exe" "/c `"`"$Pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$Repo\installer.ps1`" -Action startup-on -TakeOverStartup No < nul > `"$Work\setup-no.log`" 2>&1`"" 60
    $sm = Get-Content $SmConfig -Raw | ConvertFrom-Json
    Check ($sm.takeOver -eq $false -and -not @($sm.items | Where-Object { $_.name -eq "E2E Later" })) "startup-on -TakeOverStartup No leaves new Windows startup apps out of the list" (Get-Content "$Work\setup-no.log" -Raw -ErrorAction SilentlyContinue)
    Check ($null -eq (Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Later") "  ...and on in Windows"

    # ---- uninstall ------------------------------------------------------------------------------
    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File "$Repo\installer.ps1" -Action uninstall | Out-Null
    Check (-not (Get-ScheduledTask -TaskName "AltTabSucks" -ErrorAction SilentlyContinue)) "uninstall removes the scheduled task"
    Check (-not (Get-ScheduledTask -TaskName "AltTabSucks Startup" -ErrorAction SilentlyContinue) -and -not (Get-ScheduledTask -TaskName "AltTabSucks AHK" -ErrorAction SilentlyContinue)) "  ...and the startup manager's"
    Check ($null -eq (Get-ItemProperty $ApprovedRun -ErrorAction SilentlyContinue)."E2E Notepad") "  ...and turns the Windows startup entries it took over back on"
    Check (Wait-Until { -not (Get-NetTCPConnection -LocalPort 9876 -State Listen -ErrorAction SilentlyContinue) } 10) "  ...and stops the server"
} finally {
    Remove-E2eTasks
    Write-Host "`n$script:Passed passed, $script:Failed failed"
}
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
