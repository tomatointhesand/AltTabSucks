; press.ahk - presses a hotkey on the desktop for tests/windows/e2e.ps1, then reports which window
; ended up in front. Args: results file, keys (Send syntax), and optionally the exe of a window to
; activate first (to press the hotkey "from outside" the browser).

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
SendEvent(keys)
Sleep(2500)  ; FocusTab polls up to 1.5s for the browser to come forward

FileAppend("before=" before "`nactive=" (WinExist("A") ? WinGetProcessName("A") : "") "`n", out, "UTF-8-RAW")
ExitApp(0)
