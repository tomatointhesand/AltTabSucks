# AppHotkeysMigration.ps1 - moves static hotkeys from lib/app-hotkeys.ahk into the web Hotkeys UI.
# Called by AltTabSucksServer.ps1's POST /migrate-app-hotkeys, which AltTabSucks.ahk hits on every
# startup (lib/hotkeys-ui.ahk); a no-op once nothing convertible is left.
#
# Converts single-line hotkeys calling FocusTab / CycleChromiumProfile / ManageAppWindows /
# SplitFocusedTab / MergeFocusedWindow (and the Firefox variants) into hotkeys.json bindings, and
# returns the file text with those lines commented out. Anything else - blocks, local functions,
# Run(), ~/*/$ prefixes, hotkeys under other #HotIf criteria - is left for app-hotkeys.ahk.
# A #HotIf !WinActive("X") block becomes UI_HOTKEYS_SUPPRESS_WHEN := "X".

$MigratedMarker = "; [migrated to Hotkeys UI] "

# "^!+m" -> "Ctrl+Alt+Shift+M" (the page's recorder format, which HotkeysGenerator.ps1 converts back)
function ConvertFrom-AhkKey([string]$hk) {
    if ($hk -notmatch '^([\^!+#]*)(.+)$') { return $null }
    $mods = $Matches[1]; $base = $Matches[2]
    if ($base -match '[\s&~*$<>]') { return $null }
    $names = @{ Enter = 'Return'; Esc = 'Escape'; Del = 'Delete'; Ins = 'Insert'; PgUp = 'PageUp'; PgDn = 'PageDown' }
    if ($base.Length -eq 1) { $base = $base.ToUpperInvariant() }
    elseif ($names.ContainsKey($base)) { $base = $names[$base] }
    $parts = @()
    if ($mods.Contains('^')) { $parts += 'Ctrl' }
    if ($mods.Contains('!')) { $parts += 'Alt' }
    if ($mods.Contains('+')) { $parts += 'Shift' }
    if ($mods.Contains('#')) { $parts += 'Meta' }
    ($parts + $base) -join '+'
}

# AHK string-concatenation expression of "literals" and EnvGet("VAR") -> plain string, or $null
function Resolve-AhkStringExpr([string]$expr) {
    $expr = $expr.Trim()
    if ($expr -match '^\(\)\s*=>\s*LaunchStoreApp\("([^"`]+)"\)$') {
        $id = $Matches[1]
        if ($id.Contains('!')) { return "shell:AppsFolder\$id" }
        return Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$id"
    }
    $tokens = [regex]::Matches($expr, 'EnvGet\("(\w+)"\)|"([^"`]*)"')
    $leftover = ([regex]::Replace($expr, 'EnvGet\("\w+"\)|"[^"`]*"', '')) -replace '[\s.]', ''
    if ($tokens.Count -eq 0 -or $leftover) { return $null }
    $out = ''
    foreach ($t in $tokens) {
        if ($t.Groups[1].Success) { $out += [Environment]::GetEnvironmentVariable($t.Groups[1].Value) }
        else { $out += $t.Groups[2].Value }
    }
    $out
}

