; utils.ahk - General-purpose UI helpers and window management

; When true, cycle mode falls back to toggle when an app has only one window.
; Overridable in config.ahk or via the Settings UI (Ctrl+Alt+Shift+,).
CYCLE_SINGLE_AS_TOGGLE := false

; "auto" follows the system dark/light setting; "dark" or "light" forces a specific theme.
THEME := "auto"

; When true, a live DWM thumbnail of the highlighted window appears beside the switcher popup.
SWITCHER_SHOW_PREVIEW := true

; Which side of the switcher popup the window preview appears on: "right" or "left".
SWITCHER_PREVIEW_SIDE := "right"

; Preview size as a percentage of the default max dimensions (640×400). Range 25–200.
SWITCHER_PREVIEW_SIZE := 100

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
    if funcName = "ShowWindowSwitcher"
        return "window typeahead switcher"
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
            toastHwnd := visible.Length > 0 ? visible[1] : (minimized.Length > 0 ? minimized[1] : 0)
            if toastHwnd
                WinActivate("ahk_id " toastHwnd)
            if toastHwnd
                ShowProfileToast(toastHwnd, _SwitcherExeName(SubStr(processName, 1, -4)), SampleTitlebarColor(toastHwnd))
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
    ShowProfileToast(nextHwnd, _SwitcherExeName(SubStr(processName, 1, -4)), SampleTitlebarColor(nextHwnd))
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

    isDark := _SwitcherIsDark()
    bg         := isDark ? "202020" : ""
    editBg     := isDark ? "2D2D2D" : ""
    fg         := isDark ? "EFEFEF" : ""
    hint       := isDark ? "A0A0A0" : "808080"
    baseFont   := isDark ? "s10 Norm c" . fg : "s10 Norm"
    headerFont := isDark ? "s10 Bold Underline c" . fg : "s10 Bold Underline"

    g := Gui("+AlwaysOnTop +Resize", "AltTabSucks Settings")
    g.SetFont(baseFont, "Segoe UI")
    if isDark
        g.BackColor := bg
    _settingsGui := g

    ; Inline helpers
    addEdit(opts, val := "") {
        e := g.AddEdit(opts, val)
        if isDark
            e.Opt("+Background" . editBg)
        return e
    }
    addHeader(label, yOpt := "xm y+14 w500") {
        g.SetFont(headerFont, "Segoe UI")
        hdr := g.AddText(yOpt, label)
        g.SetFont(baseFont, "Segoe UI")
        return hdr
    }

    ; ── Browser ──────────────────────────────────────────────────────────────
    hdrBrowser := addHeader("Browser", "xm w500")

    g.AddText("xm y+6", "Chromium EXE")
    chromiumExeEdit  := addEdit("xm w420 -HScroll", CHROMIUM_EXE)
    browseChrExeBtn  := g.AddButton("x+4 yp", "Browse")
    browseChrExeBtn.OnEvent("Click",  (*) => _BrowseForFile(chromiumExeEdit, "Executable (*.exe)", "*.exe"))

    g.AddText("xm", "Chromium User Data folder")
    chromiumUserdataEdit := addEdit("xm w420 -HScroll", CHROMIUM_USERDATA)
    browseChrDataBtn     := g.AddButton("x+4 yp", "Browse")
    browseChrDataBtn.OnEvent("Click", (*) => _BrowseForDir(chromiumUserdataEdit))

    g.AddText("xm", "Firefox EXE")
    firefoxExeEdit  := addEdit("xm w420 -HScroll", FIREFOX_EXE)
    browseFfExeBtn  := g.AddButton("x+4 yp", "Browse")
    browseFfExeBtn.OnEvent("Click",   (*) => _BrowseForFile(firefoxExeEdit, "Executable (*.exe)", "*.exe"))

    g.AddText("xm", "Firefox profiles.ini")
    firefoxProfileIniEdit := addEdit("xm w420 -HScroll", FIREFOX_PROFILE_INI)
    browseFfProfileBtn    := g.AddButton("x+4 yp", "Browse")
    browseFfProfileBtn.OnEvent("Click", (*) => _BrowseForFile(firefoxProfileIniEdit, "INI file (*.ini)", "*.ini"))

    ; ── Window Cycling ────────────────────────────────────────────────────────
    hdrCycling := addHeader("Window Cycling")
    cycleCb := g.AddCheckbox("xm y+6 w500", "Cycle mode falls back to toggle when app has only one window")
    cycleCb.Value := CYCLE_SINGLE_AS_TOGGLE

    ; ── Window Switcher ───────────────────────────────────────────────────────
    hdrSwitcher := addHeader("Window Switcher")
    showPreviewCb := g.AddCheckbox("xm y+6 w500", "Show window preview beside popup")
    showPreviewCb.Value := SWITCHER_SHOW_PREVIEW

    g.AddText("xm y+6", "Preview side")
    previewSideChoices := ["Right", "Left"]
    previewSideKeys    := ["right", "left"]
    previewSideDefault := 1
    for i, k in previewSideKeys
        if k = SWITCHER_PREVIEW_SIDE
            previewSideDefault := i
    previewSideDropdown := g.AddDropDownList("x+6 yp w100 Choose" . previewSideDefault, previewSideChoices)
    previewSideDropdown.Enabled := SWITCHER_SHOW_PREVIEW

    g.AddText("xm y+8", "Preview size")
    previewSizeSlider := g.AddSlider("x+8 yp-4 w200 Range10-200 TickInterval10 NoTicks Line10 Page50", SWITCHER_PREVIEW_SIZE)
    previewSizeLbl    := g.AddText("x+8 yp+4 w40", SWITCHER_PREVIEW_SIZE "%")
    previewSizeSlider.Enabled := SWITCHER_SHOW_PREVIEW
    previewSizeSlider.OnEvent("Change", (*) => (
        previewSizeSlider.Value := Round(previewSizeSlider.Value / 10) * 10,
        previewSizeLbl.Value    := previewSizeSlider.Value "%"
    ))

    showPreviewCb.OnEvent("Click", (*) => (
        previewSideDropdown.Enabled := showPreviewCb.Value,
        previewSizeSlider.Enabled   := showPreviewCb.Value
    ))

    ; ── Appearance ────────────────────────────────────────────────────────────
    hdrAppearance := addHeader("Appearance")
    g.AddText("xm y+6", "Theme")
    themeChoices := ["Auto (follow system)", "Light", "Dark"]
    themeKeys    := ["auto", "light", "dark"]
    themeDefault := 1
    for i, k in themeKeys
        if k = THEME
            themeDefault := i
    themeDropdown := g.AddDropDownList("xm y+4 w200 Choose" . themeDefault, themeChoices)

    g.AddText("xm y+12")
    saveBtn := g.AddButton("xm Default w80", "Save")
    cancelBtn := g.AddButton("x+6 yp w80", "Cancel")
    cancelBtn.OnEvent("Click", CloseGui)
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
        newTheme             := themeKeys[themeDropdown.Value]
        newShowPreview       := showPreviewCb.Value
        newPreviewSide       := previewSideKeys[previewSideDropdown.Value]
        newPreviewSize       := previewSizeSlider.Value

        _WriteConfigFile(newChromiumExe, newChromiumUserdata, newFirefoxExe, newFirefoxProfileIni, newCycleSingle, newTheme, newShowPreview, newPreviewSide, newPreviewSize)

        pathsChanged := newChromiumExe       != origChromiumExe
                     || newChromiumUserdata  != origChromiumUserdata
                     || newFirefoxExe        != origFirefoxExe
                     || newFirefoxProfileIni != origFirefoxProfileIni
        if pathsChanged {
            CloseGui()
            Reload()
            return
        }
        global CYCLE_SINGLE_AS_TOGGLE  := newCycleSingle
        global THEME                   := newTheme
        global SWITCHER_SHOW_PREVIEW   := newShowPreview
        global SWITCHER_PREVIEW_SIDE   := newPreviewSide
        global SWITCHER_PREVIEW_SIZE   := newPreviewSize
        CloseGui()
    }

    g.Show("AutoSize")

    ; Capture browse-button width once (all four are the same size)
    browseChrExeBtn.GetPos(, , &_browseW)

    ResizeControls(gui, eventInfo, newW, newH) {
        margin  := 10
        gap     := 4
        editW   := Max(100, newW - 2*margin - gap - _browseW)
        browseX := margin + editW + gap
        fullW   := newW - 2*margin

        ; Path edit boxes stretch; browse buttons follow
        for e in [chromiumExeEdit, chromiumUserdataEdit, firefoxExeEdit, firefoxProfileIniEdit]
            e.Move(, , editW)
        for b in [browseChrExeBtn, browseChrDataBtn, browseFfExeBtn, browseFfProfileBtn]
            b.Move(browseX)

        ; Full-width controls
        for c in [hdrBrowser, hdrCycling, hdrSwitcher, hdrAppearance, cycleCb, showPreviewCb]
            c.Move(, , fullW)
    }
    g.OnEvent("Size", ResizeControls)

    ; Apply per-control dark/light theming after Show so HWNDs are valid
    for ctrl in [chromiumExeEdit, chromiumUserdataEdit, firefoxExeEdit, firefoxProfileIniEdit]
        _ThemeEdit(ctrl, isDark)
    _ThemeDropdown(themeDropdown,       isDark)
    _ThemeDropdown(previewSideDropdown, isDark)
    for ctrl in [saveBtn, cancelBtn, browseChrExeBtn, browseChrDataBtn, browseFfExeBtn, browseFfProfileBtn]
        _ThemeButton(ctrl, isDark)
    ; Dark title bar (Windows 10 20H1+ / Windows 11)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 20, "Int*", isDark ? 1 : 0, "UInt", 4)
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

