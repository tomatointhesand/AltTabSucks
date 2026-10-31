# AppHotkeys.ps1 - lib/app-hotkeys.ahk as the Hotkeys UI's single source of truth.
#
# Read-AppHotkeys parses every recognizable hotkey line into the binding shape shared/hotkeys-ui.html
# edits; Write-AppHotkeys puts the page's edits back into the same file. Nothing else in the file
# (variables, functions, blocks, comments, hand-written hotkeys this doesn't recognize) is touched,
# and a binding the page didn't change keeps its original text byte for byte.
#
# Recognized: a single-line hotkey calling one of the actions below, with arguments that are plain
# literals (strings, arrays of strings), P1-style profile variables, EnvGet("X") "\path"
# concatenations, or () => Run(...) / () => LaunchStoreApp(...) launchers:
#   FocusTab / FocusTabFirefox              -> tabFocus
#   CycleChromiumProfile / CycleFirefoxProfile -> profileCycle
#   ManageAppWindows                         -> windowCycle / windowToggle
#   SplitFocusedTab / MergeFocusedWindow     -> splitTab / mergeTabs
#   ShowTabSearch                            -> tabSearch (lib/tab-search.ahk)
#   FocusOrOpenFolder                        -> folder (lib/explorer.ahk)
#   Run(single command)                      -> runCommand
# under no #HotIf, a #HotIf !WinActive(...) suppression block, or (split/merge only) a browser
# #HotIf block. "^!+k:: ... ; Title" - the trailing comment is the binding's title.
# "; [disabled] <hotkey line>" is a disabled binding.
#
# Invalid entries are dropped, not fatal: a recognized line that fails validation is reported by
# Read-AppHotkeys (.Invalid) and removed by the next save; a posted binding that fails validation or
# reuses a key is left out and reported (.Dropped). Tests: tests/ps/test-app-hotkeys.ps1.

$AllProfiles     = "__all__"   # must match shared/hotkeys-ui.html's ALL_PROFILES
$DisabledMarker  = "; [disabled] "
# Remembers which starter hotkeys (lib/hotkeys.template.json, by id) this file has been offered.
$StarterMarker   = "; [Hotkeys UI] starter hotkeys: "
$StarterSuffix   = " - edit or delete them freely, they won't be re-added"
# What the marker said before starter hotkeys had ids: the whole set then, which had everything
# but these.
$LegacyStarterMarker = "; [Hotkeys UI] starter hotkeys added - edit or delete them freely, they won't be re-added"
$StarterIdsSinceLegacy = @('tabSearch')
$LegacyMigrated  = "; [migrated to Hotkeys UI] "
$BrowserCriteria = 'WinActive("ahk_class Chrome_WidgetWin_1") || WinActive("ahk_class MozillaWindowClass")'

$AhkMods     = @{ Ctrl = '^'; Alt = '!'; Shift = '+'; Meta = '#' }
$AhkKeyNames = @{ Return = 'Enter'; Escape = 'Esc'; Delete = 'Del'; Insert = 'Ins'; PageUp = 'PgUp'; PageDown = 'PgDn' }
$RecKeyNames = @{ Enter = 'Return'; Esc = 'Escape'; Del = 'Delete'; Ins = 'Insert'; PgUp = 'PageUp'; PgDn = 'PageDown' }
# The page records e.key, which is the *shifted* character when Shift is held (Shift+' -> ");
# AHK hotkeys name the physical (unshifted) key. US layout.
$Unshifted   = @{ '~' = '`'; '!' = '1'; '@' = '2'; '#' = '3'; '$' = '4'; '%' = '5'; '^' = '6'; '&' = '7'; '*' = '8'
                  '(' = '9'; ')' = '0'; '_' = '-'; '+' = '='; '{' = '['; '}' = ']'; '|' = '\'; ':' = ';'
                  '"' = "'"; '<' = ','; '>' = '.'; '?' = '/' }

# ---- keys ---------------------------------------------------------------------------------------

# "Ctrl+Alt+Shift+Y" (the page's recorder format) -> "^!+y"
function ConvertTo-AhkKey([string]$key) {
    $parts = if ($key.EndsWith('++')) { @($key.Substring(0, $key.Length - 2) -split '\+') + '+' } else { @($key -split '\+') }
    $base = $parts[-1]
    $mods = ''
    foreach ($m in ($parts | Select-Object -SkipLast 1 | Where-Object { $_ })) {
        if (-not $AhkMods.ContainsKey($m)) { throw "unknown modifier '$m' in key '$key'" }
        $mods += $AhkMods[$m]
    }
    if (-not $base) { throw "key '$key' has no base key" }
    if ($base.Length -eq 1) {
        if ($Unshifted.ContainsKey($base)) { $base = $Unshifted[$base] }
        $base = $base.ToLowerInvariant()
    } elseif ($AhkKeyNames.ContainsKey($base)) {
        $base = $AhkKeyNames[$base]
    }
    $mods + $base
}

