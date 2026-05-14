; window-switcher-grid.ahk — top+bottom flow grid of live DWM thumbnail previews
;
; Layout rules:
;   • Each thumbnail is at least 1/4 of the combined usable vertical space tall
;     (so at most 4 rows total across both canvases).
;   • Thumbnail WIDTH is derived from the actual window aspect ratio so there is
;     no distortion — each preview is the shape of the real window.
;   • Rows are packed greedily left-to-right and centred within the canvas.
;   • Rows fill above the switcher first; any overflow spills below.

_gridTopGui     := 0
_gridBotGui     := 0
_gridRingGui    := 0
_gridRingInner  := 0
_gridRingInnerW := 0
_gridRingInnerH := 0
_gridSlots      := []   ; [{hwnd, hThumb, screenX, screenY, w, h, totalH}]
_gridThumbH     := 0    ; uniform row height (widths vary per aspect ratio)
_gridHoverSX    := -99999   ; last processed hover screen-X (skip synthetic WM_MOUSEMOVE)
_gridHoverSY    := -99999

; ── layout helpers ────────────────────────────────────────────────────────────

; Count greedy-packed rows needed for the given thumbnail height.
_GridCountRows(thumbH, aspects, maxW, gap) {
    rows := 1
    rowW := 0
    for asp in aspects {
        w := Round(thumbH * asp)
        if rowW > 0 && rowW + gap + w > maxW {
            rows++
            rowW := w
        } else
            rowW += (rowW > 0 ? gap : 0) + w
    }
    return rows
}

; Build a flat array of {x, y, w, h} slots using a greedy row-packing flow.
; Each row is horizontally centred within maxW.
_GridFlowLayout(thumbH, rowH, aspects, maxW, gap, &outSlots) {
    outSlots := []
    ; Pass 1 – assign windows to rows
    rows := []
    cur  := []
    curW := 0
    for asp in aspects {
        w := Round(thumbH * asp)
        if curW > 0 && curW + gap + w > maxW {
            rows.Push(cur)
            cur  := [{w: w}]
            curW := w
        } else {
            cur.Push({w: w})
            curW += (curW > 0 ? gap : 0) + w
        }
    }
    if cur.Length > 0
        rows.Push(cur)

    ; Pass 2 – compute screen-relative positions, centring each row
    y := 0
    for row in rows {
        totalW := 0
        for cell in row
            totalW += cell.w
        totalW += (row.Length - 1) * gap
        x := (maxW - totalW) // 2   ; centre
        for cell in row {
            outSlots.Push({x: x, y: y, w: cell.w, h: thumbH})
            x += cell.w + gap
        }
        y += rowH
    }
}

; ── main update ───────────────────────────────────────────────────────────────