; Shared control-theming helpers — call after Show so HWNDs are valid.
_ThemeEdit(ctrl, isDark) {
    static _allowDark := 0, _init := false
    if !_init {
        _init := true
        hMod := DllCall("GetModuleHandle", "Str", "uxtheme.dll", "Ptr")
        setPref := DllCall("GetProcAddress", "Ptr", hMod, "Ptr", 135, "Ptr")
        if setPref
            DllCall(setPref, "Int", 2, "Int")   ; ForceDark — enables AllowDarkModeForWindow
        _allowDark := DllCall("GetProcAddress", "Ptr", hMod, "Ptr", 133, "Ptr")
    }
    ; AllowDarkModeForWindow tells the system this control wants dark scrollbars.
    ; WM_THEMECHANGED sent to the control itself (not parent) triggers the re-theme.
    if _allowDark
        DllCall(_allowDark, "Ptr", ctrl.Hwnd, "Int", isDark ? 1 : 0, "Int")
    DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", isDark ? "DarkMode_Explorer" : "Explorer", "Ptr", 0)
    DllCall("SendMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x031A, "Ptr", 0, "Ptr", 0)
}
_ThemeDropdown(ctrl, isDark) {
    DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", isDark ? "DarkMode_CFD" : "CFD", "Ptr", 0)
}
_ThemeButton(ctrl, isDark) {
    DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", isDark ? "DarkMode_Explorer" : "Explorer", "Ptr", 0)
}

_WriteConfigFile(chromiumExe, chromiumUserdata, firefoxExe, firefoxProfileIni, cycleSingleAsToggle, theme := "auto", switcherShowPreview := true, switcherPreviewSide := "right", switcherPreviewSize := 100) {
    esc := (s) => StrReplace(StrReplace(s, "``", "````"), '"', '`"')
    content := '; config.ahk — AltTabSucks settings. Edit manually or use Ctrl+Alt+Shift+, to open the Settings UI.'
             . '`n; This file is gitignored.'
             . '`n`nglobal CHROMIUM_EXE        := "' esc(chromiumExe)        '"'
             . '`nglobal CHROMIUM_USERDATA   := "' esc(chromiumUserdata)   '"'
             . '`nglobal FIREFOX_EXE         := "' esc(firefoxExe)         '"'
             . '`nglobal FIREFOX_PROFILE_INI := "' esc(firefoxProfileIni)  '"'
             . '`n`nglobal CYCLE_SINGLE_AS_TOGGLE  := ' (cycleSingleAsToggle ? "true" : "false")
             . '`nglobal THEME                    := "' theme '"'
             . '`nglobal SWITCHER_SHOW_PREVIEW    := ' (switcherShowPreview ? "true" : "false")
             . '`nglobal SWITCHER_PREVIEW_SIDE    := "' switcherPreviewSide '"'
             . '`nglobal SWITCHER_PREVIEW_SIZE    := ' switcherPreviewSize
             . '`n'
    f := FileOpen(A_ScriptDir '\lib\config.ahk', 'w', 'UTF-8')
    f.Write(content)
    f.Close()
}

; --- Window typeahead switcher ---

_SwitcherIsDark() {
    global THEME
    if THEME = "dark"
        return true
    if THEME = "light"
        return false
    try {
        return RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0
    } catch {
        return false
    }
}

_RGBtoCOLORREF(rgb) {
    return ((rgb >> 16) & 0xFF) | (rgb & 0xFF00) | ((rgb & 0xFF) << 16)
}

_ApplySwitcherTheme(g, edit, lv, isDark) {
    bg     := isDark ? "1E1E1E" : "F5F5F5"
    editBg := isDark ? "2D2D2D" : "FFFFFF"
    fg     := isDark ? "EFEFEF" : "1A1A1A"
    bgRef  := _RGBtoCOLORREF(isDark ? 0x1E1E1E : 0xF5F5F5)
    fgRef  := _RGBtoCOLORREF(isDark ? 0xEFEFEF : 0x1A1A1A)

    g.BackColor := bg
    edit.Opt("+Background" . editBg)
    edit.SetFont("c" . fg)

    _ThemeEdit(edit, isDark)
    ; In dark mode, remove ListView theming so the system accent color (blue) is used for the
    ; selection highlight — DarkMode_Explorer's muted highlight is too close to the background.
    DllCall("uxtheme\SetWindowTheme", "Ptr", lv.Hwnd, "Str", isDark ? "" : "Explorer", "Ptr", 0)

    SendMessage(0x1001, 0, bgRef, lv)  ; LVM_SETBKCOLOR
    SendMessage(0x1024, 0, fgRef, lv)  ; LVM_SETTEXTCOLOR
    SendMessage(0x1026, 0, bgRef, lv)  ; LVM_SETTEXTBKCOLOR
    DllCall("InvalidateRect", "Ptr", lv.Hwnd, "Ptr", 0, "Int", 1)
}

_switcherGui         := 0
_switcherItems       := []
_switcherLV          := 0
_switcherEdit        := 0
_switcherCurrentRow  := 1
_switcherHeldMods    := []
_previewGui          := 0
_previewThumbnail    := 0

ShowWindowSwitcher(dir := "down") {
    global _switcherGui, _switcherItems, _switcherLV, _switcherEdit, _switcherCurrentRow
    static _msgHooked := false
    if !_msgHooked {
        OnMessage(0x0100, _SwitcherKeyHandler)   ; WM_KEYDOWN
        OnMessage(0x0101, _SwitcherKeyHandler)   ; WM_KEYUP
        OnMessage(0x0104, _SwitcherKeyHandler)   ; WM_SYSKEYDOWN — arrow keys while Alt held
        OnMessage(0x0105, _SwitcherKeyHandler)   ; WM_SYSKEYUP
        OnMessage(0x020A, _SwitcherKeyHandler)   ; WM_MOUSEWHEEL — scroll to cycle rows
        OnMessage(0x0006, _SwitcherWMActivate)   ; WM_ACTIVATE — close on defocus
        _msgHooked := true
    }
    if IsObject(_switcherGui) {
        if IsObject(_switcherLV) {
            count := _switcherLV.GetCount()
            if count > 0 {
                if dir = "up"
                    global _switcherCurrentRow := _switcherCurrentRow <= 1 ? count : _switcherCurrentRow - 1
                else
                    global _switcherCurrentRow := Mod(_switcherCurrentRow, count) + 1
                _switcherLV.Modify(0, "-Select")
                _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
                if SWITCHER_SHOW_PREVIEW
                    _SwitcherPreviewSchedule()
            }
        }
        return
    }
    global _switcherHeldMods := []
    for modKey in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
        if GetKeyState(modKey, "P")  ; physical state — reliable even if AHK has modified logical state
            _switcherHeldMods.Push(modKey)

    isDark := _SwitcherIsDark()

    g := Gui("+AlwaysOnTop -Caption +Border", "AltTabSucks_Switcher")
    g.SetFont("s12", "Segoe UI")
    g.MarginX := 10
    g.MarginY := 10
    _switcherGui := g

    edit := g.AddEdit("xm ym w500 h32")
    _switcherEdit := edit
    lv   := g.AddListView("xm y+6 w500 h20 -Hdr -Multi +0x8", ["App", "Title"])  ; +0x8 = LVS_SHOWSELALWAYS
    _switcherLV := lv

    _ApplySwitcherTheme(g, edit, lv, isDark)

    _SwitcherRefresh(edit, lv)

    ; Single GDI pass: measure exe name widths and row height before Show.
    ; LVM_GETITEMRECT height (bottom-top) is scroll-invariant even pre-Show, because
    ; _SwitcherRefresh's "Select Focus Vis" shifts item positions but not their heights.
    hdc   := DllCall("GetDC", "Ptr", lv.Hwnd, "Ptr")
    hFont := SendMessage(0x0031, 0, 0, lv)  ; WM_GETFONT
    DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont)
    maxExeW := 0
    for item in _switcherItems {
        if item.exeName = ""
            continue
        sz := Buffer(8, 0)
        DllCall("Gdi32\GetTextExtentPoint32W", "Ptr", hdc, "Str", item.exeName, "Int", StrLen(item.exeName), "Ptr", sz)
        w := NumGet(sz, 0, "Int")
        if w > maxExeW
            maxExeW := w
    }
    rc0  := Buffer(16, 0)
    SendMessage(0x100E, 0, rc0, lv)
    rowH := NumGet(rc0, 12, "Int") - NumGet(rc0, 4, "Int")  ; bottom - top; scroll-invariant
    if rowH <= 0 {  ; pre-Show fallback: derive from font metrics
        tm := Buffer(60, 0)
        DllCall("Gdi32\GetTextMetricsW", "Ptr", hdc, "Ptr", tm)
        rowH := NumGet(tm, 0, "Int") + 4  ; tmHeight + ListView internal padding
    }
    DllCall("ReleaseDC", "Ptr", lv.Hwnd, "Ptr", hdc)
    colExeW := Max(Min(maxExeW + 20, 200), 60)

    count   := lv.GetCount()
    lvH     := Min(Max(count, 1), 32) * rowH + (rowH / 2)

    ; ListView inner usable width (accounts for WS_EX_CLIENTEDGE border)
    cr := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", lv.Hwnd, "Ptr", cr)
    usableW := NumGet(cr, 8, "Int")
    if usableW <= 0
        usableW := 496  ; fallback: 500px control - 4px for CLIENTEDGE border
    if count > 32
        usableW -= DllCall("GetSystemMetrics", "Int", 2)  ; SM_CXVSCROLL

    lv.Move(,, , lvH)
    SendMessage(0x1013, 0, 0, lv)  ; LVM_ENSUREVISIBLE item 0 — clears scroll offset left by pre-show "Vis" selection
    lv.ModifyCol(1, colExeW)
    lv.ModifyCol(2, Max(usableW - colExeW, 50))

    edit.OnEvent("Change",    (*) => _SwitcherRefresh(edit, lv))
    lv.OnEvent("DoubleClick", (ctrl, row) => _SwitcherActivate(row))

    CloseSwitcher(*) {
        global _switcherGui, _switcherLV, _switcherEdit
        _switcherGui := 0
        _switcherLV   := 0
        _switcherEdit := 0
        _SwitcherPreviewClose()
    }
    g.OnEvent("Close", CloseSwitcher)

    ; Single show at exact computed client size — no post-show resize, no flash.
    ; clientH = marginY(10) + editH(32) + gap(6) + lvH + marginY(10)
    g.Show("w520 h" (58 + lvH) " Center")
    if !IsObject(_switcherGui)  ; WM_ACTIVATE may have fired during Show and destroyed the GUI
        return
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)  ; rounded corners (Win11)
    edit.Focus()
    ; If the trigger modifiers were released while the popup was loading, activate immediately.
    ; This covers the case where _switcherHeldMods is empty (released before the physical-state
    ; check above) or where the mods were released during _SwitcherRefresh.
    modsStillHeld := false
    for modKey in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
        if GetKeyState(modKey, "P") {
            modsStillHeld := true
            break
        }
    if !modsStillHeld {
        if IsObject(_switcherLV) && _switcherLV.GetCount() = 0
            _SwitcherClose()
        else
            _SwitcherActivate(_switcherCurrentRow ? _switcherCurrentRow : 1)
        return
    }
    if SWITCHER_SHOW_PREVIEW
        _SwitcherPreviewSchedule()
}