# "^!+m" -> "Ctrl+Alt+Shift+M"; $null for anything that isn't a plain modifier+key hotkey
function ConvertFrom-AhkKey([string]$hk) {
    if ($hk -notmatch '^([\^!+#]*)(.+)$') { return $null }
    $mods = $Matches[1]; $base = $Matches[2]
    if ($base -match '[\s&~*$<>]') { return $null }
    if ($base.Length -eq 1) { $base = $base.ToUpperInvariant() }
    elseif ($RecKeyNames.ContainsKey($base)) { $base = $RecKeyNames[$base] }
    $parts = @()
    if ($mods.Contains('^')) { $parts += 'Ctrl' }
    if ($mods.Contains('!')) { $parts += 'Alt' }
    if ($mods.Contains('+')) { $parts += 'Shift' }
    if ($mods.Contains('#')) { $parts += 'Meta' }
    ($parts + $base) -join '+'
}

# Comparable form of any hotkey in the file, prefixes (~ * $) included, or $null
function Get-KeyIdentity([string]$hk) {
    $rec = ConvertFrom-AhkKey ($hk -replace '^[~*$]+', '')
    if (-not $rec) { return $null }
    (ConvertTo-AhkKey $rec).ToLowerInvariant()
}

# ---- AHK literals -------------------------------------------------------------------------------

