; app-hotkeys.ahk - hotkey are assigned here.

; Key notation: `^`=Ctrl, `!`=Alt, `+`=Shift, `#`=Win
; ^!+# = Ctrl+Alt+Shift+Win

;--- BEGIN SENSITIVE ---
; 
;P1 := "Default"
;P1 := "Default"
P1 := "Default"
P2 := "Profile 1"
;P2 := "Profile 1"
; UserName1 := "YOUR_VALUE"
; PasswordSecretName1 := "YOUR_VALUE"
; TrayAppPath := "YOUR_VALUE"
; ^!+j:: FocusTab(P2, ["https://YOUR_URL","https://YOUR_URL","https://YOUR_URL","https://YOUR_URL"],  "https://YOUR_URL")
; ^!+b:: FocusTab(P1, ["https://YOUR_URL"],           "https://YOUR_URL")
;^!+z:: FocusTab(P1, ["https://YOUR_URL", "https://YOUR_URL"],             "https://YOUR_URL")
;^!+r:: FocusTab(P1, ["YOUR_URL"],          "https://YOUR_URL")
;^+#c:: FocusTab(P1, ["YOUR_URL"], "https://YOUR_URL")
; ^!+g::OpenGitFolder
; OpenGitFolder() {
;     Run(EnvGet("USERPROFILE") "C:\\YOUR\\PATH")
; }
; 
; ^!+=:: {
; 	SendSecret(PasswordSecretName1)
; }
; 
;--- END SENSITIVE ---

; --- BEGIN COMMON ---

; PuTTY launcher
^!+\:: {
	Run("C:\Program Files\PuTTY\putty.exe")
	Sleep(400)
	Send("{Tab}{Tab}{Tab}{Tab}{Tab}{Down}{Down}{Enter}")
	Sleep(1000)
	SendSecret(UserSecretName1)
}

; Toggle tray popup and click on a button in it. Tested on 1440p and 1080p with no (100%) display scaling applied.
^!+x:: {
	; Set coordinate mode to use screen coordinates
	CoordMode("Mouse", "Screen")
	widthCoeff := 0.0699
	heightCoeff := 0.065
	targetX := A_ScreenWidth - Floor(A_ScreenWidth * widthCoeff) ; edit the decimal to change target
	targetY := A_ScreenHeight - Floor(A_ScreenHeight * heightCoeff) ; edit the decimal to change target
	; MsgBox("W: " . A_ScreenWidth . ", H: " . A_ScreenHeight . ", targetX: " . targetX . ", targetY: " . targetY) ; for debugging  
	Run(TrayAppPath)
	Sleep(600)
	; MouseMove(targetX, targetY) ; for debugging
	MouseClick("left", targetX, targetY)
}

; Browser (NOT UNIVERSAL, only applies when browser window is focused)
!x::  SplitFocusedTab()
!z::  MergeFocusedWindow()

; --- Browser tab focus (profile 1) --- (UNIVERSAL)
;^!+m:: FocusTab(P1, ["google.com/maps","bing.com/maps","apple.com/maps","openstreetmap.org"],     "https://maps.google.com")
; ^!+v:: FocusTab(P1, ["chat.google.com"],     "https://chat.google.com/")
; ^+#v:: FocusTab(P1, ["meet.google.com"], "https://meet.google.com")
;^!+g:: FocusTab(P1, ["mail.google.com","workspace,google.com"],     "https://mail.google.com")
^!+y:: FocusTab(P1, ["youtube.com"],         "https://youtube.com")

^!+k:: FocusTab(P1, ["keep.google.com"], "https://keep.google.com")
^+#g:: FocusTab(P1, ["gemini.google.com"], "https://gemini.google.com")
^!+p:: FocusTab(P1, ["ebay.com"], "https://ebay.com")
^+#y:: FocusTab(P1, ["music.youtube.com"], "https://music.youtube.com")

; --- Browser tab focus (profile 2) ---
; ^!+o:: FocusTab(P1, ["outlook.cloud.microsoft"], "https://outlook.cloud.microsoft")
^+#u:: FocusTab(P1, ["teams.microsoft.com"],     "https://teams.microsoft.com")

; --- Brave window cycling --- (UNIVERSAL)
^!+i::  CycleChromiumProfile(P1)
^+#i::  CycleChromiumProfile(P1)

; --- Utilities --- (UNIVERSAL)
^!+c:: ClipboardToSqlIn()
; ^!+h:: ClipboardCmToFtIn()
^!+t:: UnixTimestampToClipboard()

; --- App window management --- (UNIVERSAL)
; REGULAR APPS
^!+u:: ManageAppWindows("ms-teams.exe", () => LaunchStoreApp("MSTeams_8wekyb3d8bbwe!MSTeams"), "cycle")
^!+n:: ManageAppWindows("notepad++.exe", "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\notepad++", "toggle")
; ^!+d:: ManageAppWindows("discord.exe", EnvGet("USERPROFILE") "\AppData\Roaming\Microsoft\WinDdows\Start Menu\Programs\Discord Inc\Discord", "toggle")
^!+e:: ManageAppWindows("code.exe", "C:\Program Files\Microsoft VS Code\Code.exe", "cycle")
^!+q:: ManageAppWindows("ssms.exe", "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\SSMS.exe", "cycle")
^!+v:: ManageAppWindows("obs64.exe", "C:\Program Files\obs-studio\bin\64bit\obs64.exe", "toggle")
^!+s:: ManageAppWindows("slack.exe", EnvGet("USERPROFILE") "\AppData\Local\slack\slack.exe", "cycle")
^!+m:: ManageAppWindows("devenv.exe", "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\devenv.exe", "cycle")
;   CLASSIC OUTLOOK
^!+o:: ManageAppWindows("outlook.exe", "C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE", "cycle")
; APP STORE APPS - use this ps1 cmd to find needed appId (replace "*Claude" with the app you need):
;   (New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items() | Where-Object { $_.Name -like '*Claude*' } | Select-Object Name, Path, @{N='AppId'; E={$_.ExtendedProperty('System.AppUserModel.ID')}}
; ^!+c:: ManageAppWindows("claude.exe", () => LaunchStoreApp("Claude_pzs8sxrjxfjjc!Claude"), "toggle")
;   NEW OUTLOOK
; ^!+o:: ManageAppWindows("olk.exe", () => LaunchStoreApp("Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows"), "toggle")
; --- Folder shortcuts ---
^!+a::  OpenAppsFolder()
^!+w::  OpenNotSharedFolder()
^!+0::  OpenRDPFolder()
^!+Down::  OpenDownloads()
^!+d::  OpenDesktopFolder()

; --- System ---
^!+Esc:: SleepScreens()
^!+,::   ShowSettingsGui()

; --- Window switcher (handled by window-switcher-core.ahk with SWITCHER_ENABLED guard) ---

; --- Hotkey quick reference (auto-generated from this file) ---
^!+/:: ShowTextGui("Hotkey Reference", _BuildHotkeyRef(), 1250, 45)

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: ShowAltTabSucksDebug()

; ---- Local functions ----

OpenAppsFolder() {
    Run("C:\Program Files\")
}

OpenNotSharedFolder() {
    Run(EnvGet("ONEDRIVE") "\Documents\NotShared\")
}
OpenRDPFolder() {
    Run(EnvGet("ONEDRIVE") "\Desktop\rdp")
}

OpenDesktopFolder() {
    Run(EnvGet("ONEDRIVE") "\Desktop")
}

OpenDownloads() {
    Run(EnvGet("USERPROFILE") "\Downloads")
}

SleepScreens() {
    psScript := A_ScriptDir "\lib\screenOff.ps1"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}
