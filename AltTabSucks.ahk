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

^!+':: Reload  ; reload script

#Include lib\utils.ahk        ; ShowTextGui, ManageAppWindows, ShowSettingsGui
#Include lib\toast.ahk        ; SampleTitlebarColor, ShowProfileToast, ShowSetupToast
CHROMIUM_EXE        := ""     ; defaults — overwritten by config.ahk if it exists
CHROMIUM_USERDATA   := ""
FIREFOX_EXE         := ""
FIREFOX_PROFILE_INI := ""
#Include *i lib\config.ahk    ; browser paths (gitignored — auto-detected on first launch if absent)
#Include lib\chromium.ahk     ; Chromium profile cycling + tab focus via AltTabSucks server
#Include lib\firefox.ahk      ; Firefox profile cycling + tab focus via AltTabSucks server
#Include lib\app-hotkeys.ahk  ; general app + browser hotkeys
#Include lib\star-citizen.ahk ; Star Citizen automation (scoped to SC window)

A_TrayMenu.Insert("1&", "Settings", (*) => ShowSettingsGui())
A_TrayMenu.Insert("2&")
