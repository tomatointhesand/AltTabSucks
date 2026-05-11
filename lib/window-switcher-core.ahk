; window-switcher-core.ahk — theme helpers, globals, main GUI, keyboard, refresh, close/activate

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
_previewGui              := 0
_previewThumbnail        := 0
_switcherHoveredCloseRow := -1  ; 0-based item index of × cell under cursor, or -1
_switcherMouseTracking   := false
_switcherPersistent      := false  ; true when opened via Ctrl+Alt+Tab (stays open after key release)
_switcherNavThrottled    := false  ; true during burst-protection cooldown
_switcherHwnd            := 0     ; plain HWND int, readable from Fast hook callback
_mouseHookHandle         := 0
_mouseHookCb             := 0
_carouselGui             := 0
_carouselSlots           := []     ; array of {hThumb,srcHwnd,fresh,cL,cT,cR,cB,cOp,tL,tT,tR,tB,tOp}
_carouselAnimOn          := false

ShowWindowSwitcher(dir := "down", persistent := false) {
    global _switcherGui, _switcherItems, _switcherLV, _switcherEdit, _switcherCurrentRow, _switcherPersistent
    static _msgHooked := false
    if !_msgHooked {
        OnMessage(0x0100, _SwitcherKeyHandler)   ; WM_KEYDOWN
        OnMessage(0x0101, _SwitcherKeyHandler)   ; WM_KEYUP
        OnMessage(0x0104, _SwitcherKeyHandler)   ; WM_SYSKEYDOWN — arrow keys while Alt held
        OnMessage(0x0105, _SwitcherKeyHandler)   ; WM_SYSKEYUP
        OnMessage(0x0006, _SwitcherWMActivate)   ; WM_ACTIVATE — close on defocus
        OnMessage(0x0200, _SwitcherMouseMove)    ; WM_MOUSEMOVE — × column hover tracking
        OnMessage(0x02A3, _SwitcherMouseLeave)   ; WM_MOUSELEAVE — clear hover on exit
        OnMessage(0x0020, _SwitcherWMSetCursor)  ; WM_SETCURSOR — hand cursor over ×
        OnMessage(0x004E, _SwitcherWMNotify)     ; WM_NOTIFY — NM_CUSTOMDRAW for × highlight
        OnMessage(0x8001, _SwitcherWheelMsg)     ; WM_APP+1 — raw wheel delta (posted by mouse hook)
        OnMessage(0x0201, _SwitcherPreviewClick) ; WM_LBUTTONDOWN — click preview/carousel to activate
        _msgHooked := true
    }
    if IsObject(_switcherGui) {
        if persistent {
            global _switcherPersistent := true  ; upgrade a held-key session to persistent
            return
        }
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
    global _switcherPersistent := persistent

    isDark := _SwitcherIsDark()

    g := Gui("+AlwaysOnTop -Caption +Border", "AltTabSucks_Switcher")
    g.SetFont("s12", "Segoe UI")
    g.MarginX := 10
    g.MarginY := 10
    _switcherGui := g

    hintH       := 0
    hint        := 0
    dontShowBtn := 0
    if SWITCHER_SHOW_HINTS {
        hintColor := isDark ? "707070" : "909090"
        g.SetFont("s9 c" hintColor, "Segoe UI")
        hint := g.AddText("xm ym w534 h20", "Tab/Backtick, ↑/↓: navigate  •  Enter / Release Alt: switch  •  End: close selected window  •  Esc: dismiss")
        g.SetFont("s9", "Segoe UI")
        dontShowBtn := g.AddButton("x+6 yp w80 h20", "Hide hints")
        g.SetFont("s12", "Segoe UI")
        edit := g.AddEdit("xm y+4 w620 h32")
        hintH := 24

        DontShowHints(*) {
            global SWITCHER_SHOW_HINTS
            SWITCHER_SHOW_HINTS := false
            _PersistConfig()
            hint.Visible     := false
            dontShowBtn.Visible := false
            edit.Move(, 10)
            lv.GetPos(, &ly)
            lv.Move(, ly - 24)
            g.GetPos(, , , &gh)
            g.Move(, , , gh - 24)
        }
        dontShowBtn.OnEvent("Click", DontShowHints)
    } else
        edit := g.AddEdit("xm ym w620 h32")
    _switcherEdit := edit
    lv   := g.AddListView("xm y+6 w620 h20 -Hdr -Multi +0x8", ["App", "Title", ""])  ; +0x8 = LVS_SHOWSELALWAYS
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
        usableW := 616  ; fallback: 620px control - 4px for CLIENTEDGE border
    if count > 32
        usableW -= DllCall("GetSystemMetrics", "Int", 2)  ; SM_CXVSCROLL

    lv.Move(,, , lvH)
    SendMessage(0x1013, 0, 0, lv)  ; LVM_ENSUREVISIBLE item 0 — clears scroll offset left by pre-show "Vis" selection
    closeColW := 30
    lv.ModifyCol(1, colExeW)
    lv.ModifyCol(2, Max(usableW - colExeW - closeColW, 50))
    lv.ModifyCol(3, "Center " . closeColW)

    edit.OnEvent("Change",    (*) => _SwitcherRefresh(edit, lv))
    lv.OnEvent("DoubleClick", (ctrl, row) => _SwitcherActivate(row))
    lv.OnEvent("Click",       _SwitcherLVClick)

    CloseSwitcher(*) {
        global _switcherGui, _switcherLV, _switcherEdit
        _switcherGui := 0
        _switcherLV   := 0
        _switcherEdit := 0
        _SwitcherPreviewClose()
    }
    g.OnEvent("Close", CloseSwitcher)

    ; Single show at exact computed client size — no post-show resize, no flash.
    ; clientH = marginY(10) + [hintH(20)+gap(4) when hints on] + editH(32) + gap(6) + lvH + marginY(10)
    g.Show("w640 h" (58 + hintH + lvH) " Center")
    if !IsObject(_switcherGui)  ; WM_ACTIVATE may have fired during Show and destroyed the GUI
        return
    global _switcherHwnd := g.Hwnd
    _SwitcherMouseHookInstall()
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)  ; rounded corners (Win11)
    if IsObject(dontShowBtn) && isDark
        _ThemeButton(dontShowBtn, true)
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
    if !modsStillHeld && !_switcherPersistent {
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
    global _switcherGui, _switcherLV, _switcherEdit, _switcherCurrentRow, _switcherItems
    global _switcherHeldMods, _switcherPersistent
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
                if !_switcherPersistent {
                    if IsObject(_switcherLV) && _switcherLV.GetCount() = 0
                        _SwitcherClose()
                    else
                        _SwitcherActivate(_switcherCurrentRow ? _switcherCurrentRow : 1)
                }
                return true
            }
        }
        return
    }
    switch vk {
        case 0x09:  ; VK_TAB — navigate rows (Shift = up, bare = down)
            if _SwitcherNavBurst()
                return true
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
            if _SwitcherNavBurst()
                return true
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
            if _SwitcherNavBurst()
                return true
            if IsObject(_switcherLV) {
                count := _switcherLV.GetCount()
                global _switcherCurrentRow := _switcherCurrentRow >= count ? 1 : _switcherCurrentRow + 1
                _switcherLV.Modify(0, "-Select")
                _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
                if SWITCHER_SHOW_PREVIEW
                    _SwitcherPreviewSchedule()
            }
            return true
        case 0x23:  ; VK_END — close selected window (Alt+End, or bare End in persistent mode)
            if msg != 0x0104 && !_switcherPersistent
                return
            if IsObject(_switcherLV) && _switcherCurrentRow >= 1 && _switcherCurrentRow <= _switcherItems.Length {
                item    := _switcherItems[_switcherCurrentRow]
                savedRow := _switcherCurrentRow
                WinClose("ahk_id " item.hwnd)
                _SwitcherRefresh(_switcherEdit, _switcherLV)
                _SwitcherRestoreRow(savedRow)
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
            lv.Add("", exeDisp, title, "×")
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
    global _switcherGui, _switcherLV, _switcherEdit, _switcherHoveredCloseRow, _switcherMouseTracking, _switcherPersistent, _switcherHwnd
    if !IsObject(_switcherGui)
        return
    gui := _switcherGui
    _switcherGui             := 0
    _switcherLV              := 0
    _switcherEdit            := 0
    _switcherHoveredCloseRow := -1
    _switcherMouseTracking   := false
    _switcherPersistent      := false
    _switcherHwnd            := 0
    _SwitcherMouseHookRemove()
    SetTimer(_SwitcherNavUnthrottle, 0)
    _SwitcherNavUnthrottle()
    _SwitcherPreviewClose()
    gui.Destroy()
}

_SwitcherActivate(row) {
    global _switcherGui, _switcherItems, _switcherLV, _switcherEdit, _switcherHoveredCloseRow, _switcherMouseTracking, _switcherPersistent, _switcherHwnd
    if row < 1 || row > _switcherItems.Length
        return
    item := _switcherItems[row]
    gui  := _switcherGui
    _switcherGui             := 0   ; zero before Destroy so WM_ACTIVATE handler doesn't re-enter
    _switcherLV              := 0
    _switcherHoveredCloseRow := -1
    _switcherMouseTracking   := false
    _switcherPersistent      := false
    _switcherHwnd            := 0
    _SwitcherMouseHookRemove()
    SetTimer(_SwitcherNavUnthrottle, 0)
    _SwitcherNavUnthrottle()
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
    global _switcherGui, _switcherLV, _switcherEdit, _switcherHeldMods, _previewGui, _carouselGui
    if !IsObject(_switcherGui)
        return
    try {
        if hwnd != _switcherGui.Hwnd
            return
    } catch {
        return
    }
    if (wParam & 0xFFFF) = 0 {  ; WA_INACTIVE — window lost focus
        ; lParam is the HWND of the window gaining focus.
        ; Never close when focus goes to our own preview/carousel overlay windows.
        if IsObject(_previewGui) && lParam = _previewGui.Hwnd
            return
        if IsObject(_carouselGui) && lParam = _carouselGui.Hwnd
            return
        ; Close immediately on an explicit click to an external window.
        ; Scroll-inactive-windows briefly steals focus mid-scroll with no button pressed — ignore that.
        if GetKeyState("LButton", "P") || GetKeyState("RButton", "P") {
            _SwitcherClose()
            return
        }
        for mod in _switcherHeldMods
            if GetKeyState(mod, "P")
                return
        _SwitcherClose()
    }
}

; After closing a window and refreshing, restore selection to the same row (clamped).
_SwitcherRestoreRow(savedRow) {
    global _switcherLV, _switcherCurrentRow
    if !IsObject(_switcherLV)
        return
    count := _switcherLV.GetCount()
    if count < 1
        return
    targetRow := Min(savedRow, count)
    global _switcherCurrentRow := targetRow
    _switcherLV.Modify(0, "-Select")
    _switcherLV.Modify(targetRow, "Select Focus Vis")
    if SWITCHER_SHOW_PREVIEW
        _SwitcherPreviewSchedule()
}

; Ctrl+Alt+Tab — open the switcher in persistent mode (stays open after keys are released).
^!Tab::ShowWindowSwitcher("down", true)
^!+Tab::ShowWindowSwitcher("up", true)

#HotIf IsObject(_switcherGui)
!Escape::_SwitcherClose()
#HotIf

; Wheel scrolling is handled via a WH_MOUSE_LL hook (see _SwitcherMouseHookInstall)
; that posts WM_APP+1 messages instead of firing hotkeys, so AHK's hotkey
; counter is never involved and the "too many hotkeys" dialog cannot appear.
