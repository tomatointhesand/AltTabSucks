# test-app-hotkeys.ps1 - tests for Server/AppHotkeys.ps1: lib/app-hotkeys.ahk as the Hotkeys UI's
# single source of truth. Read-AppHotkeys parses recognizable hotkey lines into the page's binding
# shape; Write-AppHotkeys rewrites only what changed and drops (and reports) invalid entries.
# Run with: bash dev-scripts/run-ps-tests.sh

. "$PSScriptRoot/assert.ps1"
. "$PSScriptRoot/../../Server/AppHotkeys.ps1"

function Lines([string[]]$l) { ($l -join "`n") + "`n" }
function Pick($b, [string[]]$fields) { $o = [ordered]@{}; foreach ($f in $fields) { $o[$f] = $b.$f }; $o }
function Find($r, [string]$key) { @($r.Bindings | Where-Object { $_.key -eq $key })[0] }

$env:ATS_TEST_HOME = 'C:\Users\me'

$sample = Lines @(
    '; app-hotkeys.ahk'
    'P1 := "Default"'
    'P2 := "Work"'
    ''
    '#HotIf !WinActive("ahk_exe Moonlight.exe")'
    '^!+y:: FocusTab(P1, ["youtube.com"], "https://youtube.com")  ; YouTube (main)'
    '^!+g:: FocusTab(P2, ["mail.google.com", "inbox.google.com"], "https://mail.google.com")'
    '^!+e:: ManageAppWindows("code.exe", "C:\Program Files\VS Code\Code.exe", "cycle")'
    '^!+n:: ManageAppWindows("notepad++.exe", "", "toggle")'
    '^!+w:: ManageAppWindows("WindowsTerminal.exe", () => Run("wt.exe -w 0"), "cycle")'
    '^!+d:: ManageAppWindows("x.exe", EnvGet("ATS_TEST_HOME") "\x.exe")'
    '^!+i:: CycleChromiumProfile(P1)'
    '^+#i:: CycleChromiumProfile("__all__", "Work")'
    '^!+Down:: Run("explorer.exe shell:Downloads")  ; Downloads'
    '; [disabled] ^!+k:: FocusTab("Default", ["keep.google.com"], "https://keep.google.com")  ; Keep'
    ';^!+s:: FocusTab(P2, ["old.example.com"], "https://old.example.com")'
    '^!+t:: UnixTimestampToClipboard()'
    '^!+\:: {'
    '    Run("putty.exe")'
    '}'
    '^!+q:: FocusTab("Default", [], "")'
    '^!+v:: FocusTab(P1, someArray, "https://v.example.com")'
    '#HotIf'
    ''
    '#HotIf WinActive("ahk_class Chrome_WidgetWin_1") || WinActive("ahk_class MozillaWindowClass")'
    '!x:: SplitFocusedTab()'
    '^!+r:: FocusTab(P1, ["r.example.com"], "https://r.example.com")'
    '#HotIf'
    ''
    '#HotIf WinActive("Star Citizen")'
    '^!+m:: ManageAppWindows("sc.exe", "", "cycle")'
    '#HotIf'
    ''
    '!z:: MergeFocusedWindow()'
    ''
    'SomeFunc() {'
    '    return 1'
    '}'
)

# ---- Read-AppHotkeys: what gets recognized ----------------------------------------------------

$r = Read-AppHotkeys $sample
Assert-Equal @($r.Bindings | ForEach-Object key) @(
    'Ctrl+Alt+Shift+Y', 'Ctrl+Alt+Shift+G', 'Ctrl+Alt+Shift+E', 'Ctrl+Alt+Shift+N', 'Ctrl+Alt+Shift+W',
    'Ctrl+Alt+Shift+D', 'Ctrl+Alt+Shift+I', 'Ctrl+Shift+Meta+I', 'Ctrl+Alt+Shift+Down', 'Ctrl+Alt+Shift+K',
    'Alt+X', 'Alt+Z') `
    "recognizes exactly the single-line action hotkeys: not comments, custom functions, blocks, unparseable args, other #HotIf contexts, or non-split/merge lines in a browser block"

$b = Find $r 'Ctrl+Alt+Shift+Y'
Assert-Equal (Pick $b 'type','title','profileName','urlPatterns','openUrl','enabled') ([ordered]@{
    type = 'tabFocus'; title = 'YouTube (main)'; profileName = 'Default'; urlPatterns = @('youtube.com'); openUrl = 'https://youtube.com'; enabled = $true }) `
    "FocusTab: profile variable resolved, title from the trailing comment (parentheses in it are fine)"
