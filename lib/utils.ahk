; utils.ahk - General-purpose UI helpers and window management

; Escapes a string for safe embedding in a JSON double-quoted value.
JsonEscape(s) {
    s := StrReplace(s, "\",  "\\")
    s := StrReplace(s, '"',  '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return s
}

ShowTextGui(title, text, width := 700, rows := 20) {
    g := Gui("+Resize", title)
    editCtrl := g.Add("Edit", "r" rows " w" width " ReadOnly", text)
    closeBtn := g.Add("Button", "Default w" width, "Close")
    closeBtn.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Size", (g, mm, w, h) => (editCtrl.Move(,, w-16, h-47), closeBtn.Move(, h-31, w-16)))
    g.Show()
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

; Parses app-hotkeys.ahk and returns a formatted hotkey reference string.
; Descriptions are derived from FocusTab/ManageAppWindows/Cycle*Profile arguments.
_BuildHotkeyRef() {
    content  := FileRead(A_ScriptDir "\lib\app-hotkeys.ahk", "UTF-8")
    lines    := StrSplit(content, "`n", "`r")

    profiles := Map()
    pos := 1
    while RegExMatch(content, '(?m)^(P\w+)\s*:=\s*"([^"]+)"', &m, pos) {
        profiles[m[1]] := m[2]
        pos := m.Pos + m.Len
    }

    ref     := ""
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
        desc := _HotkeyDesc(action, profiles)
        if desc = ""
            continue
        ref .= _FormatHotkeyCombo(combo) . "  →  " . desc . "`n"
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

_HotkeyDesc(action, profiles) {
    if InStr(action, "FocusTab(") || InStr(action, "FocusTabFirefox(") {
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
    if InStr(action, "ManageAppWindows(") || InStr(action, "ShowTextGui(") {
        if RegExMatch(action, '"([^"]+)"', &m)
            return m[1]
    }
    if RegExMatch(action, "Cycle\w+Profile\((\w+)\)", &m) {
        pVar := m[1]
        return (profiles.Has(pVar) ? profiles[pVar] : pVar) . " (cycle)"
    }
    return ""
}

; ManageAppWindows(processName, exePath, mode)
;
; processName  - executable name, e.g. "notepad++.exe"
; exePath      - path to launch when no windows exist; pass "" to do nothing
; mode         - "cycle"  : 1 window -> toggle minimize/activate;
;                           2+ windows -> activate the next, wrapping around;
;                           0 windows -> launch exePath
;              - "toggle" : focus the app if it isn't active; minimize all its
;                           visible windows if one of them is currently active
;
; Visible windows = WS_VISIBLE, unowned, not minimized
ManageAppWindows(processName, exePath := "", mode := "cycle") {
    ; Only consider windows that are:
    ;   - WS_VISIBLE (excludes hidden background windows e.g. Discord tray)
    ;   - unowned (excludes dialogs/toolbars owned by a main window e.g. Notepad++ Find)
    ; DetectHiddenWindows is ON globally, so we must filter manually.
    visible := []   ; WS_VISIBLE, unowned, not minimized
    minimized := [] ; WS_VISIBLE, unowned, minimized
    for hwnd in WinGetList("ahk_exe " processName) {
        if !(WinGetStyle("ahk_id " hwnd) & 0x10000000)  ; not WS_VISIBLE
            continue
        if DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") != 0  ; owned window (dialog etc.)
            continue
        if WinGetMinMax("ahk_id " hwnd) = -1
            minimized.Push(hwnd)
        else
            visible.Push(hwnd)
    }

    ; No windows at all -> launch
    if visible.Length = 0 && minimized.Length = 0 {
        if exePath != ""
            Run(exePath)
        return
    }

    activeHwnd := WinGetID("A")

    if mode = "toggle" {
        isMine := false
        for hwnd in visible
            if hwnd = activeHwnd {
                isMine := true
                break
            }
        if isMine {
            for hwnd in visible
                WinMinimize("ahk_id " hwnd)
        } else if visible.Length > 0 {
            WinActivate("ahk_id " visible[1])
        } else {
            WinRestore("ahk_id " minimized[1])
            WinActivate("ahk_id " minimized[1])
        }
        return
    }

    ; cycle: no visible windows -> restore MRU minimized one
    if visible.Length = 0 {
        WinRestore("ahk_id " minimized[1])
        WinActivate("ahk_id " minimized[1])
        return
    }

    ; cycle: single visible window -> toggle minimize/activate
    if visible.Length = 1 {
        if visible[1] = activeHwnd
            WinMinimize("ahk_id " visible[1])
        else
            WinActivate("ahk_id " visible[1])
        return
    }

    ; cycle: multiple visible windows -> advance to next, wrapping around
    activeIdx := 0
    for i, hwnd in visible
        if hwnd = activeHwnd {
            activeIdx := i
            break
        }

    nextIdx := Mod(activeIdx, visible.Length) + 1
    WinActivate("ahk_id " visible[nextIdx])
}
