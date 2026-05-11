; window-switcher-mouse.ahk — hover/click/× column, nav throttle, wheel hook

; Track cursor position over the × column and request WM_MOUSELEAVE via TrackMouseEvent.
_SwitcherMouseMove(wParam, lParam, msg, hwnd) {
    global _switcherGui, _switcherLV, _switcherHoveredCloseRow, _switcherMouseTracking
    if !IsObject(_switcherGui) || !IsObject(_switcherLV) || hwnd != _switcherLV.Hwnd
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if x > 0x7FFF
        x -= 0x10000
    if y > 0x7FFF
        y -= 0x10000
    hti := Buffer(24, 0)
    NumPut("Int", x, hti, 0)
    NumPut("Int", y, hti, 4)
    itemIdx := SendMessage(0x1039, 0, hti, _switcherLV)  ; LVM_SUBITEMHITTEST
    subitem  := NumGet(hti, 16, "Int")
    newHover := (itemIdx >= 0 && subitem = 2) ? itemIdx : -1
    if newHover != _switcherHoveredCloseRow {
        global _switcherHoveredCloseRow := newHover
        DllCall("InvalidateRect", "Ptr", _switcherLV.Hwnd, "Ptr", 0, "Int", 1)
    }
    if !_switcherMouseTracking {
        tme := Buffer(20, 0)
        NumPut("UInt", 20,                   tme,  0)  ; cbSize
        NumPut("UInt", 2,                    tme,  4)  ; TME_LEAVE
        NumPut("Ptr",  _switcherLV.Hwnd,     tme,  8)  ; hwndTrack
        DllCall("TrackMouseEvent", "Ptr", tme)
        global _switcherMouseTracking := true
    }
}

; Clear hover state when cursor exits the ListView.
_SwitcherMouseLeave(wParam, lParam, msg, hwnd) {
    global _switcherGui, _switcherLV, _switcherHoveredCloseRow, _switcherMouseTracking
    if !IsObject(_switcherGui) || !IsObject(_switcherLV) || hwnd != _switcherLV.Hwnd
        return
    global _switcherMouseTracking := false
    if _switcherHoveredCloseRow != -1 {
        global _switcherHoveredCloseRow := -1
        DllCall("InvalidateRect", "Ptr", _switcherLV.Hwnd, "Ptr", 0, "Int", 1)
    }
}

; Show a hand cursor when hovering the × column.
_SwitcherWMSetCursor(wParam, lParam, msg, hwnd) {
    global _switcherLV, _switcherHoveredCloseRow
    if !IsObject(_switcherLV) || hwnd != _switcherLV.Hwnd || _switcherHoveredCloseRow < 0
        return
    DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr"))  ; IDC_HAND
    return true
}

; NM_CUSTOMDRAW: paint the × cell with a red hover background when the cursor is over it.
; Uses CDRF_SKIPDEFAULT + explicit GDI so the fill beats the themed selection overlay on selected rows.
; Struct offsets (x64): NMHDR=24B; +24=dwDrawStage, +32=hdc, +40=rc(ltrb), +56=dwItemSpec, +88=iSubItem
_SwitcherWMNotify(wParam, lParam, msg, hwnd) {
    global _switcherGui, _switcherLV, _switcherHoveredCloseRow
    if !IsObject(_switcherGui) || !IsObject(_switcherLV) || _switcherHoveredCloseRow < 0
        return
    if hwnd != _switcherGui.Hwnd
        return
    if NumGet(lParam, 0, "Ptr") != _switcherLV.Hwnd  ; nmhdr.hwndFrom
        return
    if NumGet(lParam, 16, "Int") != -12               ; nmhdr.code != NM_CUSTOMDRAW
        return
    drawStage := NumGet(lParam, 24, "UInt")
    if drawStage = 0x00000001                          ; CDDS_PREPAINT
        return 0x00000020                              ; CDRF_NOTIFYITEMDRAW
    if drawStage = 0x00010001                          ; CDDS_ITEMPREPAINT
        return 0x00000020                              ; CDRF_NOTIFYSUBITEMDRAW
    if drawStage = 0x00030001 {                        ; CDDS_ITEMPREPAINT|CDDS_SUBITEM
        if NumGet(lParam, 88, "Int") != 2              ; iSubItem != × column
            return
        if NumGet(lParam, 56, "UPtr") != _switcherHoveredCloseRow  ; wrong row
            return
        ; Explicit GDI fill + text bypasses the Explorer theme's selection overlay
        ; that runs after CDRF_NEWFONT and would repaint the background on selected rows.
        hdc    := NumGet(lParam, 32, "Ptr")
        rc     := Buffer(16, 0)
        NumPut("Int", NumGet(lParam, 40, "Int"), rc,  0)   ; left
        NumPut("Int", NumGet(lParam, 44, "Int"), rc,  4)   ; top
        NumPut("Int", NumGet(lParam, 48, "Int"), rc,  8)   ; right
        NumPut("Int", NumGet(lParam, 52, "Int"), rc, 12)   ; bottom
        hBrush := DllCall("CreateSolidBrush", "UInt", 0x001C2BC4, "Ptr")  ; #C42B1C in BGR
        DllCall("FillRect",  "Ptr", hdc, "Ptr", rc, "Ptr", hBrush)
        DllCall("DeleteObject", "Ptr", hBrush)
        oldColor := DllCall("SetTextColor", "Ptr", hdc, "UInt", 0x00FFFFFF, "UInt")
        oldBk    := DllCall("SetBkMode",    "Ptr", hdc, "Int",  1,          "Int")   ; TRANSPARENT
        DllCall("DrawTextW", "Ptr", hdc, "Str", "×", "Int", 1, "Ptr", rc, "UInt", 0x25)  ; DT_SINGLELINE|DT_CENTER|DT_VCENTER
        DllCall("SetTextColor", "Ptr", hdc, "UInt", oldColor)
        DllCall("SetBkMode",    "Ptr", hdc, "Int",  oldBk)
        return 0x00000004                              ; CDRF_SKIPDEFAULT — we drew it, skip system render
    }
}

