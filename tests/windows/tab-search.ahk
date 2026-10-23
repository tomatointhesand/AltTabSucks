; tab-search.ahk - drives the tab search popup (lib/tab-search.ahk) for tests/windows/e2e.ps1, like a
; person would. Args: results file, then steps, run in order:
;   open           press Ctrl+Alt+Shift+A and wait for the popup
;   type:<text>    set the search box's text (fires the same change event as typing)
;   key:<keys>     press keys (Send syntax) while the popup is in front, e.g. key:{Down}, key:^w
;   read           log the list's rows ("row=<title>`t<address>")
;   wait:<ms>      pause
; Logs "popup=open|closed" after every step, and "error=..." if a step can't run.

#Requires AutoHotkey v2.0
#NoTrayIcon

out := A_Args[1]
try FileDelete(out)
Log(line) => FileAppend(line "`n", out, "UTF-8-RAW")
popup := "AltTabSucks_TabSearch ahk_class AutoHotkeyGUI"
SetTitleMatchMode(3)  ; exact title

; SendLevel 1: the popup's keys are AltTabSucks hotkeys, which ignore level-0 input from other scripts.
SendLevel(1)
for step in A_Args {
    if A_Index = 1
        continue
    colon := InStr(step, ":")
    name := colon ? SubStr(step, 1, colon - 1) : step
    arg := colon ? SubStr(step, colon + 1) : ""
    switch name {
        case "open":
            SendEvent("^!+a")
            if !WinWait(popup, , 10) {
                Log("error=popup didn't open")
                break
            }
            WinWaitActive(popup, , 3)
            Sleep(500)
        case "type":
            ControlSetText(arg, "Edit1", popup)
            Sleep(700)
        case "key":
            if WinExist(popup)
                WinActivate(popup), WinWaitActive(popup, , 3)
            SendEvent(arg)
            Sleep(1000)
        case "read":
            try {
                for row in StrSplit(ListViewGetContent("", "SysListView321", popup), "`n", "`r")
                    Log("row=" row)
            } catch as e {
                Log("error=can't read the list: " e.Message)
            }
        case "wait":
            Sleep(Integer(arg))
    }
    Log("popup=" (WinExist(popup) ? "open" : "closed"))
}
Log("done")
ExitApp(0)
