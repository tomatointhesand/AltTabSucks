; toast.ahk - Toasts, overlays, and blocking choice dialogs

global _activeToast   := ""
global _toastColorIdx := 0
global _lastToastTick := 0
global _toastROYGBIV  := [
    0xCC0000,  ; red
    0xE53300,  ; red-orange
    0xFF6600,  ; orange
    0xFF9900,  ; amber
    0xFFCC00,  ; yellow
    0x80B300,  ; yellow-green
    0x009900,  ; green
    0x006F66,  ; teal
    0x0044CC,  ; blue
    0x2622A7,  ; blue-indigo
    0x4B0082,  ; indigo
    0x6B00C1,  ; purple
    0x8B00FF,  ; violet
]

; Sample a pixel from the right edge of the titlebar to match the toast background
; to the window's current theme color.
SampleTitlebarColor(hwnd) {
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    hDC := DllCall("GetDC", "Ptr", 0)
    pixel := DllCall("GetPixel", "Ptr", hDC, "Int", wx + ww - ww // 10, "Int", wy + 10)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC)
    r := pixel & 0xFF
    g := (pixel >> 8) & 0xFF
    b := (pixel >> 16) & 0xFF
    return Format("{:02X}{:02X}{:02X}", r, g, b)
}

_ExpireToast(t, capturedPtr) {
    global _activeToast
    try t.Destroy()
    if ObjPtr(_activeToast) = capturedPtr
        _activeToast := ""
}

; Centered screen toast for first-launch browser auto-detection notification.
ShowSetupToast(browserName, exePath, userDataPath, progId := "", duration := 5000) {
    t := Gui("-Caption +ToolWindow +AlwaysOnTop")
    t.BackColor := "1A2A3A"
    t.SetFont("s12 bold cFFFFFF", "Consolas")
    t.Add("Text", "x18 y14", "AltTabSucks: browser auto-detected")
    t.SetFont("s11 bold c7EC8E3", "Consolas")
    t.Add("Text", "x18 y40", browserName . (progId ? "  (" . progId . ")" : ""))
    t.SetFont("s9 cAABBCC", "Consolas")
    t.Add("Text", "x18 y62", exePath)
    t.Add("Text", "x18 y80", userDataPath)
    t.SetFont("s8 c556677", "Consolas")
    t.Add("Text", "x18 y102 w400", "config.ahk written  —  edit to change")
    t.Show("Hide NoActivate")
    WinGetPos(, , &tw, &th, "ahk_id " t.Hwnd)
    tw += 18  ; right padding
    th += 14
    WinSetRegion("R14-14 0-0 w" tw " h" th, "ahk_id " t.Hwnd)
    t.Show("NoActivate x" (A_ScreenWidth - tw) // 2 " y" (A_ScreenHeight - th) // 2)
    SetTimer(() => t.Destroy(), -duration)
}

; Generic blocking choice dialog. Matches the dark toast aesthetic.
;
; choices: Array of plain strings, or objects with .label (required) and .detail (optional)
;          fields. .detail is shown as a smaller line below the button.
; Returns: 1-based index of the chosen option, or 0 if dismissed (Esc / close button).
;
; Design principles:
;   - Single responsibility: pure UI primitive — no domain knowledge about browsers or hotkeys.
;   - Closed for modification: callers supply arbitrary choices without subclassing.
;   - Encapsulation: selection state lives in a Map local to this call, not in a global.
;   - DRY: _MakeChoiceBtnHandler / _MakeChoiceKeyHandler are closure factories that
;     eliminate the repetition of wiring each button and digit key individually.
ShowChoiceDialog(title, prompt, choices) {
    result := Map("chosen", 0)
    d      := Gui("+AlwaysOnTop -MinimizeBox")
    d.BackColor := "1A2A3A"

    d.SetFont("s12 bold cFFFFFF", "Consolas")
    d.Add("Text", "x20 y18 w480", title)

    y := 44
    if prompt != "" {
        d.SetFont("s9 cAABBCC", "Consolas")
        d.Add("Text", "x20 y" y " w480", prompt)
        y += 24
    }
    y += 8

    for i, choice in choices {
        label  := (choice is Object && choice.HasProp("label"))  ? choice.label  : String(choice)
        detail := (choice is Object && choice.HasProp("detail")) ? choice.detail : ""
        d.SetFont("s10 cFFFFFF", "Consolas")
        btn := d.Add("Button", "x20 y" y " w480 h28", i . "   " . label)
        btn.OnEvent("Click", _MakeChoiceBtnHandler(i, result, d))
        y += 32
        if detail != "" {
            d.SetFont("s8 c4A6070", "Consolas")
            d.Add("Text", "x28 y" y " w472", detail)
            y += 18
        }
        y += 6
    }

    d.SetFont("s8 c3A5060", "Consolas")
    d.Add("Text", "x20 y" y " w480", "Press 1–" . Min(choices.Length, 9) . " to choose  ·  Esc to cancel")
    y += 22

    d.Show("Hide AutoSize")
    dHwnd := d.Hwnd
    WinGetPos(, , &dw, &dh, "ahk_id " dHwnd)
    dw += 20
    WinSetRegion("R14-14 0-0 w" dw " h" dh, "ahk_id " dHwnd)
    safeY := Max(10, (A_ScreenHeight - dh) // 2)
    d.Show("x" (A_ScreenWidth - dw) // 2 " y" safeY)

    ; Digit and Escape shortcuts — predicate keeps them scoped to this dialog
    isActive := (*) => WinActive("ahk_id " dHwnd)
    HotIf(isActive)
    Loop Min(choices.Length, 9) {
        n := A_Index
        Hotkey(String(n), _MakeChoiceKeyHandler(n, result, d))
    }
    Hotkey("Escape", (*) => d.Destroy())
    HotIf()

    d.OnEvent("Close", (*) => 0)
    WinWaitClose("ahk_id " dHwnd)
    return result["chosen"]
}

; Closure factory for button OnEvent("Click") handlers.
_MakeChoiceBtnHandler(idx, result, gui) {
    return (ctrl, *) => (result["chosen"] := idx, gui.Destroy())
}

; Closure factory for Hotkey callbacks.
_MakeChoiceKeyHandler(idx, result, gui) {
    return (*) => (result["chosen"] := idx, gui.Destroy())
}

ShowProfileToast(hwnd, label, bgColor) {
    global _activeToast, _toastColorIdx, _toastROYGBIV, _lastToastTick
    now := A_TickCount
    ; Continue the rainbow if a toast is still visible OR fired recently.
    ; Without the recency check the rainbow resets to bgColor whenever a toast expires
    ; (250ms) between two rapid firings.
    if IsObject(_activeToast) || (now - _lastToastTick < 600) {
        _toastColorIdx := Mod(_toastColorIdx, _toastROYGBIV.Length) + 1
        bgColor := _toastROYGBIV[_toastColorIdx]
    } else {
        _toastColorIdx := 0  ; gap in sequence — next rapid burst starts fresh
    }
    _lastToastTick := now
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    t := Gui("-Caption +ToolWindow +AlwaysOnTop")
    t.BackColor := bgColor
    t.SetFont("s24 bold c471313", "Consolas")
    t.Add("Text", "x34 y27", StrUpper(label))
    t.SetFont("s24 bold cWhite", "Consolas")
    t.Add("Text", "x30 y23 BackgroundTrans", StrUpper(label))
    t.Show("Hide")
    WinGetPos(&_tx, &_ty, &tw, &th, "ahk_id " t.Hwnd)
    WinSetRegion("R20-20 0-0 w" tw " h" th, "ahk_id " t.Hwnd)
    t.Show("NoActivate x" (wx + (ww - tw) // 2) " y" (wy + (wh - th) // 2))
    _activeToast := t
    local capturedPtr := ObjPtr(t)
    SetTimer(() => _ExpireToast(t, capturedPtr), -500)
}
