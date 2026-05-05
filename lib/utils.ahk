; utils.ahk - General-purpose UI helpers and window management

; When true, cycle mode falls back to toggle when an app has only one window.
; Overridable in config.ahk or via the Settings UI (Ctrl+Alt+Shift+,).
CYCLE_SINGLE_AS_TOGGLE := false

; Launches a Microsoft Store (MSIX) app from an elevated AHK process.
; Pass either an AUMID (e.g. "Claude_pzs8sxrjxfjjc!Claude") or an App Execution
; Alias exe name (e.g. "Claude.exe"). Shell.Application runs in the user (non-elevated)
; context, which is required to activate MSIX apps from an elevated process.
LaunchStoreApp(aumidOrExe) {
    target := InStr(aumidOrExe, "!")
        ? "shell:AppsFolder\" . aumidOrExe
        : EnvGet("LOCALAPPDATA") . "\Microsoft\WindowsApps\" . aumidOrExe
    ComObject("Shell.Application").ShellExecute(target)
}

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

; Returns the current time as a Unix timestamp and copies it to the clipboard.
UnixTimestampToClipboard() {
    ts := DateDiff(A_Now, "19700101000000", "Seconds")
    A_Clipboard := ts
    MsgBox(ts " has been copied to clipboard.")
}

; Prompts for a Jira-style issue number and opens `prefix-<number>` in the browser.
; prefix should end with the project key, e.g. "https://jira.example.com/browse/PROJ".
OpenIssue(prefix) {
    proj := SubStr(prefix, -2)
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
    Run(prefix "-" result.Value)
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
    return ""
}

; ManageAppWindows(processName, exePath, mode)
;
; processName  - executable name, e.g. "notepad++.exe"
; exePath      - path to launch when no windows exist; pass "" to do nothing
; mode         - "cycle"  : advance through all windows (visible then minimized),
;                           wrapping around; restores minimized windows as they
;                           come up in rotation; 0 windows -> launch exePath;
;                           1 window -> same as "toggle" when CYCLE_SINGLE_AS_TOGGLE is true
;              - "toggle" : focus the app if it isn't active; minimize all its
;                           visible windows if one of them is currently active
;
; Visible windows = WS_VISIBLE, unowned, not minimized
ManageAppWindows(processName, exePath := "", mode := "cycle") {
    ; Only consider windows that are:
    ;   - WS_VISIBLE (excludes hidden background windows e.g. Discord tray)
    ;   - unowned (excludes dialogs/toolbars owned by a main window e.g. Notepad++ Find)
    ; DetectHiddenWindows is ON globally, so we must filter manually.
    visible := []
    minimized := []
    for hwnd in WinGetList("ahk_exe " processName) {
        if !(WinGetStyle("ahk_id " hwnd) & 0x10000000)  ; not WS_VISIBLE
            continue
        if DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") != 0  ; owned window
            continue
        if WinGetMinMax("ahk_id " hwnd) = -1
            minimized.Push(hwnd)
        else
            visible.Push(hwnd)
    }

    ; No windows at all -> launch
    if visible.Length = 0 && minimized.Length = 0 {
        if exePath is Func
            exePath()
        else if exePath != ""
            Run(exePath)
        return
    }

    activeHwnd := 0
    try activeHwnd := WinGetID("A")

    if mode = "toggle" {
        ; Use process name to detect ownership — more reliable than HWND matching when
        ; privilege level differences cause some windows to be missed in visible/minimized.
        isMine := false
        try isMine := (WinGetProcessName("A") = processName)
        if !isMine {
            for hwnd in visible
                if hwnd = activeHwnd {
                    isMine := true
                    break
                }
        }
        if isMine {
            for hwnd in visible
                WinMinimize("ahk_id " hwnd)
        } else {
            for hwnd in minimized
                WinRestore("ahk_id " hwnd)
            if visible.Length > 0
                WinActivate("ahk_id " visible[1])
            else if minimized.Length > 0
                WinActivate("ahk_id " minimized[1])
        }
        return
    }

    if mode = "cycle" && CYCLE_SINGLE_AS_TOGGLE && (visible.Length + minimized.Length = 1) {
        ManageAppWindows(processName, exePath, "toggle")
        return
    }

    ; cycle: advance through all windows (visible first, then minimized), wrapping around
    all := []
    for hwnd in visible
        all.Push(hwnd)
    for hwnd in minimized
        all.Push(hwnd)

    activeIdx := 0
    for i, hwnd in all
        if hwnd = activeHwnd {
            activeIdx := i
            break
        }

    nextIdx := Mod(activeIdx, all.Length) + 1
    nextHwnd := all[nextIdx]
    if WinGetMinMax("ahk_id " nextHwnd) = -1
        WinRestore("ahk_id " nextHwnd)
    WinActivate("ahk_id " nextHwnd)
}

_settingsGui := 0