_SwitcherKeyHandler(vk, sc, msg, hwnd) {
    global _switcherGui, _switcherLV, _switcherEdit, _switcherCurrentRow
    global _switcherHeldMods
    if !IsObject(_switcherGui)
        return
    try {
        if DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") != _switcherGui.Hwnd
            return
    } catch {
        return
    }
    ; On key-up: decide what happens when all held modifiers are released.
    ; Activate as soon as all held modifiers are physically released.
    if msg = 0x0101 || msg = 0x0105 {
        isModifier := (vk = 0x10 || vk = 0x11 || vk = 0x12
                    || vk = 0x5B || vk = 0x5C
                    || (vk >= 0xA0 && vk <= 0xA5))
        if isModifier && _switcherHeldMods.Length > 0 {
            allReleased := true
            for mod in _switcherHeldMods
                if GetKeyState(mod, "P") {  ; "P" = physical state — ignores AHK's synthetic key-ups
                    allReleased := false
                    break
                }
            if allReleased {
                if IsObject(_switcherLV) && _switcherLV.GetCount() = 0
                    _SwitcherClose()
                else
                    _SwitcherActivate(_switcherCurrentRow ? _switcherCurrentRow : 1)
                return true
            }
        }
        return
    }
    if msg = 0x020A {  ; WM_MOUSEWHEEL — high word of wParam is signed delta; positive = up
        if IsObject(_switcherLV) {
            count    := _switcherLV.GetCount()
            scrollUp := ((vk >> 16) & 0xFFFF) < 0x8000
            if scrollUp
                global _switcherCurrentRow := _switcherCurrentRow <= 1 ? count : _switcherCurrentRow - 1
            else
                global _switcherCurrentRow := _switcherCurrentRow >= count ? 1 : _switcherCurrentRow + 1
            _switcherLV.Modify(0, "-Select")
            _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
            if SWITCHER_SHOW_PREVIEW
                _SwitcherPreviewSchedule()
        }
        return true
    }

    switch vk {
        case 0x09:  ; VK_TAB — navigate rows (Shift = up, bare = down)
            if IsObject(_switcherLV) {
                count := _switcherLV.GetCount()
                if GetKeyState("Shift")
                    global _switcherCurrentRow := _switcherCurrentRow <= 1 ? count : _switcherCurrentRow - 1
                else
                    global _switcherCurrentRow := _switcherCurrentRow >= count ? 1 : _switcherCurrentRow + 1
                _switcherLV.Modify(0, "-Select")
                _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
                if SWITCHER_SHOW_PREVIEW
                    _SwitcherPreviewSchedule()
            }
            return true
        default:
    }
    switch vk {
        case 0x20:  ; VK_SPACE — suppress when hotkey modifiers still held (cycling handled via hotkey re-fire)
            for mod in _switcherHeldMods
                if GetKeyState(mod, "P")
                    return true
        case 0x1B:  ; VK_ESCAPE
            _SwitcherClose()
            return true
        case 0x0D:  ; VK_RETURN
            _SwitcherActivate(_switcherCurrentRow ? _switcherCurrentRow : 1)
            return true
        case 0x26, 0xC0:  ; VK_UP, VK_OEM_3 (backtick) — navigate up
            if IsObject(_switcherLV) {
                count := _switcherLV.GetCount()
global _switcherCurrentRow := _switcherCurrentRow <= 1 ? count : _switcherCurrentRow - 1
                _switcherLV.Modify(0, "-Select")
                _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
                if SWITCHER_SHOW_PREVIEW
                    _SwitcherPreviewSchedule()
            }
            return true
        case 0x28:  ; VK_DOWN
            if IsObject(_switcherLV) {
                count := _switcherLV.GetCount()
global _switcherCurrentRow := _switcherCurrentRow >= count ? 1 : _switcherCurrentRow + 1
                _switcherLV.Modify(0, "-Select")
                _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
                if SWITCHER_SHOW_PREVIEW
                    _SwitcherPreviewSchedule()
            }
            return true
    }
    ; WM_SYSKEYDOWN + character key — translate to WM_CHAR and forward to the edit
    ; so typeahead works while Alt (or other nav modifier) is held.
    ; WM_SYSKEYDOWN + character/backspace key — insert into the typeahead edit.
    ; Only intercept VK ranges that produce printable text or backspace; let everything
    ; else (F-keys, Alt+F4, Alt+Space, etc.) reach DefWindowProc as normal.
    if msg = 0x0104 && IsObject(_switcherEdit) {
        isCharKey := (vk >= 0x30 && vk <= 0x39)   ; digits 0-9
                  || (vk >= 0x41 && vk <= 0x5A)   ; letters A-Z
                  || (vk >= 0xBA && vk <= 0xDF)   ; OEM punctuation keys
                  || vk = 0x08                    ; VK_BACK — backspace
        if isCharKey {
            kbState := Buffer(256, 0)
            DllCall("GetKeyboardState", "Ptr", kbState)
            ; Strip Alt bits — ToUnicodeEx returns the base character without Alt
            NumPut("UChar", NumGet(kbState, 0x12, "UChar") & 0x7F, kbState, 0x12)  ; VK_MENU
            NumPut("UChar", NumGet(kbState, 0xA4, "UChar") & 0x7F, kbState, 0xA4)  ; VK_LMENU
            NumPut("UChar", NumGet(kbState, 0xA5, "UChar") & 0x7F, kbState, 0xA5)  ; VK_RMENU
            charBuf := Buffer(16, 0)
            ; Scan code is in bits 16-23 of lParam (sc)
            n := DllCall("ToUnicodeEx", "UInt", vk, "UInt", (sc >> 16) & 0xFF,
                         "Ptr", kbState, "Ptr", charBuf, "Int", 8, "UInt", 0, "Ptr", 0, "Int")
            if vk = 0x08 {
                ; Backspace: ToUnicodeEx returns \x08 which EM_REPLACESEL inserts literally — use WM_CHAR instead
                SendMessage(0x0102, 0x08, sc, _switcherEdit)
            } else if n > 0 {
                charStr := StrGet(charBuf, n, "UTF-16")
                SendMessage(0x00C2, false, StrPtr(charStr), _switcherEdit)
            }
            _switcherEdit.Focus()
            ; Focus() on a previously-unfocused edit auto-selects all — clear that immediately
            ; so the next keypress appends rather than replacing.
            textLen := StrLen(_switcherEdit.Value)
            SendMessage(0x00B1, textLen, textLen, _switcherEdit)  ; EM_SETSEL: cursor to end, no selection
            return true  ; suppress the Alt+no-menu system beep
        }
    }
}