_SwitcherGridUpdate() {
    global _switcherGui, _switcherItems, _switcherCurrentRow
    global _gridTopGui, _gridBotGui, _gridRingGui, _gridSlots, _gridThumbH
    global _gridRingInner, _gridRingInnerW, _gridRingInnerH

    if !IsObject(_switcherGui) {
        _SwitcherGridClose()
        return
    }
    count := _switcherItems.Length
    if count = 0 {
        _SwitcherGridClose()
        return
    }

    ; ── work area (primary monitor, excludes taskbar) ─────────────────────────
    MonitorGetWorkArea(MonitorGetPrimary(), &waLeft, &waTop, &waRight, &waBottom)
    waW := waRight - waLeft

    ; ── switcher position ─────────────────────────────────────────────────────
    try
        WinGetPos(&sgX, &sgY, &sgW, &sgH, "ahk_id " _switcherGui.Hwnd)
    catch
        return

    ; ── constants ─────────────────────────────────────────────────────────────
    gap        := 8
    rowGap     := 8
    labelGap   := 4    ; gap between thumbnail bottom and title text
    labelH     := 18   ; height of one-line title label (s9 Segoe UI)
    margin     := 16
    maxW       := waW - 2 * margin          ; full work-area width with small side margin
    availTop   := Max(0, sgY - waTop - margin)
    availBot   := Max(0, waBottom - (sgY + sgH) - margin)
    totalAvail := availTop + availBot

    ; ── aspect ratios from live window sizes ──────────────────────────────────
    aspects := []
    rc := Buffer(16, 0)
    for item in _switcherItems {
        DllCall("GetWindowRect", "Ptr", item.hwnd, "Ptr", rc)
        w := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int")
        h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
        aspects.Push((w > 0 && h > 0) ? (w / h) : (16/9))
    }

    ; ── binary-search for the largest thumbH that fits in available space ────────
    ; At each candidate height: compute how many rows fit above (maxRT) and below
    ; (maxRB) the switcher, then check whether the flow layout needs no more than
    ; maxRT + maxRB rows.  This naturally grows thumbnails as windows are closed.
    lo := 60
    hi := Max(availTop, availBot, 60)
    loop 20 {
        mid  := (lo + hi + 1) // 2
        rH   := mid + labelGap + labelH + rowGap
        maxRT := Max(0, (availTop + rowGap) // rH)
        maxRB := Max(0, (availBot + rowGap) // rH)
        if _GridCountRows(mid, aspects, maxW, gap) <= maxRT + maxRB
            lo := mid
        else
            hi := mid - 1
        if hi <= lo
            break
    }
    thumbH := lo

    ; ── quick path: items and height unchanged — only move the ring ───────────
    if _SwitcherGridItemsMatch(thumbH) {
        _SwitcherGridRingShow()
        return
    }

    ; ── full rebuild ──────────────────────────────────────────────────────────
    for slot in _gridSlots
        if slot.hThumb != 0
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", slot.hThumb)
    global _gridSlots  := []
    global _gridThumbH := thumbH

    ; Destroy old canvases so stale label controls don't accumulate across rebuilds
    if IsObject(_gridTopGui) {
        _gridTopGui.Destroy()
        _gridTopGui := 0
    }
    if IsObject(_gridBotGui) {
        _gridBotGui.Destroy()
        _gridBotGui := 0
    }

    ; Full row height = thumbnail + label gap + label + gap to next row
    rowH := thumbH + labelGap + labelH + rowGap

    ; Compute flow layout
    flowSlots := []
    _GridFlowLayout(thumbH, rowH, aspects, maxW, gap, &flowSlots)

    ; Determine row split
    totalRows := flowSlots.Length > 0
               ? (flowSlots[flowSlots.Length].y // rowH) + 1
               : 0
    rowsTop   := Min(totalRows, Max(0, (availTop + rowGap) // rowH))
    rowsBot   := totalRows - rowsTop
    topRowsH  := rowsTop * rowH

    topH      := rowsTop > 0 ? availTop : 0
    botH      := rowsBot > 0 ? availBot : 0
    topY      := rowsTop > 0 ? waTop : (sgY - margin)
    botY      := sgY + sgH + margin
    ; Bottom-align content in the top canvas (thumbnails closest to the switcher)
    topOffset := rowsTop > 0 ? topH - (rowsTop * rowH - rowGap) : 0

    canvasX := waLeft + margin

    ; ── create canvases (fresh each rebuild so label controls are clean) ──────
    isDark  := _SwitcherIsDark()
    bg      := isDark ? "1A1A1A" : "E8E8E8"
    cardBg  := isDark ? "2D2D2D" : "D4D4D4"   ; card background, slightly distinct from canvas
    fg      := isDark ? "EFEFEF" : "1A1A1A"

    _MakeGridCanvas(&cgRef, label, x, y, w, h, show) {
        cg := Gui("+AlwaysOnTop -Caption +ToolWindow", "AltTabSucks_Grid_" . label)
        cg.BackColor := bg
        cg.SetFont("s9 c" fg, "Segoe UI")
        WinSetExStyle("+0x08000000", "ahk_id " cg.Hwnd)
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", cg.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
        if show
            cg.Show("NA x" x " y" y " w" w " h" h)
        cgRef := cg
    }
    ; Guard: the key-up handler may have closed the switcher while this timer fired.
    if !IsObject(_switcherGui) {
        _SwitcherGridClose()
        return
    }
    _MakeGridCanvas(&_gridTopGui, "Top", canvasX, topY, maxW, topH > 0 ? topH : 1, rowsTop > 0)
    _MakeGridCanvas(&_gridBotGui, "Bot", canvasX, botY, maxW, botH > 0 ? botH : 1, rowsBot > 0)

    ; ── register DWM thumbnails and add title labels ──────────────────────────
    ; Second guard: the close interrupt may have run between _MakeGridCanvas and here.
    if !IsObject(_switcherGui) || !IsObject(_gridTopGui) || !IsObject(_gridBotGui) {
        _SwitcherGridClose()
        return
    }
    cardH := labelH + labelGap + thumbH   ; full card height per slot
    loop count {
        i  := A_Index
        fs := flowSlots[i]
        if fs.y < topRowsH {
            cGui         := _gridTopGui
            tY           := fs.y + topOffset   ; canvas-relative top of card (= top of label)
            thumbY       := tY + labelH + labelGap   ; canvas-relative top of thumbnail
            canvasOriginY := topY
        } else {
            cGui         := _gridBotGui
            tY           := fs.y - topRowsH
            thumbY       := tY + labelH + labelGap
            canvasOriginY := botY
        }
        ; Canvas may have been destroyed by the close interrupt mid-loop.
        ; IsObject() is true for a destroyed-but-referenced Gui, so use try/catch.
        try {
            hT := 0
            if DllCall("dwmapi\DwmRegisterThumbnail", "Ptr", cGui.Hwnd,
                        "Ptr", _switcherItems[i].hwnd, "Ptr*", &hT) = 0 {
                ; Thumbnail sits below the title label
                _GridApplyThumb(hT, fs.x, thumbY, fs.w, fs.h)
                ; Full-height card background + title at top
                ; (+0x4081 = SS_CENTER|SS_NOPREFIX|SS_ENDELLIPSIS)
                ; The DWM thumbnail is compositor-rendered on top of this control's lower portion.
                cGui.AddText("x" fs.x " y" tY " w" fs.w " h" cardH " +0x4081 +Background" cardBg,
                             _switcherItems[i].title)
                screenX      := canvasX + fs.x
                screenY      := canvasOriginY + tY
                thumbScreenY := canvasOriginY + thumbY
                _gridSlots.Push({hwnd: _switcherItems[i].hwnd, hThumb: hT,
                                  screenX: screenX, screenY: screenY, thumbScreenY: thumbScreenY,
                                  w: fs.w, h: fs.h, totalH: cardH})
            }
        } catch {
            break   ; canvas was destroyed mid-loop; remaining slots will be cleaned up by Close
        }
    }

    _SwitcherGridRingShow(true)
}

_SwitcherGridItemsMatch(thumbH) {
    global _switcherItems, _gridSlots, _gridThumbH
    if _switcherItems.Length != _gridSlots.Length || thumbH != _gridThumbH
        return false
    loop _switcherItems.Length
        if _switcherItems[A_Index].hwnd != _gridSlots[A_Index].hwnd
            return false
    return true
}

_GridApplyThumb(hThumb, x, y, w, h) {
    props := Buffer(48, 0)
    NumPut("UInt",  0x0D,   props,  0)
    NumPut("Int",   x,      props,  4)
    NumPut("Int",   y,      props,  8)
    NumPut("Int",   x + w,  props, 12)
    NumPut("Int",   y + h,  props, 16)
    NumPut("UChar", 255,    props, 36)
    NumPut("Int",   1,      props, 40)
    DllCall("dwmapi\DwmUpdateThumbnailProperties", "Ptr", hThumb, "Ptr", props)
}

_SwitcherGridRingShow(recreate := false) {
    global _switcherGui, _switcherCurrentRow, _gridTopGui, _gridBotGui, _gridRingGui
    global _gridSlots, _gridRingInner, _gridRingInnerW, _gridRingInnerH

    ; Switcher may have closed while a timer was in flight
    if !IsObject(_switcherGui) || (!IsObject(_gridTopGui) && !IsObject(_gridBotGui))
        return
    row := _switcherCurrentRow
    if row < 1 || row > _gridSlots.Length {
        if IsObject(_gridRingGui)
            _gridRingGui.Hide()
        return
    }

    slot := _gridSlots[row]
    bord := 3

    if recreate && IsObject(_gridRingGui) {
        _gridRingGui.Destroy()
        _gridRingGui    := 0
        _gridRingInner  := 0
        _gridRingInnerW := 0
        _gridRingInnerH := 0
    }

    if !IsObject(_gridRingGui) {
        isDark      := _SwitcherIsDark()
        accentColor := isDark ? "4CC2FF" : "0067C0"
        rg    := Gui("+AlwaysOnTop -Caption +ToolWindow", "AltTabSucks_GridRing")
        rg.BackColor := accentColor
        inner := rg.AddText("x" bord " y" bord " w" slot.w " h" slot.h)
        inner.Opt("+Background000001")
        WinSetExStyle("+0x08000000", "ahk_id " rg.Hwnd)
        WinSetTransColor("000001", "ahk_id " rg.Hwnd)
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", rg.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
        _gridRingGui    := rg
        _gridRingInner  := inner
        _gridRingInnerW := slot.w
        _gridRingInnerH := slot.h
    } else if slot.w != _gridRingInnerW || slot.h != _gridRingInnerH {
        ; Resize the transparent-hole control to match the new slot size
        _gridRingInner.Move(bord, bord, slot.w, slot.h)
        _gridRingInnerW := slot.w
        _gridRingInnerH := slot.h
    }

    _gridRingGui.Show("NA x" (slot.screenX - bord) " y" (slot.thumbScreenY - bord)
                         " w" (slot.w + bord * 2)  " h" (slot.h + bord * 2))
}

_SwitcherGridClientToSlot(canvasHwnd, lParam) {
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if x > 0x7FFF
        x -= 0x10000
    if y > 0x7FFF
        y -= 0x10000
    pt := Buffer(8, 0)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    DllCall("ClientToScreen", "Ptr", canvasHwnd, "Ptr", pt)
    sx := NumGet(pt, 0, "Int")
    sy := NumGet(pt, 4, "Int")
    loop _gridSlots.Length {
        slot := _gridSlots[A_Index]
        if sx >= slot.screenX && sx < slot.screenX + slot.w
        && sy >= slot.screenY && sy < slot.screenY + slot.totalH
            return A_Index
    }
    return 0
}

_SwitcherGridHover(canvasHwnd, lParam) {
    global _switcherCurrentRow, _switcherLV, _gridHoverSX, _gridHoverSY

    ; Convert client coords to screen coords to detect synthetic WM_MOUSEMOVE.
    ; Windows sends a synthetic move when a window's z-order changes under the cursor
    ; (e.g. the ring repositions after keyboard navigation).  Skip it so keyboard
    ; navigation can't be reverted by a hover event at the same physical position.
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if x > 0x7FFF
        x -= 0x10000
    if y > 0x7FFF
        y -= 0x10000
    pt := Buffer(8, 0)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    DllCall("ClientToScreen", "Ptr", canvasHwnd, "Ptr", pt)
    sx := NumGet(pt, 0, "Int")
    sy := NumGet(pt, 4, "Int")
    if sx = _gridHoverSX && sy = _gridHoverSY
        return
    global _gridHoverSX := sx
    global _gridHoverSY := sy

    idx := _SwitcherGridClientToSlot(canvasHwnd, lParam)
    if idx < 1 || idx = _switcherCurrentRow
        return
    global _switcherCurrentRow := idx
    if IsObject(_switcherLV) {
        _switcherLV.Modify(0, "-Select")
        _switcherLV.Modify(idx, "Select Focus Vis")
    }
    _SwitcherGridRingShow()
}

_SwitcherGridClickAt(canvasHwnd, lParam) {
    idx := _SwitcherGridClientToSlot(canvasHwnd, lParam)
    if idx >= 1
        _SwitcherActivate(idx)
}

_SwitcherGridClose() {
    global _gridTopGui, _gridBotGui, _gridRingGui, _gridSlots, _gridThumbH
    global _gridRingInner, _gridRingInnerW, _gridRingInnerH
    global _gridHoverSX, _gridHoverSY
    SetTimer(_SwitcherGridUpdate, 0)
    for slot in _gridSlots
        if slot.hThumb != 0
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", slot.hThumb)
    global _gridSlots       := []
    global _gridThumbH      := 0
    global _gridRingInner   := 0
    global _gridRingInnerW  := 0
    global _gridRingInnerH  := 0
    global _gridHoverSX     := -99999
    global _gridHoverSY     := -99999
    if IsObject(_gridRingGui) {
        _gridRingGui.Hide()     ; synchronous hide first so the ring vanishes immediately
        _gridRingGui.Destroy()
        global _gridRingGui := 0
    }
    if IsObject(_gridTopGui) {
        _gridTopGui.Destroy()
        global _gridTopGui := 0
    }
    if IsObject(_gridBotGui) {
        _gridBotGui.Destroy()
        global _gridBotGui := 0
    }
}