ShowSettingsGui() {
    global _settingsGui
    if IsObject(_settingsGui) {
        try _settingsGui.Show()
        return
    }

    origChromiumExe       := CHROMIUM_EXE
    origChromiumUserdata  := CHROMIUM_USERDATA
    origFirefoxExe        := FIREFOX_EXE
    origFirefoxProfileIni := FIREFOX_PROFILE_INI

    g := Gui("+AlwaysOnTop", "AltTabSucks Settings")
    g.SetFont("s10", "Segoe UI")
    _settingsGui := g

    g.AddText("xm w440 Section", "Browser Paths")

    g.AddText("xm y+6", "Chromium EXE")
    chromiumExeEdit := g.AddEdit("xm w360", CHROMIUM_EXE)
    g.AddButton("x+4 yp", "Browse").OnEvent("Click", (*) => _BrowseForFile(chromiumExeEdit, "Executable (*.exe)", "*.exe"))

    g.AddText("xm", "Chromium User Data folder")
    chromiumUserdataEdit := g.AddEdit("xm w360", CHROMIUM_USERDATA)
    g.AddButton("x+4 yp", "Browse").OnEvent("Click", (*) => _BrowseForDir(chromiumUserdataEdit))

    g.AddText("xm", "Firefox EXE")
    firefoxExeEdit := g.AddEdit("xm w360", FIREFOX_EXE)
    g.AddButton("x+4 yp", "Browse").OnEvent("Click", (*) => _BrowseForFile(firefoxExeEdit, "Executable (*.exe)", "*.exe"))

    g.AddText("xm", "Firefox profiles.ini")
    firefoxProfileIniEdit := g.AddEdit("xm w360", FIREFOX_PROFILE_INI)
    g.AddButton("x+4 yp", "Browse").OnEvent("Click", (*) => _BrowseForFile(firefoxProfileIniEdit, "INI file (*.ini)", "*.ini"))

    g.AddText("xm y+14 w440", "Behavior")
    cycleCb := g.AddCheckbox("xm y+6 w440", "Cycle mode falls back to toggle when app has only one window")
    cycleCb.Value := CYCLE_SINGLE_AS_TOGGLE

    g.AddText("xm y+12")
    saveBtn := g.AddButton("xm Default w80", "Save")
    g.AddButton("x+6 yp w80", "Cancel").OnEvent("Click", CloseGui)
    saveBtn.OnEvent("Click", SaveSettings)
    g.OnEvent("Close",  CloseGui)
    g.OnEvent("Escape", CloseGui)

    CloseGui(*) {
        global _settingsGui
        _settingsGui := 0
        g.Destroy()
    }

    SaveSettings(*) {
        newChromiumExe       := Trim(chromiumExeEdit.Value)
        newChromiumUserdata  := Trim(chromiumUserdataEdit.Value)
        newFirefoxExe        := Trim(firefoxExeEdit.Value)
        newFirefoxProfileIni := Trim(firefoxProfileIniEdit.Value)
        newCycleSingle       := cycleCb.Value

        _WriteConfigFile(newChromiumExe, newChromiumUserdata, newFirefoxExe, newFirefoxProfileIni, newCycleSingle)

        pathsChanged := newChromiumExe       != origChromiumExe
                     || newChromiumUserdata  != origChromiumUserdata
                     || newFirefoxExe        != origFirefoxExe
                     || newFirefoxProfileIni != origFirefoxProfileIni
        if pathsChanged {
            CloseGui()
            Reload()
            return
        }
        global CYCLE_SINGLE_AS_TOGGLE := newCycleSingle
        CloseGui()
    }

    g.Show("AutoSize")
}

_BrowseForFile(editCtrl, desc, filter) {
    path := FileSelect(3,, desc, filter)
    if path != ""
        editCtrl.Value := path
}

_BrowseForDir(editCtrl) {
    path := DirSelect("*" editCtrl.Value,, "Select folder")
    if path != ""
        editCtrl.Value := path
}

_WriteConfigFile(chromiumExe, chromiumUserdata, firefoxExe, firefoxProfileIni, cycleSingleAsToggle) {
    esc := (s) => StrReplace(StrReplace(s, "``", "````"), '"', '`"')
    content := '; config.ahk — AltTabSucks settings. Edit manually or use Ctrl+Alt+Shift+, to open the Settings UI.'
             . '`n; This file is gitignored.'
             . '`n`nglobal CHROMIUM_EXE        := "' esc(chromiumExe)        '"'
             . '`nglobal CHROMIUM_USERDATA   := "' esc(chromiumUserdata)   '"'
             . '`nglobal FIREFOX_EXE         := "' esc(firefoxExe)         '"'
             . '`nglobal FIREFOX_PROFILE_INI := "' esc(firefoxProfileIni)  '"'
             . '`n`nglobal CYCLE_SINGLE_AS_TOGGLE := ' (cycleSingleAsToggle ? "true" : "false") '`n'
    f := FileOpen(A_ScriptDir '\lib\config.ahk', 'w', 'UTF-8')
    f.Write(content)
    f.Close()
}