_SwitcherRefresh(edit, lv) {
    static _running := false
    if _running
        return
    _running := true
    global _switcherItems, _switcherGui, _switcherCurrentRow
    q := edit.Value
    _switcherItems := []
    lv.Delete()

    ; Pre-allocate buffers once — avoids a Buffer() allocation per window in the loop
    titleBuf   := Buffer(1024, 0)
    pathBuf    := Buffer(1040, 0)
    pathSize   := Buffer(4,    0)
    cloakedBuf := Buffer(4,    0)
    pidCache   := Map()  ; process name cache: avoids redundant OpenProcess per shared-process windows

    SendMessage(0x000B, 0, 0, lv)  ; WM_SETREDRAW false — batch all lv.Add calls

    ; GetTopWindow + GetWindow(GW_HWNDNEXT=2) guarantees Z-order (most-recently-active first)
    hwnd := DllCall("GetTopWindow", "Ptr", 0, "Ptr")
    while hwnd {
        nextHwnd := DllCall("GetWindow", "Ptr", hwnd, "UInt", 2, "Ptr")

        ; Skip the switcher itself
        if IsObject(_switcherGui) && hwnd = _switcherGui.Hwnd {
            hwnd := nextHwnd
            continue
        }

        ; Direct GetWindowLong calls — faster than WinGetStyle/WinGetExStyle (no AHK window-matching overhead)
        style := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -16, "Int")  ; GWL_STYLE
        if !(style & 0x10000000) {  ; WS_VISIBLE
            hwnd := nextHwnd
            continue
        }
        exStyle := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -20, "Int")  ; GWL_EXSTYLE
        if exStyle & 0x80 {  ; WS_EX_TOOLWINDOW — overlays, notification windows, etc.
            hwnd := nextHwnd
            continue
        }
        if DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") {  ; GW_OWNER — skip owned windows
            hwnd := nextHwnd
            continue
        }

        ; Skip cloaked windows (virtual desktop, UWP background, etc.)
        DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "Ptr", cloakedBuf, "UInt", 4)
        if NumGet(cloakedBuf, 0, "Int") {
            hwnd := nextHwnd
            continue
        }

        ; Title via direct GetWindowTextW — faster than WinGetTitle
        titleChars := DllCall("GetWindowTextW", "Ptr", hwnd, "Ptr", titleBuf, "Int", 511, "Int")
        if !titleChars {
            hwnd := nextHwnd
            continue
        }
        title := StrGet(titleBuf, titleChars)

        ; Process name — cached by PID so multi-window processes (browsers, etc.) only pay once
        pid := 0
        DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UIntP", &pid)
        if !pidCache.Has(pid) {
            hProc := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")  ; PROCESS_QUERY_LIMITED_INFORMATION
            if hProc {
                NumPut("UInt", 520, pathSize, 0)
                DllCall("QueryFullProcessImageNameW", "Ptr", hProc, "UInt", 0, "Ptr", pathBuf, "Ptr", pathSize)
                DllCall("CloseHandle", "Ptr", hProc)
                SplitPath(StrGet(pathBuf), &fname)
                pidCache[pid] := fname
            } else
                pidCache[pid] := ""
        }
        proc := pidCache[pid]
        if proc = "" {
            hwnd := nextHwnd
            continue
        }

        mini    := (style & 0x20000000) != 0  ; WS_MINIMIZE — faster than WinGetMinMax
        exeDisp := _SwitcherExeName(SubStr(proc, 1, -4))  ; strip .exe suffix

        if q = "" || _SwitcherMatch(exeDisp . " " . title, q) {
            _switcherItems.Push({hwnd: hwnd, minimized: mini, exeName: exeDisp, title: title})
            lv.Add("", exeDisp, title)
        }

        hwnd := nextHwnd
    }

    SendMessage(0x000B, 1, 0, lv)  ; WM_SETREDRAW true
    DllCall("InvalidateRect", "Ptr", lv.Hwnd, "Ptr", 0, "Int", 1)

    _switcherCurrentRow := (lv.GetCount() > 1 && q = "") ? 2 : 1
    if lv.GetCount() > 0
        lv.Modify(_switcherCurrentRow, "Select Focus Vis")
    if SWITCHER_SHOW_PREVIEW
        _SwitcherPreviewSchedule()
    _running := false
}

