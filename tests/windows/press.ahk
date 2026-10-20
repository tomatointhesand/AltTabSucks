; press.ahk - presses a hotkey on the desktop for tests/windows/e2e.ps1, then reports which window
; ended up in front. Args: results file, keys (Send syntax; "" just reports), and optionally the exe of
; a window to activate first (to press the hotkey "from outside" the browser).

#Requires AutoHotkey v2.0
#NoTrayIcon

out := A_Args[1]
keys := A_Args[2]
try FileDelete(out)

if A_Args.Length >= 3 {
    target := "ahk_exe " A_Args[3]
    if !WinWait(target, , 15) {
        FileAppend("error=no window for " A_Args[3] "`n", out, "UTF-8-RAW")
        ExitApp(1)
    }
    WinActivate(target)
    WinWaitActive(target, , 5)
}
before := WinExist("A") ? WinGetProcessName("A") : ""

; SendLevel 1: hotkeys ignore input from other AutoHotkey scripts sent at the default level 0.
SendLevel(1)
if keys != ""
    SendEvent(keys)
Sleep(2500)  ; FocusTab polls up to 1.5s for the browser to come forward

; Also: the front window's handle, the screen width, and each visible Edge window's position, so
; the test can tell cycling (which window is in front) and split snapping (side by side) apart.
edge := ""
for hwnd in WinGetList("ahk_class Chrome_WidgetWin_1 ahk_exe msedge.exe") {
    if !(WinGetStyle(hwnd) & 0x10000000) || WinGetTitle(hwnd) = ""  ; WS_VISIBLE
        continue
    WinGetPos(&x, &y, &w, &h, hwnd)
    edge .= (edge ? ";" : "") hwnd ":" x "," y "," w "," h
}
; And any AltTabSucks popups on screen (error/notice dialogs explain a hotkey that did nothing).
guis := ""
for hwnd in WinGetList("ahk_class AutoHotkeyGUI")
    if WinGetStyle(hwnd) & 0x10000000
        guis .= (guis ? " | " : "") RegExReplace(WinGetText(hwnd), "\s+", " ")
DetectHiddenWindows(false)
FileAppend("before=" before "`nactive=" (WinExist("A") ? WinGetProcessName("A") : "")
    . "`nhwnd=" WinExist("A") "`ntitle=" (WinExist("A") ? WinGetTitle("A") : "") "`nscreen=" A_ScreenWidth
    . "`nedge=" edge "`nguis=" guis "`n", out, "UTF-8-RAW")
ExitApp(0)
