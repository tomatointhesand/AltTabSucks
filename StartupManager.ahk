; Copyright (C) 2026 LtDerbs
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version. See LICENSE for details.

; The startup manager: launches the startup items (AltTabSucks.ahk among them) at logon, in order,
; with their delays, and records how long each took. See lib/startup-manager.ahk.

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

#Include lib\json.ahk
#Include lib\startup-logic.ahk
#Include lib\tray-icon.ahk
#Include lib\startup-manager.ahk

StartupManagerMain(A_Args)