function ConvertTo-AhkString([string]$s) {
    '"' + ($s -replace '`', '``' -replace '"', '`"' -replace "`r", '`r' -replace "`n", '`n' -replace "`t", '`t') + '"'
}
function ConvertTo-AhkArray($values) {
    '[' + ((@($values) | ForEach-Object { ConvertTo-AhkString $_ }) -join ', ') + ']'
}
function Join-CommandLine($argv) {
    (@($argv) | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
}
function Split-CommandLine([string]$cmd) {
    @([regex]::Matches($cmd, '"([^"]*)"|(\S+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
}

# Splits on top-level commas, respecting "..."/'...' strings and ()/[] nesting. $null if unbalanced.
function Split-AhkArgs([string]$s) {
    $out = New-Object System.Collections.Generic.List[string]
    $depth = 0; $quote = $null; $start = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($quote) {
            if ($c -eq '`') { $i++ } elseif ($c -eq $quote) { $quote = $null }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c }
        elseif ($c -eq '(' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']') { $depth--; if ($depth -lt 0) { return $null } }
        elseif ($c -eq ',' -and $depth -eq 0) { $out.Add($s.Substring($start, $i - $start).Trim()); $start = $i + 1 }
    }
    if ($quote -or $depth -ne 0) { return $null }
    $last = $s.Substring($start).Trim()
    if ($out.Count -gt 0 -or $last) { $out.Add($last) }
    , $out.ToArray()
}

function ConvertFrom-AhkStringLiteral([string]$s) {
    if ($s -notmatch '^(["''])(.*)\1$') { return $null }
    $q = $Matches[1]; $body = $Matches[2]
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $body.Length; $i++) {
        $c = $body[$i]
        if ($c -eq '`' -and $i + 1 -lt $body.Length) {
            $i++
            switch -CaseSensitive ($body[$i]) { 'n' { [void]$sb.Append("`n") } 'r' { [void]$sb.Append("`r") } 't' { [void]$sb.Append("`t") } default { [void]$sb.Append($body[$i]) } }
        } elseif ($c -eq $q) {
            return $null   # an unescaped quote inside: really two literals, not one
        } else { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

# "literal" "literal" EnvGet("VAR") ... (implicit concatenation, optional dots) -> string, or $null
function Resolve-AhkStringExpr([string]$expr) {
    $expr = $expr.Trim()
    $tokens = [regex]::Matches($expr, 'EnvGet\("(\w+)"\)|"((?:[^"`]|`.)*)"')
    $leftover = ([regex]::Replace($expr, 'EnvGet\("\w+"\)|"(?:[^"`]|`.)*"', '')) -replace '[\s.]', ''
    if ($tokens.Count -eq 0 -or $leftover) { return $null }
    $out = ''
    foreach ($t in $tokens) {
        if ($t.Groups[1].Success) { $out += [Environment]::GetEnvironmentVariable($t.Groups[1].Value) }
        else { $out += ConvertFrom-AhkStringLiteral ('"' + $t.Groups[2].Value + '"') }
    }
    $out
}

# A ManageAppWindows launch argument -> argv array, or $null if not understood
function Resolve-LaunchArg([string]$expr) {
    $expr = $expr.Trim()
    if ($expr -match '^\(\)\s*=>\s*LaunchStoreApp\("([^"`]+)"\)$') {
        $id = $Matches[1]
        if ($id.Contains('!')) { return , @("shell:AppsFolder\$id") }
        return , @(Join-Path ([Environment]::GetEnvironmentVariable('LOCALAPPDATA')) "Microsoft\WindowsApps\$id")
    }
    if ($expr -match '^\(\)\s*=>\s*Run\((.*)\)$') {
        $cmd = Resolve-AhkStringExpr $Matches[1]
        if ($null -eq $cmd) { return $null }
        return , @(Split-CommandLine $cmd)
    }
    $s = Resolve-AhkStringExpr $expr
    if ($null -eq $s) { return $null }
    if ($s -eq '') { return , @() }
    , @($s)
}

# ---- one line -----------------------------------------------------------------------------------

# Splits a candidate hotkey line into its parts, or $null if it isn't "key:: Func(args)  ; comment"
function Split-HotkeyLine([string]$line) {
    $disabled = $false
    if ($line.StartsWith($DisabledMarker)) { $disabled = $true; $line = $line.Substring($DisabledMarker.Length) }
    $line = $line.Trim()
    if ($line -notmatch '^([^\s:;]+)::\s*(\w+)\(') { return $null }
    $hk = $Matches[1]; $fn = $Matches[2]
    $open = $Matches[0].Length
    $depth = 1; $quote = $null; $close = -1
    for ($i = $open; $i -lt $line.Length; $i++) {
        $c = $line[$i]
        if ($quote) { if ($c -eq '`') { $i++ } elseif ($c -eq $quote) { $quote = $null }; continue }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c }
        elseif ($c -eq '(' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']') { $depth--; if ($depth -eq 0) { $close = $i; break } }
    }
    if ($close -lt 0) { return $null }
    $rest = $line.Substring($close + 1)
    if ($rest -notmatch '^\s*(?:;\s?(.*))?$') { return $null }
    $argList = Split-AhkArgs $line.Substring($open, $close - $open)
    if ($null -eq $argList) { return $null }
    [PSCustomObject]@{ Hk = $hk; Fn = $fn; Args = $argList; Comment = "$($Matches[1])".Trim(); Disabled = $disabled }
}

function Get-DefaultTitle($b) {
    switch ($b.type) {
        'tabFocus'     { if (@($b.urlPatterns).Count) { return ($b.urlPatterns[0] -replace '^https?://', '') }; return '' }
        'profileCycle' { if ($b.profileName -eq $AllProfiles) { return 'Cycle all profiles' }; return "Cycle $($b.profileName)" }
        'splitTab'     { return 'Split tab' }
        'mergeTabs'    { return 'Merge windows' }
        'tabSearch'    { return 'Search tabs' }
        'folder'       { $p = "$($b.path)".TrimEnd('\', '/'); return $(if ($p) { ($p -split '[\\/]')[-1] } else { '' }) }
        'runCommand'   { if (@($b.argv).Count) { return [IO.Path]::GetFileNameWithoutExtension(($b.argv[0] -split '[\\/]')[-1]) }; return '' }
        default        { return [IO.Path]::GetFileNameWithoutExtension("$($b.resourceClass)") }
    }
}

# Parts from Split-HotkeyLine -> binding (unvalidated), or $null if the call isn't an understood action
function ConvertFrom-HotkeyParts($parts, $profileVars) {
    $key = ConvertFrom-AhkKey $parts.Hk
    if (-not $key) { return $null }
    $a = @($parts.Args)
    $resolveProfile = {
        param($tok)
        $v = ConvertFrom-AhkStringLiteral $tok
        if ($null -ne $v) { return $v }
        if ($tok -match '^\w+$' -and $profileVars.ContainsKey($tok)) { return $profileVars[$tok] }
        $null
    }
    $b = $null
    switch -Regex ($parts.Fn) {
        '^(FocusTab|FocusTabFirefox)$' {
            if ($a.Count -ne 3) { return $null }
            $prof = & $resolveProfile $a[0]
            $pats = if ($a[1] -match '^\[(.*)\]$') {
                $items = Split-AhkArgs $Matches[1]
                if ($null -eq $items) { return $null }
                $vals = @(); foreach ($it in $items) { $v = ConvertFrom-AhkStringLiteral $it; if ($null -eq $v) { return $null }; $vals += $v }
                , $vals
            } else { $v = ConvertFrom-AhkStringLiteral $a[1]; if ($null -eq $v) { return $null }; , @($v) }
            $url = ConvertFrom-AhkStringLiteral $a[2]
            if ($null -eq $prof -or $null -eq $url) { return $null }
            $b = [ordered]@{ type = 'tabFocus'; profileName = $prof; urlPatterns = @($pats); openUrl = $url }
        }
        '^(CycleChromiumProfile|CycleFirefoxProfile)$' {
            if ($a.Count -lt 1 -or $a.Count -gt 2) { return $null }
            $prof = & $resolveProfile $a[0]
            if ($null -eq $prof) { return $null }
            $launch = if ($a.Count -eq 2) { & $resolveProfile $a[1] } else { $prof }
            if ($null -eq $launch) { return $null }
            $b = [ordered]@{ type = 'profileCycle'; profileName = $prof; launchProfileName = $launch }
        }
        '^ManageAppWindows$' {
            if ($a.Count -lt 1 -or $a.Count -gt 3) { return $null }
            $proc = ConvertFrom-AhkStringLiteral $a[0]
            $argv = if ($a.Count -ge 2) { Resolve-LaunchArg $a[1] } else { , @() }
            $mode = if ($a.Count -eq 3) { ConvertFrom-AhkStringLiteral $a[2] } else { 'cycle' }
            if ($null -eq $proc -or $null -eq $argv -or $mode -notin 'cycle', 'toggle') { return $null }
            $b = [ordered]@{ type = $(if ($mode -eq 'toggle') { 'windowToggle' } else { 'windowCycle' }); resourceClass = $proc; launchArgv = @($argv) }
        }
        '^SplitFocusedTab$'    { if ($a.Count -ne 0) { return $null }; $b = [ordered]@{ type = 'splitTab' } }
        '^MergeFocusedWindow$' { if ($a.Count -ne 0) { return $null }; $b = [ordered]@{ type = 'mergeTabs' } }
        '^ShowTabSearch$'      { if ($a.Count -ne 0) { return $null }; $b = [ordered]@{ type = 'tabSearch' } }
        '^FocusOrOpenFolder$' {
            if ($a.Count -ne 1) { return $null }
            $path = Resolve-AhkStringExpr $a[0]
            if ($null -eq $path) { return $null }
            $b = [ordered]@{ type = 'folder'; path = $path }
        }
        '^Run$' {
            if ($a.Count -ne 1) { return $null }   # Run's extra options (working dir, "Hide") don't round-trip
            $cmd = Resolve-AhkStringExpr $a[0]
            if (-not $cmd) { return $null }
            $b = [ordered]@{ type = 'runCommand'; argv = @(Split-CommandLine $cmd) }
        }
        default { return $null }
    }
    $o = [ordered]@{ type = $b.type; title = ''; key = $key; enabled = -not $parts.Disabled }
    foreach ($k in $b.Keys) { if ($k -ne 'type') { $o[$k] = $b[$k] } }
    $o.title = if ($parts.Comment) { $parts.Comment } else { Get-DefaultTitle ([PSCustomObject]$o) }
    [PSCustomObject]$o
}

# Validated binding -> the call text, throwing with a readable reason if it's invalid.
# $profileExpr (optional) replaces the profile string literal, to keep a P1-style variable.
function ConvertTo-AhkCall($b, [string]$profileExpr) {
    $title = "$($b.title)".Trim()
    $prof = "$($b.profileName)".Trim()
    $profLit = if ($profileExpr) { $profileExpr } else { ConvertTo-AhkString $prof }
    $needProfile = { if (-not $prof) { throw "missing profile" } }
    switch ($b.type) {
        { $_ -in 'windowCycle', 'windowToggle' } {
            $proc = "$($b.resourceClass)".Trim()
            if (-not $proc) { throw "missing process name" }
            if ($proc -notmatch '\.') { $proc += '.exe' }
            $mode = if ($b.type -eq 'windowCycle') { 'cycle' } else { 'toggle' }
            $argv = @($b.launchArgv | Where-Object { $_ })
            $launch = switch ($argv.Count) {
                0       { '""' }
                1       { ConvertTo-AhkString $argv[0] }
                default { "() => Run($(ConvertTo-AhkString (Join-CommandLine $argv)))" }
            }
            return "ManageAppWindows($(ConvertTo-AhkString $proc), $launch, `"$mode`")"
        }
        'profileCycle' {
            & $needProfile
            if ($prof -eq $AllProfiles) {
                $launch = "$($b.launchProfileName)".Trim()
                if (-not $launch) { throw "cycles all profiles but has no launch profile set" }
                return "CycleChromiumProfile(`"$AllProfiles`", $(ConvertTo-AhkString $launch))"
            }
            return "CycleChromiumProfile($profLit)"
        }
        'tabFocus' {
            & $needProfile
            $patterns = @($b.urlPatterns | Where-Object { $_ })
            if (-not $patterns) { throw "missing URL pattern(s)" }
            if (-not "$($b.openUrl)".Trim()) { throw "missing open URL" }
            return "FocusTab($profLit, $(ConvertTo-AhkArray $patterns), $(ConvertTo-AhkString "$($b.openUrl)".Trim()))"
        }
        'splitTab'  { return 'SplitFocusedTab()' }
        'mergeTabs' { return 'MergeFocusedWindow()' }
        'tabSearch' { return 'ShowTabSearch()' }
        'folder' {
            $path = "$($b.path)".Trim()
            if (-not $path) { throw "missing folder" }
            return "FocusOrOpenFolder($(ConvertTo-AhkString $path))"
        }
        'runCommand' {
            $argv = @($b.argv | Where-Object { $_ })
            if (-not $argv) { throw "missing command" }
            return "Run($(ConvertTo-AhkString (Join-CommandLine $argv)))"
        }
        default { throw "unknown type '$($b.type)'" }
    }
}

# Validated binding -> its full line ("^!+y:: FocusTab(...)  ; Title"). Throws if invalid.
function ConvertTo-AhkHotkeyLine($b, [string]$profileExpr) {
    $title = "$($b.title)".Trim() -replace '[\r\n]+', ' '
    $key = "$($b.key)".Trim()
    # The action first: a title derived from an empty field would otherwise mask the real problem.
    $call = ConvertTo-AhkCall $b $profileExpr
    if (-not $key)   { throw "missing key" }
    if (-not $title) { throw "missing title" }
    $line = "$(ConvertTo-AhkKey $key):: $call  ; $title"
    if ($b.enabled -eq $false) { $line = $DisabledMarker + $line }
    $line
}

# ---- whole file ---------------------------------------------------------------------------------

function Get-ProfileVars([string[]]$lines) {
    $vars = @{}
    foreach ($l in $lines) { if ($l -match '^\s*(\w+)\s*:=\s*"([^"`]*)"') { $vars[$Matches[1]] = $Matches[2] } }
    $vars
}

function Get-Group($type) { if ($type -in 'windowCycle', 'windowToggle') { 'app' } else { $type } }

# Line-by-line scan: each line's #HotIf criteria, recognized bindings, invalid entries, and the
# keys of every other (hand-written) hotkey, for duplicate checks.
function Get-FileModel([string]$text) {
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $profileVars = Get-ProfileVars $lines
    $ctxOf = New-Object string[] $lines.Count
    $bindings = @(); $invalid = @(); $custom = @()
    $ctx = ''; $inComment = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($inComment) { if ($t.Contains('*/')) { $inComment = $false }; $ctxOf[$i] = $ctx; continue }
        if ($t.StartsWith('/*')) { $inComment = -not $t.Contains('*/'); $ctxOf[$i] = $ctx; continue }
        if ($t -match '^#HotIf\b\s*(.*)$') { $ctx = ($Matches[1] -replace '\s;.*$', '').Trim() }
        $ctxOf[$i] = $ctx
        $parts = Split-HotkeyLine $lines[$i]
        $ctxKind = if (-not $ctx) { 'global' } elseif ($ctx -match 'Chrome_WidgetWin_1|MozillaWindowClass') { 'browser' } elseif ($ctx -match '^!WinActive\(.+\)$') { 'global' } else { 'other' }
        $b = if ($parts -and $ctxKind -ne 'other') { ConvertFrom-HotkeyParts $parts $profileVars } else { $null }
        if ($b -and $ctxKind -eq 'browser' -and $b.type -notin 'splitTab', 'mergeTabs') { $b = $null }
        if ($b) {
            try {
                ConvertTo-AhkHotkeyLine $b | Out-Null
                $b | Add-Member slot $i
                $b | Add-Member src $lines[$i]
                $bindings += $b
            } catch {
                $invalid += [PSCustomObject]@{ line = $i + 1; text = $lines[$i]; reason = $_.Exception.Message; key = $b.key
                                               title = $(if ($parts.Comment) { $parts.Comment } else { $lines[$i] }) }
            }
        } elseif (-not $t.StartsWith(';') -and $t -match '^([^\s:;]+)::') {
            $id = Get-KeyIdentity $Matches[1]
            if ($id) { $custom += [PSCustomObject]@{ Id = $id; Ctx = $ctx; Text = $t } }
        }
    }
    [PSCustomObject]@{ Lines = $lines; Eol = $eol; Ctx = $ctxOf; Bindings = $bindings; Invalid = $invalid; Custom = $custom; ProfileVars = $profileVars }
}

function Read-AppHotkeys([string]$text) {
    $m = Get-FileModel $text
    [PSCustomObject]@{ Bindings = @($m.Bindings); Invalid = @($m.Invalid) }
}

# Core rewrite. $newAnchor (line index, optional) forces where new non-split/merge bindings go;
# $browserCriteria is the #HotIf criteria for a new browser-only block.
# -KeepInvalid leaves invalid entries in place (and unreported) instead of removing them.
function Invoke-AppHotkeysRewrite([string]$text, $posted, $newAnchor = $null, [string]$browserCriteria = $BrowserCriteria, [switch]$KeepInvalid) {
    $m = Get-FileModel $text
    $lines = $m.Lines
    $slotBinding = @{}; foreach ($b in $m.Bindings) { $slotBinding[$b.slot] = $b }
    $dropped = New-Object System.Collections.ArrayList
    $report = { param($b, $reason) [void]$dropped.Add([PSCustomObject]@{ title = "$($b.title)"; key = "$($b.key)"; reason = $reason }) }

    # 1. Validate; work out each binding's line text.
    $items = @()
    foreach ($b in @($posted | Where-Object { $_ })) {
        $slot = if ($null -ne $b.PSObject.Properties['slot'] -and $null -ne $b.slot -and "$($b.slot)" -ne '') { [int]$b.slot } else { $null }
        if ($null -ne $slot -and (-not $slotBinding.ContainsKey($slot) -or $slotBinding[$slot].src -cne "$($b.src)")) {
            throw "app-hotkeys.ahk changed since the page loaded it - reload the page and redo your change"
        }
        try {
            $text1 = if ($null -ne $slot) {
                $orig = $slotBinding[$slot]
                $profTok = $null
                $op = Split-HotkeyLine $orig.src
                if ($op -and $op.Args.Count -ge 1 -and $op.Args[0] -match '^\w+$' -and $m.ProfileVars[$op.Args[0]] -eq "$($b.profileName)") { $profTok = $op.Args[0] }
                if ((ConvertTo-AhkHotkeyLine $b) -ceq (ConvertTo-AhkHotkeyLine $orig)) { $orig.src } else { ConvertTo-AhkHotkeyLine $b $profTok }
            } else { ConvertTo-AhkHotkeyLine $b }
            $items += [PSCustomObject]@{ B = $b; Slot = $slot; Text = $text1; Group = (Get-Group $b.type); Line = $null; Anchor = $null; Ctx = $null }
        } catch { & $report $b $_.Exception.Message }
    }

    # 2. Existing bindings keep their group's slots, in the order the page posted them (reordering
    #    within a group moves bindings between that group's lines).
    foreach ($g in @($items | Where-Object { $null -ne $_.Slot } | ForEach-Object Group | Select-Object -Unique)) {
        $its = @($items | Where-Object { $null -ne $_.Slot -and $_.Group -eq $g })
        $slots = @($its | ForEach-Object Slot | Sort-Object)
        for ($k = 0; $k -lt $its.Count; $k++) { $its[$k].Line = $slots[$k]; $its[$k].Ctx = $m.Ctx[$slots[$k]] }
    }

    # 3. New bindings: after the last line of their group, else (split/merge) a new browser block
    #    at the end, else after the last binding outside a browser block, else at the end.
    $eofIndex = if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines.Count - 1 } else { $lines.Count }
    $endCtx = if ($lines.Count) { $m.Ctx[$lines.Count - 1] } else { '' }
    foreach ($it in @($items | Where-Object { $null -eq $_.Slot })) {
        $isBrowser = $it.Group -in 'splitTab', 'mergeTabs'
        $same = @($items | Where-Object { $null -ne $_.Line -and $_.Group -eq $it.Group } | ForEach-Object Line | Sort-Object)
        if ($same) { $it.Anchor = $same[-1] + 1; $it.Ctx = $m.Ctx[$same[-1]] }
        elseif ($isBrowser) { $it.Anchor = 'browser'; $it.Ctx = $browserCriteria }
        elseif ($null -ne $newAnchor) { $it.Anchor = [int]$newAnchor; $it.Ctx = $(if ($newAnchor -lt $lines.Count) { $m.Ctx[$newAnchor] } else { $endCtx }) }
        else {
            $other = @($items | Where-Object { $null -ne $_.Line -and $_.Group -notin 'splitTab', 'mergeTabs' } | ForEach-Object Line | Sort-Object)
            if ($other) { $it.Anchor = $other[-1] + 1; $it.Ctx = $m.Ctx[$other[-1]] }
            else { $it.Anchor = $eofIndex; $it.Ctx = $endCtx }
        }
    }

    # 4. Keys must be unique per #HotIf criteria, among enabled bindings and against hand-written
    #    hotkeys (a duplicate static hotkey would stop the whole script from loading). First wins.
    $taken = @{}
    foreach ($c in $m.Custom) { $taken["$($c.Ctx)|$($c.Id)"] = "a hand-written hotkey ($($c.Text))" }
    $kept = @()
    foreach ($it in $items) {
        if ($it.B.enabled -ne $false) {
            $id = "$($it.Ctx)|$((ConvertTo-AhkKey "$($it.B.key)").ToLowerInvariant())"
            if ($taken.ContainsKey($id)) { & $report $it.B "same key as $($taken[$id])"; continue }
            $taken[$id] = "'$($it.B.title)'"
        }
        $kept += $it
    }

    # 5. Assemble: assigned slots get their binding's text, unassigned slots and invalid entries
    #    are removed, new bindings are inserted before their anchor line.
    $byLine = @{}; foreach ($it in $kept) { if ($null -ne $it.Line) { $byLine[$it.Line] = $it.Text } }
    $remove = @{}; foreach ($b in $m.Bindings) { if (-not $byLine.ContainsKey($b.slot)) { $remove[$b.slot] = $true } }
    foreach ($inv in $(if ($KeepInvalid) { @() } else { $m.Invalid })) {
        $remove[$inv.line - 1] = $true
        [void]$dropped.Add([PSCustomObject]@{ title = $inv.title; key = $inv.key; reason = $inv.reason })
    }
    $insertAt = @{}
    foreach ($it in $kept) { if ($null -ne $it.Anchor -and $it.Anchor -ne 'browser') { if (-not $insertAt.ContainsKey($it.Anchor)) { $insertAt[$it.Anchor] = @() }; $insertAt[$it.Anchor] += $it.Text } }
    $browserNew = @($kept | Where-Object { $_.Anchor -eq 'browser' } | ForEach-Object Text)

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -le $lines.Count; $i++) {
        if ($i -eq $eofIndex -and $browserNew) {
            if ($insertAt.ContainsKey($i)) { foreach ($t in $insertAt[$i]) { $out.Add($t) }; $insertAt.Remove($i) }
            if ($out.Count -and $out[$out.Count - 1] -ne '') { $out.Add('') }
            $out.Add("#HotIf $browserCriteria"); foreach ($t in $browserNew) { $out.Add($t) }; $out.Add('#HotIf')
        }
        if ($insertAt.ContainsKey($i)) { foreach ($t in $insertAt[$i]) { $out.Add($t) } }
        if ($i -ge $lines.Count) { break }
        if ($byLine.ContainsKey($i)) { $out.Add($byLine[$i]) }
        elseif (-not $remove.ContainsKey($i)) { $out.Add($lines[$i]) }
    }
    [PSCustomObject]@{ Text = ($out -join $m.Eol); Saved = $kept.Count; Dropped = @($dropped) }
}