; Handle single click on the ListView: × column closes the window, other columns update row selection.
_SwitcherLVClick(ctrl, row) {
    global _switcherGui, _switcherItems, _switcherLV, _switcherEdit, _switcherCurrentRow
    if !IsObject(_switcherGui) || row < 1 || row > _switcherItems.Length
        return
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", ctrl.Hwnd, "Ptr", pt)
    hti := Buffer(24, 0)
    NumPut("Int", NumGet(pt, 0, "Int"), hti, 0)
    NumPut("Int", NumGet(pt, 4, "Int"), hti, 4)
    SendMessage(0x1039, 0, hti, ctrl)  ; LVM_SUBITEMHITTEST — fills iSubItem at offset 16
    if NumGet(hti, 16, "Int") = 2 {   ; column 2 (0-based) = "×"
        savedRow := _switcherCurrentRow
        WinClose("ahk_id " _switcherItems[row].hwnd)
        _SwitcherRefresh(_switcherEdit, _switcherLV)
        _SwitcherRestoreRow(savedRow)
    } else
        global _switcherCurrentRow := row
}

; ── Navigation burst protection ──────────────────────────────────────────────
; All navigation inputs (scroll, Tab, backtick, arrows) share this counter.
; After 50 rapid events, a 500 ms cooldown suppresses further navigation and
; prevents AHK's hotkey counter from reaching the warning threshold.

_SwitcherNavBurst() {
    static count       := 0
    static windowStart := 0
    global _switcherNavThrottled
    if _switcherNavThrottled
        return true
    now := A_TickCount
    if now - windowStart >= 2000 {
        count       := 0
        windowStart := now
    }
    count += 1
    if count >= 50 {
        count := 0
        _SwitcherNavThrottle()
        return true
    }
    return false
}

_SwitcherNavThrottle() {
    global _switcherNavThrottled
    if _switcherNavThrottled
        return
    _switcherNavThrottled := true
    SetTimer(_SwitcherNavUnthrottle, -500)
}

_SwitcherNavUnthrottle() {
    global _switcherNavThrottled
    _switcherNavThrottled := false
}

_SwitcherScroll(dir) {
    global _switcherLV, _switcherCurrentRow
    if _SwitcherNavBurst()
        return
    if !IsObject(_switcherLV)
        return
    count := _switcherLV.GetCount()
    if count < 1
        return
    if dir = "up"
        global _switcherCurrentRow := _switcherCurrentRow <= 1 ? count : _switcherCurrentRow - 1
    else
        global _switcherCurrentRow := _switcherCurrentRow >= count ? 1 : _switcherCurrentRow + 1
    _switcherLV.Modify(0, "-Select")
    _switcherLV.Modify(_switcherCurrentRow, "Select Focus Vis")
    if SWITCHER_SHOW_PREVIEW
        _SwitcherPreviewSchedule()
}

; ── Mouse wheel via low-level hook ───────────────────────────────────────────
; WH_MOUSE_LL intercepts every wheel event system-wide and posts a plain WM_APP
; message to the switcher window.  OnMessage receives it — no hotkey is ever fired,
; so AHK's hotkey counter cannot reach the warning threshold regardless of speed.

_SwitcherMouseHookInstall() {
    global _mouseHookHandle, _mouseHookCb
    if _mouseHookHandle  ; already installed
        return
    if !_mouseHookCb
        _mouseHookCb := CallbackCreate(_SwitcherMouseHookProc, "Fast", 3)
    _mouseHookHandle := DllCall("SetWindowsHookExW", "Int", 14,   ; WH_MOUSE_LL
                                 "Ptr", _mouseHookCb, "Ptr", 0, "UInt", 0, "Ptr")
}

_SwitcherMouseHookRemove() {
    global _mouseHookHandle
    if _mouseHookHandle {
        DllCall("UnhookWindowsHookEx", "Ptr", _mouseHookHandle)
        _mouseHookHandle := 0
    }
}

; Fast callback — runs in the hook thread.  Only reads simple globals and calls
; WinAPI; must not call any AHK function that touches the script's state.
_SwitcherMouseHookProc(nCode, wParam, lParam) {
    global _switcherHwnd
    if nCode >= 0 && wParam = 0x020A && _switcherHwnd {
        ; MSLLHOOKSTRUCT: pt(8) + mouseData(4).  High word of mouseData = signed wheel delta.
        highWord := (NumGet(lParam + 8, "UInt") >> 16) & 0xFFFF
        DllCall("PostMessage", "Ptr", _switcherHwnd, "UInt", 0x8001, "UPtr", highWord, "Ptr", 0)
        return 1  ; consume — prevent OS "3 lines per notch" from applying
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; OnMessage handler for raw wheel deltas posted by the low-level mouse hook.
; Accumulates fractional deltas so smooth-scroll mice still move one row per notch.
_SwitcherWheelMsg(wParam, lParam, msg, hwnd) {
    static accum := 0
    if !IsObject(_switcherGui) {
        accum := 0
        return
    }
    ; wParam is the unsigned high-word of mouseData; convert to signed delta
    delta := (wParam & 0xFFFF) >= 0x8000 ? (wParam & 0xFFFF) - 0x10000 : (wParam & 0xFFFF)
    accum += delta
    if Abs(accum) >= 120 {
        _SwitcherScroll(accum > 0 ? "up" : "down")
        accum := 0
    }
}
