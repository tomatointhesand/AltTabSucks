; config.ahk - Machine-local configuration (copy to config.ahk and fill in your paths)
; This file is tracked in git with placeholders. config.ahk is gitignored.

; Full path to the Chromium-based browser executable you want to use.
; Use A_ProgramFiles for Program Files, or EnvGet("LOCALAPPDATA") for per-user installs.
; Examples:
;   Brave:   A_ProgramFiles . "\BraveSoftware\Brave-Browser\Application\brave.exe"
;   Chrome:  A_ProgramFiles . "\Google\Chrome\Application\chrome.exe"
;   Edge:    EnvGet("ProgramFiles(x86)") . "\Microsoft\Edge\Application\msedge.exe"
;   Vivaldi: EnvGet("LOCALAPPDATA") . "\Vivaldi\Application\vivaldi.exe"
global CHROMIUM_EXE      := A_ProgramFiles . "C:\YOUR\PATH"

; Full path to the browser's User Data directory (contains Local State and profile folders).
; Examples:
;   Brave:   EnvGet("LOCALAPPDATA") . "\BraveSoftware\Brave-Browser\User Data"
;   Chrome:  EnvGet("LOCALAPPDATA") . "\Google\Chrome\User Data"
;   Edge:    EnvGet("LOCALAPPDATA") . "\Microsoft\Edge\User Data"
;   Vivaldi: EnvGet("LOCALAPPDATA") . "\Vivaldi\User Data"
global CHROMIUM_USERDATA := EnvGet("LOCALAPPDATA") . "C:\YOUR\PATH"