_SwitcherMatch(text, query) {
    return InStr(text, query, false)
}

_SwitcherExeName(exeName) {
    static aliases := Map(
        "steamwebhelper",       "Steam",
        "systemsettings",       "Settings",
        "applicationframehost", "Settings"          ; UWP host — title is already the app name
    )
    key := StrLower(exeName)
    return aliases.Has(key) ? aliases[key]
         : StrUpper(SubStr(exeName, 1, 1)) . SubStr(exeName, 2)
}

_SwitcherClose() {
    global _switcherGui, _switcherLV, _switcherEdit
    if !IsObject(_switcherGui)
        return
    gui := _switcherGui
    _switcherGui  := 0
    _switcherLV   := 0
    _switcherEdit := 0
    _SwitcherPreviewClose()
    gui.Destroy()
}

_SwitcherActivate(row) {
    global _switcherGui, _switcherItems, _switcherLV, _switcherEdit
    if row < 1 || row > _switcherItems.Length
        return
    item := _switcherItems[row]
    gui  := _switcherGui
    _switcherGui := 0   ; zero before Destroy so WM_ACTIVATE handler doesn't re-enter
    _switcherLV  := 0
    _SwitcherPreviewClose()
    if IsObject(gui)
        gui.Destroy()
    try {
        if item.minimized
            WinRestore("ahk_id " item.hwnd)
        WinActivate("ahk_id " item.hwnd)
    } catch {
    }
}

