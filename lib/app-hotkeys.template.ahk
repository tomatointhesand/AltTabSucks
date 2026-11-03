; app-hotkeys.ahk - your hotkeys (gitignored; installer.ps1 creates it from app-hotkeys.template.ahk)
; The web Hotkeys UI (Ctrl+Alt+/, http://localhost:9876/hotkeys-ui) shows and edits the single-line
; app-window / tab-focus / profile-cycle / split / merge / folder / run hotkeys in this file, and
; rewrites just those lines on Save. Everything else here is left as you wrote it. On first launch
; AltTabSucks adds a set of suggested hotkeys (lib\hotkeys.template.json) below these.

; Key notation: `^`=Ctrl, `!`=Alt, `+`=Shift, `#`=Win

; --- Utilities ---
^!+t:: UnixTimestampToClipboard()

; --- System ---
^!+Esc::   SleepScreens()
^!+,::     ShowSettingsGui()

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: ShowAltTabSucksDebug()

; ---- Local functions ----
SleepScreens() {
    psScript := A_ScriptDir "\lib\screenOff.ps1"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}