function Write-AppHotkeys([string]$text, $posted) { Invoke-AppHotkeysRewrite $text $posted }

# One-time fold-in of a lib/hotkeys.json from the earlier JSON-based Hotkeys UI: its bindings go
# back into app-hotkeys.ahk where the "[migrated to Hotkeys UI]" lines they came from were (those
# lines are removed - hotkeys.json holds their newer versions), else inside the
# UI_HOTKEYS_SUPPRESS_WHEN block, else at the end. Split/merge get a browser-only block that keeps
# the suppression. The UI_HOTKEYS_SUPPRESS_WHEN assignment itself is removed: only the old
# generated file read it.
function Merge-LegacyHotkeysJson([string]$text, $jsonBindings) {
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $suppress = $null
    foreach ($l in $lines) { if ($l -match '^\s*UI_HOTKEYS_SUPPRESS_WHEN\s*:=\s*"([^"`]+)"') { $suppress = $Matches[1] } }
    $kept = @(); $anchor = $null
    foreach ($l in $lines) {
        if ($l.TrimStart().StartsWith($LegacyMigrated)) { if ($null -eq $anchor) { $anchor = $kept.Count }; continue }
        if ($l -match '^\s*UI_HOTKEYS_SUPPRESS_WHEN\s*:=') { continue }
        $kept += $l
    }
    if ($null -eq $anchor -and $suppress) {
        $open = -1
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $t = $kept[$i].Trim()
            if ($open -lt 0 -and $t -match '^#HotIf\s+!WinActive\("([^"`]+)"\)' -and $Matches[1] -eq $suppress) { $open = $i }
            elseif ($open -ge 0 -and $t -match '^#HotIf\s*(;.*)?$') { $anchor = $i; break }
        }
    }
    $criteria = if ($suppress) { "!WinActive($(ConvertTo-AhkString $suppress)) && ($BrowserCriteria)" } else { $BrowserCriteria }
    $new = @($jsonBindings | Where-Object { $_ } | ForEach-Object {
        $o = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { if ($p.Name -notin 'slot', 'src') { $o[$p.Name] = $p.Value } }
        if (-not $o.Contains('enabled')) { $o['enabled'] = $true }
        [PSCustomObject]$o
    })
    $base = $kept -join $eol
    $existing = @((Get-FileModel $base).Bindings)
    $r = Invoke-AppHotkeysRewrite $base (@($existing) + @($new)) $anchor $criteria
    [PSCustomObject]@{ Text = $r.Text; Count = $r.Saved - $existing.Count; Dropped = $r.Dropped }
}

