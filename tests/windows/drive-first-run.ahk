; drive-first-run.ahk - answers AltTabSucks' first-launch dialogs for tests/windows/e2e.ps1:
; picks the first browser in "Choose target browser", then "No" to "Set default browser?".
; Writes what it did to the file named by its first argument.

#Requires AutoHotkey v2.0
#NoTrayIcon

out := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\drive-first-run.txt"
Log(line) => FileAppend(line "`n", out, "UTF-8-RAW")
try FileDelete(out)

if !WinWait("ahk_class AutoHotkeyGUI", "Choose target browser", 60) {
    Log("no browser choice dialog")
    ExitApp(1)
}
Log("browser choice dialog: " WinGetText())
; Click rather than send "1": the dialog's digit shortcuts are hotkeys, and hotkeys ignore
; keystrokes sent by another AutoHotkey script. Clicking also doesn't depend on focus.
ControlClick("Button1")

if !WinWait("Set default browser?", , 15) {
    Log("no default-browser prompt")
    ExitApp(1)
}
ControlClick("Button2")  ; Yes, No
Log("answered both")
ExitApp(0)
