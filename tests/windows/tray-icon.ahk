; tray-icon.ahk - writes "1" to the file given as the argument if AltTabSucks.ahk's tray icon is in
; the taskbar, "0" if not (logon.ps1). Runs on the desktop: it asks Explorer.
#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_ScriptDir%\..\..\lib\tray-icon.ahk
DetectHiddenWindows(true)
SetTitleMatchMode(2)
hwnd := WinExist("\AltTabSucks.ahk - AutoHotkey ahk_class AutoHotkey")
FileAppend(hwnd && TrayIconShown(hwnd) ? "1" : "0", A_Args[1], "UTF-8-RAW")
