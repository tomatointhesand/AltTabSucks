; settings.ahk - Settings GUI

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

    ; ── Window Cycling ───────────────────────────────────────────────────────
    hdrCycling := addHeader("Window Cycling")
    cycleCb := g.AddCheckbox("xm y+6 w500", "Cycle mode falls back to toggle when app has only one window")
    cycleCb.Value := CYCLE_SINGLE_AS_TOGGLE

    ; ── Window Switcher ───────────────────────────────────────────────────────
    hdrSwitcher := addHeader("Window Switcher")

    ; Determine current mode from globals
    previewMode := !SWITCHER_SHOW_PREVIEW ? 1
                 : SWITCHER_GRID_PREVIEW  ? 3
                 : 2

    g.AddText("xm y+6", "Preview mode")

    ; All four radios must be added consecutively with no other controls between
    ; them — any intervening control with WS_GROUP (e.g. a DropDownList) splits
    ; the group and lets multiple radios be selected at once.
    radioNone   := g.AddRadio("xm y+4 +Group w140", "None")
    radioSingle := g.AddRadio("xm y+6 w140", "Single")
    radioGrid   := g.AddRadio("xm y+6 w140", "Grid")

    ; Grab each radio's y-coord so sub-controls can be placed on the same row.
    radioNone.GetPos(&rnX)
    radioSingle.GetPos(, &rsY)
    radioGrid.GetPos(, &rgY, , &rgH)
    subX := rnX + 140 + 8  ; right edge of radio column + gap

    ; ── Single sub-controls ───────────────────────────────────────────────────
    previewSideChoices := ["Right", "Left"]
    previewSideKeys    := ["right", "left"]
    previewSideDefault := 1
    for i, k in previewSideKeys
        if k = SWITCHER_PREVIEW_SIDE
            previewSideDefault := i
    g.AddText("x" subX " y" (rsY + 3), "Side")
    previewSideDropdown := g.AddDropDownList("x+4 yp-3 w80 Choose" . previewSideDefault, previewSideChoices)
    g.AddText("x+10 yp+3", "Size")
    previewSizeSlider := g.AddSlider("x+6 yp-4 w160 Range10-200 TickInterval10 NoTicks Line10 Page50", SWITCHER_PREVIEW_SIZE)
    previewSizeLbl    := g.AddText("x+6 yp+4 w36", SWITCHER_PREVIEW_SIZE "%")
    previewSizeSlider.OnEvent("Change", (*) => (
        previewSizeSlider.Value := Round(previewSizeSlider.Value / 10) * 10,
        previewSizeLbl.Value    := previewSizeSlider.Value "%"
    ))

    ; (Grid has no sub-controls — layout is fully automatic)

    ; ── Radio state ───────────────────────────────────────────────────────────
    radioNone.Value   := (previewMode = 1)
    radioSingle.Value := (previewMode = 2)
    radioGrid.Value   := (previewMode = 3)

    UpdatePreviewState(*) {
        isSingle := radioSingle.Value
        previewSideDropdown.Enabled := isSingle
        previewSizeSlider.Enabled   := isSingle
    }
    UpdatePreviewState()
    for r in [radioNone, radioSingle, radioGrid]
        r.OnEvent("Click", UpdatePreviewState)

    showHintsCb := g.AddCheckbox("xm y" (rgY + rgH + 8) " w500", "Show keyboard hint bar in window switcher popup")
    showHintsCb.Value := SWITCHER_SHOW_HINTS

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
        newShowPreview := !radioNone.Value
        newShowGrid    := radioGrid.Value
        newPreviewSide := previewSideKeys[previewSideDropdown.Value]
        newPreviewSize := previewSizeSlider.Value
        newShowHints   := showHintsCb.Value

        _WriteConfigFile(newChromiumExe, newChromiumUserdata, newFirefoxExe, newFirefoxProfileIni, newCycleSingle, newTheme, newShowPreview, newPreviewSide, newPreviewSize, newShowHints, newShowGrid)

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
        global SWITCHER_SHOW_HINTS     := newShowHints
        global SWITCHER_GRID_PREVIEW := newShowGrid
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
        for c in [hdrBrowser, hdrCycling, hdrSwitcher, hdrAppearance, cycleCb, showHintsCb]
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

_WriteConfigFile(chromiumExe, chromiumUserdata, firefoxExe, firefoxProfileIni, cycleSingleAsToggle, theme := "auto", switcherShowPreview := true, switcherPreviewSide := "right", switcherPreviewSize := 100, switcherShowHints := true, switcherGridPreview := false) {
    esc := (s) => StrReplace(StrReplace(s, "``", "````"), '"', '`"')
    content := '; config.ahk — AltTabSucks settings. Edit manually or use Ctrl+Alt+Shift+, to open the Settings UI.' . '`n'
             . '; This file is gitignored.' . '`n'
             . '`nglobal CHROMIUM_EXE        := "' . esc(chromiumExe)       . '"'
             . '`nglobal CHROMIUM_USERDATA   := "' . esc(chromiumUserdata)  . '"'
             . '`nglobal FIREFOX_EXE         := "' . esc(firefoxExe)        . '"'
             . '`nglobal FIREFOX_PROFILE_INI := "' . esc(firefoxProfileIni) . '"'
             . '`n`nglobal CYCLE_SINGLE_AS_TOGGLE  := ' . (cycleSingleAsToggle ? "true" : "false")
             . '`nglobal THEME                    := "' . theme . '"'
             . '`nglobal SWITCHER_SHOW_PREVIEW    := ' . (switcherShowPreview ? "true" : "false")
             . '`nglobal SWITCHER_PREVIEW_SIDE    := "' . switcherPreviewSide . '"'
             . '`nglobal SWITCHER_PREVIEW_SIZE    := ' . switcherPreviewSize
             . '`nglobal SWITCHER_SHOW_HINTS      := ' . (switcherShowHints ? "true" : "false")
             . '`nglobal SWITCHER_GRID_PREVIEW := ' . (switcherGridPreview ? "true" : "false")
             . '`n'
    f := FileOpen(A_ScriptDir '\lib\config.ahk', 'w', 'UTF-8')
    f.Write(content)
    f.Close()
}

_PersistConfig() {
    global CHROMIUM_EXE, CHROMIUM_USERDATA, FIREFOX_EXE, FIREFOX_PROFILE_INI
    global CYCLE_SINGLE_AS_TOGGLE, THEME, SWITCHER_SHOW_PREVIEW, SWITCHER_PREVIEW_SIDE, SWITCHER_PREVIEW_SIZE
    global SWITCHER_SHOW_HINTS, SWITCHER_GRID_PREVIEW
    _WriteConfigFile(CHROMIUM_EXE, CHROMIUM_USERDATA, FIREFOX_EXE, FIREFOX_PROFILE_INI,
                     CYCLE_SINGLE_AS_TOGGLE, THEME, SWITCHER_SHOW_PREVIEW, SWITCHER_PREVIEW_SIDE,
                     SWITCHER_PREVIEW_SIZE, SWITCHER_SHOW_HINTS, SWITCHER_GRID_PREVIEW)
}