; window-switcher.ahk - Window typeahead switcher

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