# What makes two bindings the same hotkey for the starter set, whatever their key and title: a
# file that already has one doesn't get the starter's.
function Get-StarterIdentity($b) {
    switch ($b.type) {
        'tabFocus'     { "tabFocus|$("$($b.openUrl)".Trim().ToLowerInvariant())" }
        'profileCycle' { "profileCycle|$($b.profileName)" }
        { $_ -in 'windowCycle', 'windowToggle' } { $p = "$($b.resourceClass)".Trim().ToLowerInvariant(); if ($p -notmatch '\.') { $p += '.exe' }; "app|$p" }
        'runCommand'   { "runCommand|$((Join-CommandLine @($b.argv)).ToLowerInvariant())" }
        'folder'       { "folder|$("$($b.path)".Trim().TrimEnd('\', '/').ToLowerInvariant())" }
        default        { "$($b.type)" }
    }
}

# The ids in the file's starter marker, $null if it has none.
function Get-StarterOffered([string[]]$lines, $templateIds) {
    foreach ($l in $lines) {
        if ($l.StartsWith($StarterMarker)) {
            $ids = $l.Substring($StarterMarker.Length)
            if ($ids.EndsWith($StarterSuffix)) { $ids = $ids.Substring(0, $ids.Length - $StarterSuffix.Length) }
            return , @($ids -split '\s+' | Where-Object { $_ })
        }
        if ($l -ceq $LegacyStarterMarker) { return , @($templateIds | Where-Object { $_ -notin $StarterIdsSinceLegacy }) }
    }
    $null
}

