; window-switcher-preview.ahk — single DWM thumbnail preview and carousel dispatch

; WM_LBUTTONDOWN on the preview or carousel — both windows have WS_EX_NOACTIVATE so clicking
; them doesn't steal focus from the switcher, keeping _switcherCurrentRow and _carouselGui valid.
_SwitcherPreviewClick(wParam, lParam, msg, hwnd) {
    global _previewGui, _carouselGui, _carouselSlots, _switcherItems, _switcherCurrentRow
    global _gridTopGui, _gridBotGui
    if IsObject(_previewGui) && hwnd = _previewGui.Hwnd {
        _SwitcherActivate(_switcherCurrentRow)
        return
    }
    if (IsObject(_gridTopGui) && hwnd = _gridTopGui.Hwnd)
    || (IsObject(_gridBotGui) && hwnd = _gridBotGui.Hwnd) {
        _SwitcherGridClickAt(hwnd, lParam)
        return
    }
    if IsObject(_carouselGui) && hwnd = _carouselGui.Hwnd {
        x := lParam & 0xFFFF
        y := (lParam >> 16) & 0xFFFF
        if x > 0x7FFF
            x -= 0x10000
        if y > 0x7FFF
            y -= 0x10000
        for thumb in _carouselSlots {
            if thumb.removing
                continue
            if x >= Round(thumb.cL) && x <= Round(thumb.cR) && y >= Round(thumb.cT) && y <= Round(thumb.cB) {
                loop _switcherItems.Length {
                    if _switcherItems[A_Index].hwnd = thumb.srcHwnd {
                        _SwitcherActivate(A_Index)
                        return
                    }
                }
            }
        }
    }
}

_SwitcherPreviewSchedule() {
    if SWITCHER_CAROUSEL
        SetTimer(_SwitcherCarouselUpdate, -30)
    else if SWITCHER_GRID_PREVIEW
        SetTimer(_SwitcherGridUpdate, -30)
    else
        SetTimer(_SwitcherPreviewTimer, -30)
}

_SwitcherPreviewClose() {
    global _previewGui, _previewThumbnail
    SetTimer(_SwitcherPreviewTimer, 0)  ; cancel any pending single-preview timer
    if _previewThumbnail != 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", _previewThumbnail)
        _previewThumbnail := 0
    }
    if IsObject(_previewGui) {
        _previewGui.Destroy()
        _previewGui := 0
    }
    _SwitcherCarouselClose()
    _SwitcherGridClose()
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
        ; WS_EX_NOACTIVATE: clicking the preview doesn't steal focus from the switcher,
        ; so the OnMessage WM_LBUTTONDOWN handler can activate the correct window.
        WinSetExStyle("+0x08000000", "ahk_id " pg.Hwnd)
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
