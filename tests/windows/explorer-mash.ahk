; explorer-mash.ahk - the real-Explorer side of lib/explorer.ahk that tests/ahk/test-explorer.ahk
; can't reach: mashes FocusOrOpenFolder on one folder, then counts the Explorer windows/tabs
; showing it. Run on the desktop by tests/windows/e2e.ps1. Args: folder, results file.

#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_ScriptDir%\..\..\lib\explorer.ahk

; The toast is cosmetic and lives in lib/toast.ahk with its own dependencies; stub it.
ShowProfileToast(*) => 0
SampleTitlebarColor(*) => 0

folder := A_Args[1]
out := A_Args[2]
try FileDelete(out)

CountShowing(path) {
    n := 0
    for w in ComObject("Shell.Application").Windows()
        try if w.Document.Folder.Self.Path = path
            n += 1
    return n
}

Loop 6 {                     ; a mashed hotkey: six presses 80ms apart
    FocusOrOpenFolder(folder)
    Sleep(80)
}
Sleep(4000)                  ; let Explorer finish opening
first := CountShowing(folder)
FocusOrOpenFolder(folder)    ; a later press should focus that window, not open another
Sleep(3000)
FileAppend("after_mash=" first "`nafter_second_press=" CountShowing(folder)
    . "`nactive_is_explorer=" (WinActive("ahk_class CabinetWClass") ? 1 : 0) "`n", out, "UTF-8-RAW")
ExitApp(0)