Assert-Equal $b.slot 5 "slot is the 0-based line index"
Assert-Equal $b.src '^!+y:: FocusTab(P1, ["youtube.com"], "https://youtube.com")  ; YouTube (main)' "src is the line's original text"

Assert-Equal (Find $r 'Ctrl+Alt+Shift+G').title 'mail.google.com' "no trailing comment: title derived from the first URL pattern"
Assert-Equal (Find $r 'Ctrl+Alt+Shift+G').urlPatterns @('mail.google.com', 'inbox.google.com') "multiple URL patterns"

Assert-Equal (Pick (Find $r 'Ctrl+Alt+Shift+E') 'type','title','resourceClass','launchArgv') ([ordered]@{
    type = 'windowCycle'; title = 'code'; resourceClass = 'code.exe'; launchArgv = @('C:\Program Files\VS Code\Code.exe') }) `
    "ManageAppWindows cycle with a launch path"
Assert-Equal (Pick (Find $r 'Ctrl+Alt+Shift+N') 'type','launchArgv') ([ordered]@{ type = 'windowToggle'; launchArgv = @() }) `
    "ManageAppWindows toggle with no launch command"
Assert-Equal (Find $r 'Ctrl+Alt+Shift+W').launchArgv @('wt.exe', '-w', '0') "() => Run(cmdline) launch split back into argv"
Assert-Equal (Pick (Find $r 'Ctrl+Alt+Shift+D') 'type','launchArgv') ([ordered]@{ type = 'windowCycle'; launchArgv = @('C:\Users\me\x.exe') }) `
    "EnvGet(...) concatenation resolved; mode defaults to cycle"

Assert-Equal (Pick (Find $r 'Ctrl+Alt+Shift+I') 'type','profileName','launchProfileName') ([ordered]@{
    type = 'profileCycle'; profileName = 'Default'; launchProfileName = 'Default' }) "CycleChromiumProfile(P1)"
Assert-Equal (Pick (Find $r 'Ctrl+Shift+Meta+I') 'profileName','launchProfileName') ([ordered]@{
    profileName = '__all__'; launchProfileName = 'Work' }) "CycleChromiumProfile all profiles"
Assert-Equal (Pick (Find $r 'Ctrl+Alt+Shift+Down') 'type','title','argv') ([ordered]@{
    type = 'runCommand'; title = 'Downloads'; argv = @('explorer.exe', 'shell:Downloads') }) "Run(cmdline) -> runCommand"
Assert-Equal (Pick (Find $r 'Ctrl+Alt+Shift+K') 'enabled','title') ([ordered]@{ enabled = $false; title = 'Keep' }) `
    "a '; [disabled] ' line is a disabled binding"
Assert-Equal (Find $r 'Alt+X').type 'splitTab' "split inside a browser #HotIf block"
Assert-Equal (Find $r 'Alt+Z').type 'mergeTabs' "merge at top level (the old hand-written style)"

Assert-Equal @($r.Invalid | ForEach-Object { Pick $_ 'line','text' }) @([ordered]@{ line = 21; text = '^!+q:: FocusTab("Default", [], "")' }) `
    "a fully parsed but invalid entry is reported (1-based line), not shown as a binding"
Assert-Equal ($r.Invalid[0].reason -match 'URL pattern') $true "  ...with the reason"

$crlf = $sample -replace "`n", "`r`n"
Assert-Equal @((Read-AppHotkeys $crlf).Bindings | ForEach-Object key) @($r.Bindings | ForEach-Object key) "CRLF files parse the same"
Assert-Equal (Find (Read-AppHotkeys $crlf) 'Ctrl+Alt+Shift+Y').src (Find $r 'Ctrl+Alt+Shift+Y').src "  ...and src never includes the CR"