# The file with its starter marker listing $ids: the marker line replaced, or added at the end.
function Set-StarterMarker([string]$text, $ids) {
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $marker = $StarterMarker + (@($ids) -join ' ') + $StarterSuffix
    $lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($StarterMarker) -or $lines[$i] -ceq $LegacyStarterMarker) { $lines[$i] = $marker; return $lines -join $eol }
    }
    $text.TrimEnd("`r", "`n") + $eol + $eol + $marker + $eol
}

# The starter hotkeys (lib/hotkeys.template.json; "__PROFILE__" -> the browser's default profile,
# and any other $Values placeholders), each offered to a file once, remembered by its id in a
# marker line. A file with no bindings and no marker (first run) gets the whole set; any other
# file gets the entries marked "upgrade" it hasn't been offered yet (new features, not examples).
# An entry is skipped if the file already has the same hotkey under any key; otherwise it's added,
# and if its key is taken it's added switched off (SwitchedOff says by what), so nothing the user
# set up changes. One that can't be added at all (Dropped, e.g. no profile yet) is offered again
# next time.
function Add-StarterHotkeys([string]$text, [string]$templateJson, [string]$profile, [hashtable]$Values = @{}) {
    $m = Get-FileModel $text
    $json = $templateJson
    $Values = @{} + $Values; $Values['__PROFILE__'] = $profile
    foreach ($k in $Values.Keys) { $json = $json.Replace($k, (ConvertTo-Json -InputObject "$($Values[$k])" -Compress).Trim('"')) }
    $tpl = @(($json | ConvertFrom-Json).bindings | Where-Object { $_.id })
    $offered = Get-StarterOffered $m.Lines @($tpl | ForEach-Object id)
    $firstRun = $null -eq $offered -and $m.Bindings.Count -eq 0
    if ($null -eq $offered) { $offered = @() }
    $result = [PSCustomObject]@{ Text = $text; Count = 0; FirstRun = $firstRun; Added = @(); SwitchedOff = @(); Dropped = @() }
    $todo = @($tpl | Where-Object { $_.id -notin $offered -and ($firstRun -or $_.upgrade -eq $true) })
    if (-not $todo) { return $result }

    $cur = Set-StarterMarker $text $offered
    foreach ($t in $todo) {
        $c = [ordered]@{}
        foreach ($p in $t.PSObject.Properties) { if ($p.Name -notin 'id', 'upgrade') { $c[$p.Name] = $p.Value } }
        if (-not $c.Contains('enabled')) { $c['enabled'] = $true }
        $c = [PSCustomObject]$c
        $existing = @((Get-FileModel $cur).Bindings)
        $id = Get-StarterIdentity $c
        if ($existing | Where-Object { (Get-StarterIdentity $_) -eq $id }) { $offered += $t.id; continue }
        $r = Invoke-AppHotkeysRewrite $cur (@($existing) + $c) -KeepInvalid
        $mine = @($r.Dropped | Where-Object { $_.title -eq "$($c.title)" -and $_.key -eq "$($c.key)" })
        if ($mine -and $mine[0].reason -like 'same key as *') {
            $c.enabled = $false
            $r = Invoke-AppHotkeysRewrite $cur (@($existing) + $c) -KeepInvalid
            $result.SwitchedOff += [PSCustomObject]@{ title = "$($c.title)"; key = "$($c.key)"; takenBy = $mine[0].reason.Substring(12) }
        } elseif ($mine) {
            $result.Dropped += $mine
            continue
        } else {
            $result.Added += [PSCustomObject]@{ title = "$($c.title)"; key = "$($c.key)" }
        }
        $cur = $r.Text
        $offered += $t.id
    }
    $result.Text = Set-StarterMarker $cur $offered
    $result.Count = @($result.Added).Count + @($result.SwitchedOff).Count
    $result
}

# The tray notification for what Add-StarterHotkeys did, "" for nothing worth saying.
function Format-StarterNotice($s) {
    if ($s.FirstRun) { return $(if ($s.Count) { "Suggested hotkeys added to app-hotkeys.ahk. Press Ctrl+Alt+/ to view and edit them." } else { "" }) }
    $parts = @()
    foreach ($a in $s.Added) { $parts += "New hotkey: $($a.title) ($($a.key))." }
    foreach ($o in $s.SwitchedOff) { $parts += "New: $($o.title). $($o.key) is already used by $($o.takenBy), so it was added switched off - give it a key on the Hotkeys page." }
    $parts -join ' '
}
