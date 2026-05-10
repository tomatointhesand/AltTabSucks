; app-hotkeys.ahk - General application hotkeys

; Key notation: `^`=Ctrl, `!`=Alt, `+`=Shift, `#`=Win, `~`=pass-through
;--- BEGIN SENSITIVE ---
; 
;P1 := "Default" ; Firefox
;P1 := "Default" ; Edge profile 1
;P2 := "Profile 1" ; Edge profile 2
;P1 := "Default" ; Opera
P1 := "Default" ; Brave profile 1
P2 := "Profile 1" ; Brave profile 2
; 
; ^!+s:: FocusTab(P2, ["YOUR_URL"],           "https://YOUR_URL")
; ^!+j:: FocusTab(P2, ["https://YOUR_URL","https://YOUR_URL","https://YOUR_URL","https://YOUR_URL"],  "https://YOUR_URL")
; ^!+b:: FocusTab(P2, ["YOUR_URL"],           "https://YOUR_URL")
; ^!+z:: FocusTab(P2, ["YOUR_URL"],             "https://YOUR_URL")
; ^+#w:: FocusTab(P2, ["https://YOUR_URL"], "https://YOUR_URL")
; ^+#c:: FocusTab(P1, ["YOUR_URL"], "https://YOUR_URL")
; ^+#b:: OpenIssue("https://YOUR_URL")
; ^+#r:: OpenIssue("https://YOUR_URL")
; 
;--- END SENSITIVE ---

; --- BEGIN COMMON ---

; Browser (only applies when browser window is focused)
#HotIf WinActive("ahk_class Chrome_WidgetWin_1") || WinActive("ahk_class MozillaWindowClass")
!x::  SplitFocusedTab()
!z::  MergeFocusedWindow()
#HotIf

; --- Browser tab focus (profile 1) --- (UNIVERSAL)
^!+m:: FocusTab(P1, ["google.com/maps","bing.com/maps","apple.com/maps","openstreetmap.org"], "https://maps.google.com")
^!+g:: FocusTab(P1, ["mail.google.com","workspace,google.com"],     "https://mail.google.com")
^!+v:: FocusTab(P1, ["chat.google.com"],                            "https://chat.google.com/")
^+#v:: FocusTab(P1, ["meet.google.com"],                            "https://meet.google.com")
^!+y:: FocusTab(P1, ["www.youtube.com"],                            "https://youtube.com")
^!+x:: FocusTab(P1, ["messages.google.com"],                        "https://messages.google.com")
^!+k:: FocusTab(P1, ["keep.google.com"],                            "https://keep.google.com")
^+#k:: FocusTab(P1, ["calendar.google.com"],                        "https://calendar.google.com")
^+#g:: FocusTab(P1, ["gemini.google.com"],                          "https://gemini.google.com")
^!+p:: FocusTab(P1, ["ebay.com"],                                   "https://ebay.com")
^+#y:: FocusTab(P1, ["music.youtube.com"],                          "https://music.youtube.com")
^!+r:: FocusTab(P1, ["reddit.com"],                                 "https://reddit.com/r/sailing")

; --- Browser tab focus (profile 2) ---
^!+o:: FocusTab(P2, ["outlook.cloud.microsoft"],                    "https://outlook.cloud.microsoft")
^!+u:: FocusTab(P2, ["teams.microsoft.com"],                        "https://teams.microsoft.com")

; --- Brave window cycling --- (UNIVERSAL)
^!+i::  CycleChromiumProfile(P1)
^+#i::  CycleChromiumProfile(P2)

; --- Utilities --- (UNIVERSAL)
; ^!+C:: ClipboardToSqlIn()
; ^!+h:: ClipboardCmToFtIn()
^!+t:: UnixTimestampToClipboard()

; --- App window management --- (UNIVERSAL)
; REGULAR APPS
^!+n:: ManageAppWindows("notepad++.exe", "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\notepad++", "toggle")
^!+d:: ManageAppWindows("discord.exe", EnvGet("USERPROFILE") "\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Discord Inc\Discord", "cycle")
^!+e:: ManageAppWindows("code.exe", EnvGet("USERPROFILE") "\AppData\Local\Programs\Microsoft VS Code\Code.exe", "cycle")
; APP STORE APPS - use this ps1 cmd to find needed appId (replace "*Claude" with the app you need):
; (New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items() | Where-Object { $_.Name -like '*Claude*' } | Select-Object Name, Path, @{N='AppId'; E={$_.ExtendedProperty('System.AppUserModel.ID')}}
^!+c:: ManageAppWindows("claude.exe", () => LaunchStoreApp("Claude_pzs8sxrjxfjjc!Claude"), "toggle")

; --- Folder shortcuts ---
^!+a::  OpenAppsFolder()
^!+Down::  OpenDownloads()
^+#d::  OpenDesktop()

; --- System ---
^!+Esc::   SleepScreens()
^!+,::     ShowSettingsGui()

; --- Window switcher (UNIVERSAL)
!Tab::    ShowWindowSwitcher("down")
!+Tab::   ShowWindowSwitcher("up")
!vkC0::   ShowWindowSwitcher("up")
!WheelDown:: ShowWindowSwitcher("down")
!WheelUp::   ShowWindowSwitcher("up")

; --- Hotkey quick reference (auto-generated from this file) ---
^!+/:: ShowTextGui("Hotkey Reference", _BuildHotkeyRef(), 1250, 45)

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: ShowAltTabSucksDebug()

; ---- Local functions ----
OpenAppsFolder() {
    Run("G:\My Drive\apps-drivers-saves-portable")
}
OpenDownloads() {
    Run(EnvGet("USERPROFILE") "\Downloads")
}
OpenDesktop() {
    Run(EnvGet("USERPROFILE") "\Desktop")
}
SleepScreens() {
    psScript := A_ScriptDir "\lib\screenOff.ps1"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}
