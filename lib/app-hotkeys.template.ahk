; app-hotkeys.ahk - General application hotkeys
; App-window, browser tab/profile, split/merge, and folder hotkeys now live in the web Hotkeys UI
; (http://localhost:9876/hotkeys-ui -> lib/hotkeys.json). Keep hotkeys here that call AHK functions.

; Key notation: `^`=Ctrl, `!`=Alt, `+`=Shift, `#`=Win
;--- BEGIN SENSITIVE ---
; 
;P1 := "Default" ; Firefox
;P1 := "Default" ; Edge profile 1
;P2 := "Profile 1" ; Edge profile 2
;P1 := "Default" ; Opera
P1 := "Default" ; Brave profile 1
P2 := "Profile 1" ; Brave profile 2
; 
;^!+s:: FocusTab(P2, ["YOUR_URL"],           "https://YOUR_URL")
;^!+j:: FocusTab(P2, ["YOUR_URL","https://YOUR_URL","https://YOUR_URL","https://YOUR_URL"],  "https://YOUR_URL")
;^!+b:: FocusTab(P2, ["YOUR_URL"],           "https://YOUR_URL")
;^+#z:: FocusTab(P2, ["YOUR_URL"],             "https://YOUR_URL")
;^+#w:: FocusTab(P2, ["YOUR_URL"], "https://YOUR_URL")
;^+#b:: OpenIssue("YOUR_URL")
;^+#r:: OpenIssue("YOUR_URL")
; 
;--- END SENSITIVE ---

; --- BEGIN COMMON ---

; Suppress all hotkeys when Moonlight is streaming (UI hotkeys honor this too)
UI_HOTKEYS_SUPPRESS_WHEN := "ahk_exe Moonlight.exe"
#HotIf !WinActive("ahk_exe Moonlight.exe")

; --- Utilities --- (UNIVERSAL)
; ^!+C:: ClipboardToSqlIn()
; ^!+h:: ClipboardCmToFtIn()
^!+t:: UnixTimestampToClipboard()

; --- System ---
^!+Esc::   SleepScreens()
^!+,::     ShowSettingsGui()

; --- Hotkey quick reference (auto-generated from this file) ---
^!+/:: ShowTextGui("Hotkey Reference", _BuildHotkeyRef(), 1250, 45)

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: ShowAltTabSucksDebug()

#HotIf

; ---- Local functions ----
SleepScreens() {
    psScript := A_ScriptDir "\lib\screenOff.ps1"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}

UserName1 := "test.user"
PasswordSecretName1 := "test.password"
^!+=:: {
	SendSecret(PasswordSecretName1)
}
