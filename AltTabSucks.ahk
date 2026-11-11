; Copyright (C) 2026 LtDerbs
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version. See LICENSE for details.

#Requires AutoHotkey v2.0
#SingleInstance Force
DetectHiddenWindows 1
if not A_IsAdmin
    Run '*RunAs "' A_ScriptFullPath '"'
TrayIconKeep()  ; lib\tray-icon.ahk: at logon this can start before the taskbar exists

^!+':: RestartAltTabSucks()  ; restart the server, then reload this script

#Include lib\utils.ahk        ; ShowTextGui, ManageAppWindows, ShowSettingsGui
#Include lib\toast.ahk        ; SampleTitlebarColor, ShowProfileToast, ShowSetupToast
CHROMIUM_EXE := ""     ; defaults — overwritten by config.ahk if it exists
CHROMIUM_USERDATA := ""
CHROMIUM_EXTRA_FLAGS := ""
FIREFOX_EXE := ""
FIREFOX_PROFILE_INI := ""
#Include *i lib\config.ahk    ; browser paths (gitignored — auto-detected on first launch if absent)
_SwitcherSetHotkeysEnabled(SWITCHER_ENABLED)  ; after config.ahk, which may switch it on
#Include lib\chromium.ahk     ; Chromium profile cycling + tab focus via AltTabSucks server
#Include lib\firefox.ahk      ; Firefox profile cycling + tab focus via AltTabSucks server
#Include lib\tab-search.ahk   ; tab search popup (ShowTabSearch, Ctrl+Alt+Shift+A)
#Include lib\app-hotkeys.ahk  ; general app + browser hotkeys
#Include lib\json.ahk         ; Json_Parse, Json_Stringify
#Include lib\hotkeys-ui.ahk   ; runtime for hotkeys saved from the web UI (localhost:9876/hotkeys-ui)
#Include lib\tray-icon.ahk    ; keeps the tray icon there when this starts before the taskbar
#Include *i lib\SC.ahk ; SC automation (scoped to SC window) — optional

A_TrayMenu.Insert("1&", "Settings", (*) => ShowSettingsGui())
A_TrayMenu.Insert("2&", "Hotkeys UI", (*) => Run("http://localhost:9876/hotkeys-ui"))
A_TrayMenu.Insert("3&", "Search browser tabs", (*) => ShowTabSearch())
; Through Explorer, so the editor (and its "Run startup now") runs as a normal user, not elevated like this script.
A_TrayMenu.Insert("4&", "Startup items", (*) => Run('explorer.exe "' A_ScriptDir '\StartupManager.ahk"'))
A_TrayMenu.Insert("5&", "Connect browser extension", (*) => ConnectBrowserExtension())
A_TrayMenu.Insert("6&")