; answer-msgbox.ahk - for tests/windows/e2e.ps1: waits for a message box by title and clicks one of
; its buttons. Args: results file, window title, button (Button1 = Yes/OK, Button2 = No/Cancel),
; seconds to wait. Logs "text=<the box's text>" and "answered", or "no box".

#Requires AutoHotkey v2.0
#NoTrayIcon

out := A_Args[1]
try FileDelete(out)
Log(line) => FileAppend(line "`n", out, "UTF-8-RAW")

if !(hwnd := WinWait(A_Args[2] " ahk_class #32770", , Integer(A_Args[4]))) {
    Log("no box")
    ExitApp(1)
}
Log("text=" StrReplace(WinGetText(hwnd), "`r`n", " "))
Loop 5 {  ; a click that lands while the box is still settling can be lost
    try ControlClick(A_Args[3], hwnd)
    if WinWaitClose(hwnd, , 2) {
        Log("answered")
        ExitApp(0)
    }
}
Log("box didn't close")
ExitApp(1)
