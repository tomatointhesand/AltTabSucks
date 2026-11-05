; tray-icon.ahk - is an AutoHotkey script's tray icon there, and keeping AltTabSucks.ahk's there.
;
; At logon the startup manager starts AltTabSucks.ahk within a second or so of Explorer, often
; before the taskbar exists. The icon AutoHotkey adds then is lost. AutoHotkey adds it again when
; the taskbar broadcasts "TaskbarCreated", but AltTabSucks.ahk runs elevated and Windows filters
; that message out on its way to an elevated window. So TrayIconKeep() lets the message through
; (which also covers Explorer restarting later) and, for the first two minutes, checks every second
; that the icon is there and adds it again if it isn't.
;
; Included by AltTabSucks.ahk (TrayIconKeep) and StartupManager.ahk (TrayIconShown, for when the
; AltTabSucks item counts as ready).

TRAY_ICON_ID := 1028  ; the uID AutoHotkey v2 gives its tray icon (AHK_NOTIFYICON)

; True if the tray icon of the script whose main window is hwnd is in the taskbar (shown or in the
; overflow area).
TrayIconShown(hwnd) {
    x64 := A_PtrSize = 8
    nii := Buffer(x64 ? 40 : 28, 0)  ; NOTIFYICONIDENTIFIER
    NumPut("uint", nii.Size, nii, 0)
    NumPut("ptr", hwnd, nii, x64 ? 8 : 4)
    NumPut("uint", TRAY_ICON_ID, nii, x64 ? 16 : 8)
    rc := Buffer(16, 0)
    return DllCall("shell32\Shell_NotifyIconGetRect", "ptr", nii, "ptr", rc, "int") = 0
}

TrayIconKeep() {
    msg := DllCall("RegisterWindowMessage", "str", "TaskbarCreated", "uint")
    DllCall("ChangeWindowMessageFilterEx", "ptr", A_ScriptHwnd, "uint", msg, "uint", 1, "ptr", 0)  ; MSGFLT_ALLOW
    SetTimer(_TrayIconCheck, 1000)
}

_TrayIconCheck() {
    static checks := 0
    if ++checks > 120 {
        SetTimer(, 0)
        return
    }
    if A_IconHidden || !WinExist("ahk_class Shell_TrayWnd") || TrayIconShown(A_ScriptHwnd)
        return
    A_IconHidden := true   ; add it again
    A_IconHidden := false
}