function Invoke-AppHotkeysMigration([string]$text, $existingBindings) {
    $lines = $text -split "`n"

    # P1 := "Default" style profile variables (uncommented, last one wins)
    $profileVars = @{}
    foreach ($l in $lines) {
        if ($l -match '^\s*(\w+)\s*:=\s*"([^"`]*)"') { $profileVars[$Matches[1]] = $Matches[2] }
    }
    $resolveProfile = {
        param($tok)
        $tok = $tok.Trim()
        if ($tok -match '^"([^"`]+)"$') { return $Matches[1] }
        if ($profileVars.ContainsKey($tok)) { return $profileVars[$tok] }
        $null
    }

    $hasSuppress = [bool]($lines | Where-Object { $_ -match '^\s*UI_HOTKEYS_SUPPRESS_WHEN\s*:=' })
    $suppress = $null; $suppressInsertAt = -1
    $ctx = ''
    $new = New-Object System.Collections.ArrayList
    $migrated = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]; $t = $line.TrimEnd("`r").Trim()
        if ($t -match '^#HotIf\b\s*(.*)$') { $ctx = $Matches[1].Trim() }
        if ($t -notmatch '^([^\s:;]+)::\s*(\w+)\((.*)\)\s*(;.*)?$') { continue }
        $hk = $Matches[1]; $fn = $Matches[2]; $argStr = $Matches[3]

        $browserCtx = $ctx -match 'Chrome_WidgetWin_1|MozillaWindowClass'
        $suppressCtx = if ($ctx -match '^!WinActive\("([^"`]+)"\)$') { $Matches[1] } else { $null }
        if ($ctx -and -not $browserCtx -and -not $suppressCtx) { continue }   # other #HotIf criteria
        if ($suppressCtx -and $suppress -and $suppressCtx -ne $suppress) { continue }

        $key = ConvertFrom-AhkKey $hk
        if (-not $key) { continue }
        $b = $null
        switch -Regex ($fn) {
            '^(FocusTab|FocusTabFirefox)$' {
                if ($argStr -match '^\s*("[^"`]*"|\w+)\s*,\s*(\[[^\]]*\]|"[^"`]*")\s*,\s*"([^"`]+)"\s*$') {
                    $profTok = $Matches[1]; $patsStr = $Matches[2]; $url = $Matches[3]
                    $prof = & $resolveProfile $profTok
                    $pats = @([regex]::Matches($patsStr, '"([^"`]*)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ })
                    if ($prof -and $pats) {
                        $b = [ordered]@{ type = 'tabFocus'; title = ($pats[0] -replace '^https?://', ''); key = $key
                                         profileName = $prof; urlPatterns = $pats; openUrl = $url }
                    }
                }
            }
            '^(CycleChromiumProfile|CycleFirefoxProfile)$' {
                $prof = & $resolveProfile $argStr
                if ($prof) { $b = [ordered]@{ type = 'profileCycle'; title = "Cycle $prof"; key = $key; profileName = $prof; launchProfileName = $prof } }
            }
            '^ManageAppWindows$' {
                if ($argStr -match '^\s*"([^"`]+)"\s*(?:,\s*(.*?))?\s*(?:,\s*"(cycle|toggle)")?\s*$') {
                    $proc = $Matches[1]; $launchExpr = $Matches[2]; $mode = if ($Matches[3]) { $Matches[3] } else { 'cycle' }
                    $launch = if ($launchExpr) { Resolve-AhkStringExpr $launchExpr } else { '' }
                    if ($null -ne $launch) {
                        $b = [ordered]@{ type = $(if ($mode -eq 'toggle') { 'windowToggle' } else { 'windowCycle' })
                                         title = [IO.Path]::GetFileNameWithoutExtension($proc); key = $key; resourceClass = $proc
                                         launchArgv = @(@($launch) | Where-Object { $_ }) }
                    }
                }
            }
            '^SplitFocusedTab$'    { if (-not $argStr.Trim()) { $b = [ordered]@{ type = 'splitTab'; title = 'Split tab'; key = $key } } }
            '^MergeFocusedWindow$' { if (-not $argStr.Trim()) { $b = [ordered]@{ type = 'mergeTabs'; title = 'Merge windows'; key = $key } } }
        }
        if (-not $b) { continue }
        if ($browserCtx -and $b.type -notin 'splitTab', 'mergeTabs') { continue }
        if ($new | Where-Object { $_.key -eq $key }) { continue }   # same key twice in the file: keep the first

        if ($suppressCtx -and -not $suppress) {
            $suppress = $suppressCtx
            if (-not $hasSuppress) {   # insert the setting just above this #HotIf block
                for ($j = $i; $j -ge 0; $j--) { if ($lines[$j].Trim() -match '^#HotIf\b') { $suppressInsertAt = $j; break } }
            }
        }
        [void]$new.Add($b)
        $lines[$i] = $MigratedMarker + $line
        $migrated++
    }

    if ($suppressInsertAt -ge 0) {
        $eol = if ($lines[$suppressInsertAt].EndsWith("`r")) { "`r" } else { "" }
        $list = [System.Collections.ArrayList]@($lines)
        $list.Insert($suppressInsertAt, "UI_HOTKEYS_SUPPRESS_WHEN := `"$suppress`"  ; added by the Hotkeys UI migration$eol")
        $lines = $list.ToArray()
    }

    # Migrated hotkeys replace existing UI bindings on the same key (e.g. a seeded starter hotkey)
    $keys = @($new | ForEach-Object { $_.key })
    $bindings = @(@($existingBindings) | Where-Object { $_ -and $keys -notcontains $_.key }) + @($new | ForEach-Object { [PSCustomObject]$_ })
    [PSCustomObject]@{ Count = $migrated; Text = ($lines -join "`n"); Bindings = $bindings }
}