# ---- Write-AppHotkeys: rewrite in place --------------------------------------------------------

function Copy-Bindings($r) { @($r.Bindings | ForEach-Object { $_.PSObject.Copy() }) }
function Without-Invalid([string]$text) { ($text -split "`n" | Where-Object { $_ -notmatch '^\^!\+q::' }) -join "`n" }

$w = Write-AppHotkeys $sample (Copy-Bindings $r)
Assert-Equal $w.Text (Without-Invalid $sample) "saving unchanged bindings changes nothing except removing the invalid entry"
Assert-Equal @($w.Dropped | ForEach-Object { Pick $_ 'title','key' }) @([ordered]@{ title = '^!+q:: FocusTab("Default", [], "")'; key = 'Ctrl+Alt+Shift+Q' }) `
    "  ...and that removal is reported (by its line text, since it has no title comment)"

$clean = Without-Invalid $sample
$rc = Read-AppHotkeys $clean
Assert-Equal (Write-AppHotkeys $clean (Copy-Bindings $rc)).Text $clean "a valid file round-trips byte for byte"
$cleanCrlf = $clean -replace "`n", "`r`n"
Assert-Equal (Write-AppHotkeys $cleanCrlf (Copy-Bindings (Read-AppHotkeys $cleanCrlf))).Text $cleanCrlf "  ...CRLF included"

