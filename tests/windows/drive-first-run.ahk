; drive-first-run.ahk - answers AltTabSucks' first-launch dialogs for tests/windows/e2e.ps1:
; picks the first browser in "Choose target browser", then "No" to "Set default browser?".
; Writes what it did to the file named by its first argument.

#Requires AutoHotkey v2.0
#NoTrayIcon

out := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\drive-first-run.txt"
Log(line) => FileAppend(line "`n", out, "UTF-8-RAW")
try FileDelete(out)

; Clicks a button until its dialog actually closes. A click that lands while the dialog is still
; settling can be lost, which left AltTabSucks stuck on a dialog mid-startup (no reload watcher,
; no starter hotkeys) while this script reported success.
ClickUntilClosed(hwnd, button) {
    Loop 5 {
        try ControlClick(button, hwnd)
        if WinWaitClose(hwnd, , 2)
            return true
    }
    return false
}

if !(choice := WinWait("ahk_class AutoHotkeyGUI", "Choose target browser", 60)) {
    Log("no browser choice dialog")
    ExitApp(1)
}
Log("browser choice dialog: " WinGetText(choice))
; Click rather than send "1": the dialog's digit shortcuts are hotkeys, and hotkeys ignore
; keystrokes sent by another AutoHotkey script. Clicking also doesn't depend on focus.
if !ClickUntilClosed(choice, "Button1") {
    Log("browser choice dialog didn't close")
    ExitApp(1)
}

if !(prompt := WinWait("Set default browser?", , 15)) {
    Log("no default-browser prompt")
    ExitApp(1)
}
if !ClickUntilClosed(prompt, "Button2") {  ; Yes, No
    Log("default-browser prompt didn't close")
    ExitApp(1)
}
Log("answered both")
ExitApp(0)
