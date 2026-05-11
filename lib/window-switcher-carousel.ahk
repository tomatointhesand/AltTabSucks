; window-switcher-carousel.ahk — animated multi-window DWM thumbnail carousel

_SwitcherCarouselUpdate() {
    global _switcherGui, _switcherItems, _switcherCurrentRow
    global _carouselGui, _carouselSlots, _carouselAnimOn

    if !IsObject(_switcherGui)
        return

    ; ── geometry ──────────────────────────────────────────────────────────────
    nSlots := SWITCHER_CAROUSEL_SLOTS
    if Mod(nSlots, 2) = 0
        nSlots += 1
    halfN     := nSlots // 2
    scaleStep := 0.65
    gap       := 14

    totalSF := 0.0
    loop nSlots
        totalSF += scaleStep ** Abs(A_Index - 1 - halfN)
    desiredW := Max(Round(640 * SWITCHER_PREVIEW_SIZE / 100), 64)
    maxFitW  := Floor((A_ScreenWidth * 0.85 - (nSlots - 1) * gap) / totalSF)
    centerW  := Min(desiredW, maxFitW)
    centerH  := Round(centerW * 0.625)

    canvasW := 0
    loop nSlots {
        canvasW += Round(centerW * scaleStep ** Abs(A_Index - 1 - halfN))
        if A_Index < nSlots
            canvasW += gap
    }
    canvasH := centerH

    ; Position canvas: centred horizontally, above or below the switcher popup
    try
        WinGetPos(&sgX, &sgY, &sgW, &sgH, "ahk_id " _switcherGui.Hwnd)
    catch
        return
    canvasX := Max(0, (A_ScreenWidth - canvasW) // 2)
    canvasY := (SWITCHER_CAROUSEL_POSITION = "below") ? sgY + sgH + 20 : sgY - canvasH - 20
    canvasY := Max(10, Min(canvasY, A_ScreenHeight - canvasH - 10))

    ; ── canvas Gui ────────────────────────────────────────────────────────────
    if !IsObject(_carouselGui) {
        cg := Gui("+AlwaysOnTop -Caption +ToolWindow", "AltTabSucks_Carousel")
        cg.BackColor := "010101"
        WinSetTransparent(254, "ahk_id " cg.Hwnd)
        ; WS_EX_NOACTIVATE: clicking a thumbnail doesn't steal focus from the switcher,
        ; so _carouselGui is still valid when the WM_LBUTTONDOWN OnMessage handler fires.
        WinSetExStyle("+0x08000000", "ahk_id " cg.Hwnd)
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", cg.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)  ; rounded corners (Win11)
        _carouselGui := cg
    }
    _carouselGui.Show("NA x" canvasX " y" canvasY " w" canvasW " h" canvasH)

    ; ── compute target rect for each visible slot ──────────────────────────────
    ; visSlots: [{hwnd, tL, tT, tR, tB, handled}]  one entry per visible position
    count    := _switcherItems.Length
    visSlots := []
    xCursor  := 0
    loop nSlots {
        d    := A_Index - 1 - halfN
        absD := Abs(d)
        scl  := scaleStep ** absD
        sw   := Round(centerW * scl)
        sh   := Round(centerH * scl)
        tL   := xCursor
        tT   := (centerH - sh) // 2
        if count > 0 {
            winIdx := _switcherCurrentRow + d
            while winIdx < 1
                winIdx += count
            while winIdx > count
                winIdx -= count
            visSlots.Push({hwnd: _switcherItems[winIdx].hwnd,
                            tL: tL + 0.0, tT: tT + 0.0,
                            tR: tL + sw + 0.0, tB: tT + sh + 0.0,
                            handled: false})
        }
        xCursor += sw + gap
    }

    ; ── match existing thumbs to visible slots — no re-registration ───────────
    ; Thumbs that still appear in the visible range just get new target positions.
    ; Thumbs that left the range are marked `removing` and fade to opacity 0.
    for thumb in _carouselSlots
        thumb.matched := false

    for slot in visSlots {
        for thumb in _carouselSlots {
            if thumb.srcHwnd = slot.hwnd && !thumb.removing && !thumb.matched {
                thumb.matched := true
                slot.handled  := true
                thumb.tL := slot.tL
                thumb.tT := slot.tT
                thumb.tR := slot.tR
                thumb.tB := slot.tB
                thumb.tOp := 255.0
                break
            }
        }
    }

    for thumb in _carouselSlots {
        if !thumb.matched && !thumb.removing {
            thumb.removing := true
            thumb.tOp      := 0.0
        }
    }

    ; ── register new thumbs for slots with no existing registration ────────────
    ; New thumbs start at their target rect with opacity 0 and fade in.
    if !IsObject(_carouselGui)
        return
    for slot in visSlots {
        if slot.handled
            continue
        hT := 0
        if DllCall("dwmapi\DwmRegisterThumbnail", "Ptr", _carouselGui.Hwnd,
                    "Ptr", slot.hwnd, "Ptr*", &hT) = 0 {
            _carouselSlots.Push({
                hThumb: hT, srcHwnd: slot.hwnd, removing: false, matched: true,
                cL: slot.tL, cT: slot.tT, cR: slot.tR, cB: slot.tB, cOp: 0.0,
                tL: slot.tL, tT: slot.tT, tR: slot.tR, tB: slot.tB, tOp: 255.0
            })
        }
    }

    ; ── apply / animate ───────────────────────────────────────────────────────
    if SWITCHER_CAROUSEL_ANIMATE {
        if !_carouselAnimOn {
            global _carouselAnimOn := true
            SetTimer(_SwitcherCarouselAnimTick, 16)
        }
    } else {
        SetTimer(_SwitcherCarouselAnimTick, 0)
        global _carouselAnimOn := false
        _SwitcherCarouselApply(true)
    }
}

; Apply current positions to DWM and optionally snap current → target first.
; Also prunes fully-faded removing thumbs.
_SwitcherCarouselApply(snap := false) {
    global _carouselSlots
    for thumb in _carouselSlots {
        if snap {
            thumb.cL  := thumb.tL
            thumb.cT  := thumb.tT
            thumb.cR  := thumb.tR
            thumb.cB  := thumb.tB
            thumb.cOp := thumb.tOp
        }
        props := Buffer(48, 0)
        NumPut("UInt",  0x0D,             props,  0)
        NumPut("Int",   Round(thumb.cL),  props,  4)
        NumPut("Int",   Round(thumb.cT),  props,  8)
        NumPut("Int",   Round(thumb.cR),  props, 12)
        NumPut("Int",   Round(thumb.cB),  props, 16)
        NumPut("UChar", Round(thumb.cOp), props, 36)
        NumPut("Int",   1,                props, 40)
        DllCall("dwmapi\DwmUpdateThumbnailProperties", "Ptr", thumb.hThumb, "Ptr", props)
    }
    ; Prune removing thumbs that have fully faded (iterate backward for safe removal)
    i := _carouselSlots.Length
    while i >= 1 {
        thumb := _carouselSlots[i]
        if thumb.removing && Round(thumb.cOp) <= 0 {
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", thumb.hThumb)
            _carouselSlots.RemoveAt(i)
        }
        i -= 1
    }
}

_SwitcherCarouselAnimTick() {
    global _carouselGui, _carouselSlots, _carouselAnimOn
    if !IsObject(_carouselGui) {
        SetTimer(_SwitcherCarouselAnimTick, 0)
        global _carouselAnimOn := false
        return
    }
    k    := SWITCHER_CAROUSEL_SPEED = "slow" ? 0.10
          : SWITCHER_CAROUSEL_SPEED = "fast" ? 0.38
          : 0.22   ; medium
    done := true
    for thumb in _carouselSlots {
        thumb.cL  += (thumb.tL  - thumb.cL)  * k
        thumb.cT  += (thumb.tT  - thumb.cT)  * k
        thumb.cR  += (thumb.tR  - thumb.cR)  * k
        thumb.cB  += (thumb.tB  - thumb.cB)  * k
        thumb.cOp += (thumb.tOp - thumb.cOp) * k
        if Abs(thumb.cL - thumb.tL) > 0.5 || Abs(thumb.cT - thumb.tT) > 0.5
           || Abs(thumb.cOp - thumb.tOp) > 0.5
            done := false
    }
    _SwitcherCarouselApply()   ; write to DWM and prune faded-out removing thumbs
    if done {
        SetTimer(_SwitcherCarouselAnimTick, 0)
        global _carouselAnimOn := false
    }
}

_SwitcherCarouselClose() {
    global _carouselGui, _carouselSlots, _carouselAnimOn
    SetTimer(_SwitcherCarouselUpdate,    0)
    SetTimer(_SwitcherCarouselAnimTick,  0)
    global _carouselAnimOn := false
    for slot in _carouselSlots {
        if slot.hThumb != 0 {
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", slot.hThumb)
            slot.hThumb  := 0
            slot.srcHwnd := 0
        }
    }
    _carouselSlots := []
    if IsObject(_carouselGui) {
        _carouselGui.Destroy()
        _carouselGui := 0
    }
}
