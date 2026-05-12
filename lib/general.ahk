; general.ahk - General-purpose UI helpers

; Escapes a string for safe embedding in a JSON double-quoted value.
JsonEscape(s) {
    s := StrReplace(s, "\",  "\\")
    s := StrReplace(s, '"',  '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return s
}

ShowTextGui(title, text, width := 700, rows := 20) {  ; rows ignored — height auto-sizes to content
    isDark := _SwitcherIsDark()
    bg     := isDark ? "1E1E1E" : "F5F5F5"
    editBg := isDark ? "2D2D2D" : "FFFFFF"
    fg     := isDark ? "EFEFEF" : "1A1A1A"

    lineCount := 0
    Loop Parse, text, "`n"
        lineCount++

    g := Gui("+Resize", title)
    g.SetFont("s10", "Segoe UI")
    if isDark
        g.BackColor := bg
    editCtrl := g.Add("Edit", "r" (lineCount + 1) " w" width " ReadOnly", text)
    editCtrl.SetFont("c" . fg)
    if isDark
        editCtrl.Opt("+Background" . editBg)
    closeBtn := g.Add("Button", "Default w" width, "Close")
    closeBtn.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Size", (g, mm, w, h) => (editCtrl.Move(,, w-16, h-47), closeBtn.Move(, h-31, w-16)))

    g.Show("Hide AutoSize")
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 20, "Int*", isDark ? 1 : 0, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    _ThemeEdit(editCtrl, isDark)
    _ThemeButton(closeBtn, isDark)

    MonitorGetWorkArea(, &waL, &waT, &waR, &waB)
    WinGetPos(&_x, &_y, &ww, &wh, "ahk_id " g.Hwnd)
    finalH := Min(wh, waB - waT)
    finalX := (waL + waR - ww) // 2
    finalY := Max(waT, (waT + waB - finalH) // 2)
    g.Show("x" finalX " y" finalY " w" ww " h" finalH)

    closeBtn.Focus()
}

; Converts a clipboard column (one value per line, e.g. from SSMS) to a SQL IN clause.
; Usage: select a column of cells, Ctrl+C, fire the hotkey, then Ctrl+V.
; Result: ('VAL1','VAL2','VAL3')
ClipboardToSqlIn() {
    words := StrUpper(A_Clipboard)
    text  := ""
    Loop Parse, words, "`n", "`r" {
        field := Trim(A_LoopField)
        if field = ""
            continue
        text .= (text ? ",'" : "'") . field . "'"
    }
    if text != ""
        A_Clipboard := "(" . text . ")"
}

; Converts highlighted text (a number in cm) to feet and inches, saves result to clipboard.
; Usage: select the number, fire the hotkey, then Ctrl+V.
; Result: e.g. "5 11.2" (feet inches)
ClipboardCmToFtIn() {
    ; Send("^c")
    ClipWait(0.5)
    try
        num_in := Number(Trim(A_Clipboard)) / 2.54
    catch {
        ShowProfileToast(WinGetID("A"), "not a number", "CC0000")
        return
    }
    num_ft := Floor(num_in / 12)
    num_in := num_in - num_ft * 12
    A_Clipboard := num_ft . "' " . Round(num_in, 1) . Chr(34) ; Chr(34) = double quote
}

; Returns the current time as a Unix timestamp and copies it to the clipboard.
UnixTimestampToClipboard() {
    ts := DateDiff(A_Now, "19700101000000", "Seconds")
    A_Clipboard := ts
    MsgBox(ts " has been copied to clipboard.")
}

; Prompts for a Jira-style issue number and opens `prefix-<number>` in the browser.
; prefix should end with the project key, e.g. "https://jira.example.com/browse/PROJ".
OpenIssue(prefix) {
    proj := SubStr(prefix, -3)
    insults := ["POXED WOODLOUSE", "SCRUB-FACED CIVILIAN", "HIDEOUS SEABIRD", "BEEF-WITTED NINNY",
        "DISAGREEABLE BILGE DWELLER", "SOGGY RODENT THIEF", "SCURRILOUS INSECT",
        "INFAMOUS SCOUNDREL", "BANKRUPT SEA LIZARD", "FLEA RIDDEN LANDLUBBER",
        "YELLOWBELLIED BARNACLE EATER", "FRESHWATER POND LARVAE", "LANKY BOTTOMSCRAPER",
        "COWARDLY SEAGULL", "BLUBBERIN SQUID", "MILK HEADED BABOON", "TOOTHLESS OLD MAN",
        "ILL BRED BILIOUS OX", "UNREDEEMABLE VILLIAN", "VILE FELLOW",
        "THICK HEADED MISCREANT", "UNRELENTING PARASITE"]
    insult := insults[Random(1, insults.Length)]
    result := InputBox(
        "AARGHGH! Enter ye olde " proj " issue number AND FIRE THE CANNONS YE " insult "!",
        "Open " proj " Issue", "H150 T15")
    if result.Result != "OK" || result.Value = ""
        return
    url := (SubStr(prefix, 1, 4) = "http") ? prefix : "https://" prefix
    Run(url "-" result.Value)
}

; Parses app-hotkeys.ahk and returns a formatted hotkey reference string grouped
; by called function. Section headers are the function name itself — no hardcoded
; category list. A hotkey appears only if its function has a _Desc* handler.
_BuildHotkeyRef() {
    content  := FileRead(A_ScriptDir "\lib\app-hotkeys.ahk", "UTF-8")
    lines    := StrSplit(content, "`n", "`r")

    profiles := Map()
    pos := 1
    while RegExMatch(content, '(?m)^(P\w+)\s*:=\s*"([^"]+)"', &m, pos) {
        profiles[m[1]] := m[2]
        pos := m.Pos + m.Len
    }

    ; Keyed by function name, ordered by first appearance in the file
    categoryOrder := []
    categories    := Map()

    inBlock := false
    for line in lines {
        trimmed := Trim(line)
        if inBlock {
            if trimmed = "}"
                inBlock := false
            continue
        }
        if !RegExMatch(trimmed, "^([^\s:]+)::\s*(.*)", &hm)
            continue
        combo  := hm[1]
        action := Trim(hm[2])
        if action = "{" {
            inBlock := true
            continue
        }
        if action = "" || action = "return"
            continue
        if !RegExMatch(action, "^(\w+)", &fm)
            continue
        funcName := fm[1]
        desc     := _HotkeyDesc(funcName, action, profiles)
        if desc = ""
            continue
        if !categories.Has(funcName) {
            categoryOrder.Push(funcName)
            categories[funcName] := []
        }
        categories[funcName].Push(_FormatHotkeyCombo(combo) . "  →  " . desc)
    }

    ref := ""
    for cat in categoryOrder {
        ref .= (ref ? "`n" : "") . "── " . cat . " ──`n"
        for entry in categories[cat]
            ref .= entry . "`n"
    }
    return Trim(ref)
}

_FormatHotkeyCombo(combo) {
    modChars := "^!+#~*$<>&@"
    keyStart := 1
    Loop StrLen(combo) {
        if InStr(modChars, SubStr(combo, A_Index, 1))
            keyStart := A_Index + 1
        else
            break
    }
    if keyStart > StrLen(combo)
        keyStart := StrLen(combo)
    mods := SubStr(combo, 1, keyStart - 1)
    key  := SubStr(combo, keyStart)
    return (InStr(mods, "^") ? "Ctrl+"  : "")
         . (InStr(mods, "!") ? "Alt+"   : "")
         . (InStr(mods, "+") ? "Shift+" : "")
         . (InStr(mods, "#") ? "Win+"   : "")
         . StrUpper(key)
}

_HotkeyDesc(funcName, action, profiles) {
    if funcName = "FocusTab" || funcName = "FocusTabFirefox" {
        all := []
        pos := 1
        while RegExMatch(action, '"([^"]+)"', &m, pos) {
            all.Push(m[1])
            pos := m.Pos + m.Len
        }
        if all.Length = 0
            return ""
        openUrl  := RegExReplace(all[all.Length], "^https?://")
        patterns := ""
        Loop all.Length - 1
            patterns .= (patterns ? ", " : "") . RegExReplace(all[A_Index], "^https?://")
        return (patterns ? patterns . "  →  " : "") . openUrl
    }
    if funcName = "ManageAppWindows" || funcName = "ShowTextGui" {
        if RegExMatch(action, '"([^"]+)"', &m)
            return m[1]
    }
    if RegExMatch(funcName, "Cycle\w+Profile") {
        if RegExMatch(action, "\((\w+)\)", &m) {
            pVar := m[1]
            return (profiles.Has(pVar) ? profiles[pVar] : pVar) . " (cycle)"
        }
    }
    if funcName = "SplitFocusedTab"
        return "split active tab → new window, snap side-by-side"
    if funcName = "MergeFocusedWindow"
        return "merge focused window's tabs → other window"
    if funcName = "ShowAltTabSucksDebug"
        return "AltTabSucks debug overlay"
    if funcName = "ShowSettingsGui"
        return "settings"
    if funcName = "ShowWindowSwitcher"
        return "window typeahead switcher"
    return ""
}