_SwitcherWMActivate(wParam, lParam, msg, hwnd) {
    global _switcherGui, _switcherLV, _switcherEdit, _switcherHeldMods
    if !IsObject(_switcherGui)
        return
    try {
        if hwnd != _switcherGui.Hwnd
            return
    } catch {
        return
    }
    if (wParam & 0xFFFF) = 0 {  ; WA_INACTIVE — window lost focus
        ; On Win10+ "scroll inactive windows" routes wheel events to the cursor's window,
        ; which can briefly activate it while nav mod keys are still held. Ignore in that case.
        for mod in _switcherHeldMods
            if GetKeyState(mod, "P")
                return
        _SwitcherClose()
    }
}

_SwitcherPreviewSchedule() {
    SetTimer(_SwitcherPreviewTimer, -30)
}

_SwitcherPreviewClose() {
    global _previewGui, _previewThumbnail
    if _previewThumbnail != 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", _previewThumbnail)
        _previewThumbnail := 0
    }
    if IsObject(_previewGui) {
        _previewGui.Destroy()
        _previewGui := 0
    }
}

_SwitcherPreviewTimer() {
    global _switcherGui, _switcherItems, _switcherCurrentRow
    global _previewGui, _previewThumbnail, SWITCHER_PREVIEW_SIDE, SWITCHER_PREVIEW_SIZE
    if !IsObject(_switcherGui)
        return
    switcherHwnd := _switcherGui.Hwnd  ; capture before anything that may pump messages
    try
        WinGetPos(&sx, &sy, &sw, &sh, "ahk_id " switcherHwnd)  ; grab position now, before DLL calls
    catch
        return
    if _switcherCurrentRow < 1 || _switcherCurrentRow > _switcherItems.Length
        return
    item := _switcherItems[_switcherCurrentRow]

    ; Unregister previous thumbnail before registering new one
    if _previewThumbnail != 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", _previewThumbnail)
        _previewThumbnail := 0
    }

    ; Create preview GUI lazily — only once
    if !IsObject(_previewGui) {
        isDark := _SwitcherIsDark()
        pg := Gui("+AlwaysOnTop -Caption +ToolWindow", "AltTabSucks_Preview")  ; +ToolWindow keeps it out of the switcher list
        pg.BackColor := isDark ? "1E1E1E" : "F5F5F5"
        _previewGui := pg
    }
    previewHwnd := _previewGui.Hwnd

    ; Register live DWM thumbnail (compositor renders it — zero CPU on our side)
    hThumb := 0
    if DllCall("dwmapi\DwmRegisterThumbnail", "Ptr", previewHwnd, "Ptr", item.hwnd, "Ptr*", &hThumb) != 0
        return
    _previewThumbnail := hThumb

    ; Query source size for aspect-correct scaling
    sz := Buffer(8, 0)
    DllCall("dwmapi\DwmQueryThumbnailSourceSize", "Ptr", hThumb, "Ptr", sz)
    srcW := NumGet(sz, 0, "Int")
    srcH := NumGet(sz, 4, "Int")

    maxW := Max(Round(640 * SWITCHER_PREVIEW_SIZE / 100), 64)
    maxH := Max(Round(400 * SWITCHER_PREVIEW_SIZE / 100), 40)
    if srcW > 0 && srcH > 0 {
        scale    := Min(maxW / srcW, maxH / srcH)
        previewW := Max(Round(srcW * scale), 80)
        previewH := Max(Round(srcH * scale), 60)
    } else {
        previewW := maxW
        previewH := maxH
    }

    ; Position beside switcher, vertically centred, clamped to primary monitor
    previewX := (SWITCHER_PREVIEW_SIDE = "left") ? sx - previewW - 12 : sx + sw + 12
    previewY := sy + (sh - previewH) // 2
    previewX := Max(0, Min(previewX, A_ScreenWidth  - previewW))
    previewY := Max(0, Min(previewY, A_ScreenHeight - previewH))

    _previewGui.Show("NA x" previewX " y" previewY " w" previewW " h" previewH)

    isDark := _SwitcherIsDark()
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", previewHwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", previewHwnd, "UInt", 20, "Int*", isDark ? 1 : 0, "UInt", 4)

    ; DWM_THUMBNAIL_PROPERTIES (48 bytes): dest rect fills the entire preview client area
    props := Buffer(48, 0)
    NumPut("UInt",  0xD,      props,  0)  ; dwFlags: TNP_RECTDESTINATION|TNP_OPACITY|TNP_VISIBLE
    NumPut("Int",   0,        props,  4)  ; rcDestination.left
    NumPut("Int",   0,        props,  8)  ; rcDestination.top
    NumPut("Int",   previewW, props, 12)  ; rcDestination.right
    NumPut("Int",   previewH, props, 16)  ; rcDestination.bottom
    NumPut("UChar", 255,      props, 36)  ; opacity
    NumPut("Int",   1,        props, 40)  ; fVisible
    DllCall("dwmapi\DwmUpdateThumbnailProperties", "Ptr", hThumb, "Ptr", props)
}
