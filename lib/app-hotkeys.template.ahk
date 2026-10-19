; app-hotkeys.ahk - General application hotkeys
; The web Hotkeys UI (Ctrl+Alt+/, http://localhost:9876/hotkeys-ui) shows and edits the single-line
; app-window / tab-focus / profile-cycle / split / merge / run hotkeys in this file, and rewrites
; just those lines on Save. Everything else here is left as you wrote it.

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

; Suppress all hotkeys when Moonlight is streaming
#HotIf !WinActive("ahk_exe Moonlight.exe")

; --- Utilities --- (UNIVERSAL)
; ^!+C:: ClipboardToSqlIn()
; ^!+h:: ClipboardCmToFtIn()
^!+t:: UnixTimestampToClipboard()

; --- System ---
^!+Esc::   SleepScreens()
^!+,::     ShowSettingsGui()

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: ShowAltTabSucksDebug()

#HotIf

; ---- Local functions ----
SleepScreens() {
    psScript := A_ScriptDir "\lib\screenOff.ps1"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}