$p = Copy-Bindings $rc; (Find @{ Bindings = $p } 'Ctrl+Alt+Shift+Y').title = 'YouTube'
$w = Write-AppHotkeys $clean $p
$changed = @(Compare-Object ($clean -split "`n") ($w.Text -split "`n") -SyncWindow 0 | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
Assert-Equal $changed @('^!+y:: FocusTab(P1, ["youtube.com"], "https://youtube.com")  ; YouTube') `
    "editing one binding rewrites only its line, keeping its profile variable (P1)"

$p = @(Copy-Bindings $rc | Where-Object { $_.key -ne 'Ctrl+Alt+Shift+G' })
$w = Write-AppHotkeys $clean $p
Assert-Equal ($w.Text -match 'mail\.google\.com') $false "a binding removed in the page is removed from the file"
Assert-Equal ((Read-AppHotkeys $w.Text).Bindings.Count) ($rc.Bindings.Count - 1) "  ...and nothing else is"

$p = Copy-Bindings $rc
$p += [PSCustomObject]@{ type = 'tabFocus'; title = 'Maps'; key = 'Ctrl+Alt+Shift+P'; enabled = $true
                         profileName = 'Default'; urlPatterns = @('google.com/maps'); openUrl = 'https://google.com/maps' }
$lines = (Write-AppHotkeys $clean $p).Text -split "`n"
$i = [array]::IndexOf($lines, '^!+p:: FocusTab("Default", ["google.com/maps"], "https://google.com/maps")  ; Maps')
Assert-Equal ($lines[$i - 1] -like '; `[disabled`] ^!+k::*') $true "a new binding goes right after the last binding of its group, disabled ones included (here inside the Moonlight block)"

$p = Copy-Bindings $rc; (Find @{ Bindings = $p } 'Ctrl+Alt+Shift+Y').enabled = $false
$w = Write-AppHotkeys $clean $p
Assert-Equal (($w.Text -split "`n")[5]) '; [disabled] ^!+y:: FocusTab(P1, ["youtube.com"], "https://youtube.com")  ; YouTube (main)' `
    "disabling a binding comments its line out with the marker"
Assert-Equal (Find (Read-AppHotkeys $w.Text) 'Ctrl+Alt+Shift+Y').enabled $false "  ...and it reads back disabled"

$p = Copy-Bindings $rc
$a = [array]::IndexOf(@($p | ForEach-Object key), 'Ctrl+Alt+Shift+Y'); $bb = [array]::IndexOf(@($p | ForEach-Object key), 'Ctrl+Alt+Shift+G')
$p[$a], $p[$bb] = $p[$bb], $p[$a]
$lines = (Write-AppHotkeys $clean $p).Text -split "`n"
Assert-Equal @($lines[5].Substring(0, 5), $lines[6].Substring(0, 5)) @('^!+g:', '^!+y:') "reordering two bindings of the same group swaps their lines"

# ---- Write-AppHotkeys: drop and report ----------------------------------------------------------

$p = Copy-Bindings $rc; (Find @{ Bindings = $p } 'Ctrl+Alt+Shift+G').openUrl = ''
$w = Write-AppHotkeys $clean $p
Assert-Equal ($w.Text -match 'inbox\.google\.com') $false "an existing binding made invalid is dropped from the file"
Assert-Equal (@($w.Dropped | ForEach-Object key)) @('Ctrl+Alt+Shift+G') "  ...and reported"
Assert-Equal ($w.Dropped[0].reason -match 'open URL') $true "  ...with the reason"

$p = Copy-Bindings $rc
$p += [PSCustomObject]@{ type = 'noLongerAType'; title = 'Old'; key = 'Ctrl+Alt+Shift+O'; enabled = $true }
$w = Write-AppHotkeys $clean $p
Assert-Equal $w.Text $clean "a new binding of an unknown type isn't written"
Assert-Equal ($w.Dropped[0].reason -match 'unknown type') $true "  ...and is reported"

$p = Copy-Bindings $rc
$p += [PSCustomObject]@{ type = 'runCommand'; title = 'Dupe'; key = 'Ctrl+Alt+Shift+Y'; enabled = $true; argv = @('calc.exe') }
$w = Write-AppHotkeys $clean $p
Assert-Equal ($w.Text -match 'calc\.exe') $false "a binding reusing another binding's key is dropped"
Assert-Equal ($w.Dropped[0].reason -match 'YouTube') $true "  ...and the report names the binding it clashes with"

$p = Copy-Bindings $rc
$p += [PSCustomObject]@{ type = 'runCommand'; title = 'Clash'; key = 'Ctrl+Alt+Shift+T'; enabled = $true; argv = @('calc.exe') }
$w = Write-AppHotkeys $clean $p
Assert-Equal ($w.Text -match 'calc\.exe') $false "a binding reusing the key of a hand-written hotkey in the file is dropped (it would break the script load)"

$p = Copy-Bindings $rc
$p += [PSCustomObject]@{ type = 'runCommand'; title = 'Disabled dupe'; key = 'Ctrl+Alt+Shift+Y'; enabled = $false; argv = @('calc.exe') }
$w = Write-AppHotkeys $clean $p
Assert-Equal ($w.Text -match 'calc\.exe') $true "a disabled binding may share a key (it never registers)"

$p = Copy-Bindings $rc
$stale = $clean.Replace('"https://youtube.com")', '"https://www.youtube.com")')
$threw = $null; try { Write-AppHotkeys $stale $p | Out-Null } catch { $threw = $_.Exception.Message }
Assert-Equal ($threw -match 'changed') $true "refuses to save if the file changed since the page loaded it"

# ---- new split/merge and empty files ------------------------------------------------------------

$plain = Lines @('P1 := "Default"', '^!+t:: UnixTimestampToClipboard()', '')
$new = @(
    [PSCustomObject]@{ type = 'splitTab'; title = 'Split'; key = 'Alt+X'; enabled = $true }
    [PSCustomObject]@{ type = 'tabFocus'; title = 'YT'; key = 'Ctrl+Alt+Shift+Y'; enabled = $true; profileName = 'Default'; urlPatterns = @('youtube.com'); openUrl = 'https://youtube.com' }
)
$w = Write-AppHotkeys $plain $new
$r2 = Read-AppHotkeys $w.Text
Assert-Equal @($r2.Bindings | ForEach-Object type) @('tabFocus', 'splitTab') "new bindings in a file with none are appended, and read back"
Assert-Equal ($w.Text -match '(?m)^#HotIf WinActive\("ahk_class Chrome_WidgetWin_1"\) \|\| WinActive\("ahk_class MozillaWindowClass"\)\r?\n!x:: SplitFocusedTab\(\)') $true `
    "a new split/merge with no existing one gets its own browser-only #HotIf block"
Assert-Equal $w.Text.StartsWith($plain.TrimEnd("`n")) $true "  ...without touching the existing lines"

# ---- one-time fold-in of a legacy lib/hotkeys.json -----------------------------------------------

$legacy = Lines @(
    'P1 := "Default"'
    'UI_HOTKEYS_SUPPRESS_WHEN := "ahk_exe Moonlight.exe"'
    '#HotIf !WinActive("ahk_exe Moonlight.exe")'
    '; [migrated to Hotkeys UI] ^!+y:: FocusTab(P1, ["youtube.com"], "https://youtube.com")'
    '^!+t:: UnixTimestampToClipboard()'
    '#HotIf'
)
$json = @(
    [PSCustomObject]@{ type = 'tabFocus'; title = 'YouTube'; key = 'Ctrl+Alt+Shift+Y'; profileName = 'Default'; urlPatterns = @('youtube.com'); openUrl = 'https://youtube.com' }
    [PSCustomObject]@{ type = 'mergeTabs'; title = 'Merge'; key = 'Alt+Z' }
    [PSCustomObject]@{ type = 'gone'; title = 'Gone'; key = 'Ctrl+Alt+Shift+Q' }
)
$f = Merge-LegacyHotkeysJson $legacy $json
$fl = $f.Text -split "`n"
Assert-Equal ($f.Text -match 'migrated to Hotkeys UI') $false "fold-in removes the '[migrated to Hotkeys UI]' lines"
Assert-Equal ($f.Text -match 'UI_HOTKEYS_SUPPRESS_WHEN') $false "  ...and the UI_HOTKEYS_SUPPRESS_WHEN line, which nothing reads any more"
Assert-Equal $fl[2] '^!+y:: FocusTab("Default", ["youtube.com"], "https://youtube.com")  ; YouTube' `
    "  ...and puts the hotkeys.json bindings where they were (inside the Moonlight block)"
Assert-Equal ($f.Text -match '(?m)^#HotIf !WinActive\("ahk_exe Moonlight\.exe"\) && \(WinActive\("ahk_class Chrome_WidgetWin_1"\) \|\| WinActive\("ahk_class MozillaWindowClass"\)\)\r?\n!z:: MergeFocusedWindow\(\)') $true `
    "  ...split/merge into a browser-only block that keeps the suppression"
Assert-Equal @(Read-AppHotkeys $f.Text | ForEach-Object { $_.Bindings } | ForEach-Object type) @('tabFocus', 'mergeTabs') "  ...and the result reads back"
Assert-Equal @($f.Dropped | ForEach-Object key) @('Ctrl+Alt+Shift+Q') "  ...reporting invalid ones instead of writing them"

# ---- starter set ---------------------------------------------------------------------------------

$tpl = '{ "bindings": [ { "type": "tabFocus", "title": "Gmail", "key": "Ctrl+Alt+Shift+G", "profileName": "__PROFILE__", "urlPatterns": ["mail.google.com"], "openUrl": "https://mail.google.com" } ] }'
$s = Add-StarterHotkeys $plain $tpl 'Default'
Assert-Equal $s.Count 1 "the starter set is added to a file with no bindings"
Assert-Equal (Find (Read-AppHotkeys $s.Text) 'Ctrl+Alt+Shift+G').profileName 'Default' "  ...with __PROFILE__ filled in"
Assert-Equal (Add-StarterHotkeys $s.Text $tpl 'Default').Count 0 "  ...and only once (a marker remembers it, even if every binding is later deleted)"
Assert-Equal (Add-StarterHotkeys $clean $tpl 'Default').Count 0 "a file that already has bindings gets no starter set"

Complete-Asserts
