# HotkeysGenerator.ps1 - Windows counterpart of linux/server/hotkeys_generator.py.
# Turns the hotkeys.json shape that shared/hotkeys-ui.html edits into lib/hotkeys-ui.generated.ahk:
# one _UiHotkey(...) call per enabled binding (see lib/hotkeys-ui.ahk for why it's Hotkey() at
# runtime rather than static :: hotkeys). Same field names as the Linux side; on Windows
# "resourceClass" is a process name (code.exe) and "launchArgv" is what ManageAppWindows launches.
# Throws on an invalid binding so a broken .ahk file is never written.

$AllProfiles = "__all__"   # must match shared/hotkeys-ui.html's ALL_PROFILES

$AhkMods     = @{ Ctrl = '^'; Alt = '!'; Shift = '+'; Meta = '#' }
$AhkKeyNames = @{ Return = 'Enter'; Escape = 'Esc'; Delete = 'Del'; Insert = 'Ins'; PageUp = 'PgUp'; PageDown = 'PgDn' }
# The page records e.key, which is the *shifted* character when Shift is held (Shift+' -> ");
# AHK hotkeys name the physical (unshifted) key. US layout.
$Unshifted   = @{ '~' = '`'; '!' = '1'; '@' = '2'; '#' = '3'; '$' = '4'; '%' = '5'; '^' = '6'; '&' = '7'; '*' = '8'
                  '(' = '9'; ')' = '0'; '_' = '-'; '+' = '='; '{' = '['; '}' = ']'; '|' = '\'; ':' = ';'
                  '"' = "'"; '<' = ','; '>' = '.'; '?' = '/' }

function ConvertTo-AhkString([string]$s) {
    '"' + ($s -replace '`', '``' -replace '"', '`"' -replace "`r", '`r' -replace "`n", '`n') + '"'
}

function ConvertTo-AhkArray($values) {
    '[' + ((@($values) | ForEach-Object { ConvertTo-AhkString $_ }) -join ', ') + ']'
}

# "Ctrl+Alt+Shift+Y" (the page's recorder format) -> "^!+y"
function ConvertTo-AhkKey([string]$key) {
    $parts = if ($key.EndsWith('++')) { @($key.Substring(0, $key.Length - 2) -split '\+') + '+' } else { @($key -split '\+') }
    $base = $parts[-1]
    $mods = ''
    foreach ($m in ($parts | Select-Object -SkipLast 1 | Where-Object { $_ })) {
        if (-not $AhkMods.ContainsKey($m)) { throw "unknown modifier '$m' in key '$key'" }
        $mods += $AhkMods[$m]
    }
    if ($base.Length -eq 1) {
        if ($Unshifted.ContainsKey($base)) { $base = $Unshifted[$base] }
        $base = $base.ToLowerInvariant()
    } elseif ($AhkKeyNames.ContainsKey($base)) {
        $base = $AhkKeyNames[$base]
    }
    $mods + $base
}

function Join-CommandLine($argv) {
    (@($argv) | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
}

function ConvertTo-AhkBinding($b) {
    $title = "$($b.title)".Trim()
    $key   = "$($b.key)".Trim()
    if (-not $title) { throw "binding missing title" }
    if (-not $key)   { throw "binding '$title' missing key" }
    $prof = "$($b.profileName)".Trim()
    $needProfile = { if (-not $prof) { throw "binding '$title' missing profile" } }

    switch ($b.type) {
        { $_ -in 'windowCycle', 'windowToggle' } {
            $proc = "$($b.resourceClass)".Trim()
            if (-not $proc) { throw "binding '$title' missing process name" }
            if ($proc -notmatch '\.') { $proc += '.exe' }
            $mode = if ($b.type -eq 'windowCycle') { 'cycle' } else { 'toggle' }
            $argv = @($b.launchArgv | Where-Object { $_ })
            $launch = switch ($argv.Count) {
                0       { '""' }
                1       { ConvertTo-AhkString $argv[0] }
                default { "() => Run($(ConvertTo-AhkString (Join-CommandLine $argv)))" }
            }
            $call = "ManageAppWindows($(ConvertTo-AhkString $proc), $launch, `"$mode`")"
        }
        'profileCycle' {
            & $needProfile
            if ($prof -eq $AllProfiles) { throw "binding '$title': 'All profiles' isn't supported on Windows yet" }
            $call = "CycleChromiumProfile($(ConvertTo-AhkString $prof))"
        }
        'tabFocus' {
            & $needProfile
            $patterns = @($b.urlPatterns | Where-Object { $_ })
            if (-not $patterns) { throw "binding '$title' missing URL pattern(s)" }
            if (-not "$($b.openUrl)".Trim()) { throw "binding '$title' missing open URL" }
            $call = "FocusTab($(ConvertTo-AhkString $prof), $(ConvertTo-AhkArray $patterns), $(ConvertTo-AhkString "$($b.openUrl)".Trim()))"
        }
        'splitTab'  { $call = 'SplitFocusedTab()' }     # profile auto-detected from the focused window on Windows
        'mergeTabs' { $call = 'MergeFocusedWindow()' }
        'runCommand' {
            $argv = @($b.argv | Where-Object { $_ })
            if (-not $argv) { throw "binding '$title' missing command" }
            $call = "Run($(ConvertTo-AhkString (Join-CommandLine $argv)))"
        }
        default { throw "binding '$title' has unknown type '$($b.type)'" }
    }
    # split/merge act on the focused browser window, so they're only live while one is active
    $browserOnly = if ($b.type -in 'splitTab', 'mergeTabs') { ', true' } else { '' }
    [PSCustomObject]@{ Key = (ConvertTo-AhkKey $key); Line = "_UiHotkey($(ConvertTo-AhkString (ConvertTo-AhkKey $key)), $(ConvertTo-AhkString $title), (*) => $call$browserOnly)" }
}

function ConvertTo-AhkHotkeys($config) {
    $lines = @(
        "; Generated by the AltTabSucks hotkeys UI (http://localhost:9876/hotkeys-ui) from lib/hotkeys.json."
        "; Hand edits here are overwritten on the next save - put hand-written hotkeys in lib/app-hotkeys.ahk."
        ""
    )
    $seen = @{}
    foreach ($b in @($config.bindings | Where-Object { $_ -and $_.enabled -ne $false })) {
        $out = ConvertTo-AhkBinding $b
        if ($seen.ContainsKey($out.Key)) { throw "'$($b.title)' and '$($seen[$out.Key])' both use $($b.key)" }
        $seen[$out.Key] = $b.title
        $lines += $out.Line
    }
    ($lines -join "`r`n") + "`r`n"
}
