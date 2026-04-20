; app-hotkeys.ahk - General application hotkeys

; Key notation: `^`=Ctrl, `!`=Alt, `+`=Shift, `#`=Win, `~`=pass-through
;--- BEGIN SENSITIVE ---

;P1 := "Default"
P1 := "Default"
P2 := "Profile 1"
^!+s:: FocusTab(P2, ["YOUR_URL"],           "https://YOUR_URL")
^!+j:: FocusTab(P2, ["https://YOUR_URL","https://YOUR_URL","https://YOUR_URL","https://YOUR_URL"],  "https://YOUR_URL")
^!+b:: FocusTab(P2, ["YOUR_URL"],           "https://YOUR_URL")
^!+z:: FocusTab(P2, ["YOUR_URL"],             "https://YOUR_URL")

;--- END SENSITIVE ---

; --- BEGIN COMMON ---

; --- Brave tab focus (profile 1) ---
^!+m:: FocusTab(P1, ["google.com/maps","bing.com/maps","apple.com/maps","openstreetmap.org"],     "https://maps.google.com")
^!+v:: FocusTab(P1, ["chat.google.com"],     "https://chat.google.com/")
^+#v:: FocusTab(P1, ["meet.google.com"], "https://meet.google.com")
^!+g:: FocusTab(P1, ["mail.google.com","workspace,google.com"],     "https://mail.google.com")
^!+y:: FocusTab(P1, ["youtube.com"],         "https://youtube.com")
^!+r:: FocusTab(P1, ["reddit.com"],          "https://reddit.com/r/sailing")
^!+x:: FocusTab(P1, ["messages.google.com"], "https://messages.google.com")
^!+k:: FocusTab(P1, ["keep.google.com"], "https://keep.google.com")
^+#g:: FocusTab(P1, ["gemini.google.com"], "https://gemini.google.com")
^+#c:: FocusTab(P1, ["claude.ai"], "https://claude.ai")
^!+p:: FocusTab(P1, ["ebay.com"], "https://ebay.com")

; --- Brave tab focus (profile 2) ---
^!+o:: FocusTab(P2, ["outlook.cloud.microsoft"], "https://outlook.cloud.microsoft")
^!+u:: FocusTab(P2, ["teams.microsoft.com"],     "https://teams.microsoft.com")

; --- Brave window cycling ---
^!+i::  CycleChromiumProfile(P1)
^+#i::  CycleChromiumProfile(P2)

; --- Utilities ---
; ^!+C:: ClipboardToSqlIn()
; ^!+h:: ClipboardCmToFtIn()

; --- App window management ---
; REGULAR APPS
^!+n:: ManageAppWindows("notepad++.exe", "C:\ProgramData\Microsoft\Windows\Start Menu\Programs", "toggle")
^!+d:: ManageAppWindows("discord.exe", EnvGet("USERPROFILE") "\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Discord Inc\Discord")
^!+e:: ManageAppWindows("code.exe", EnvGet("USERPROFILE") "\AppData\Local\Programs\Microsoft VS Code\Code.exe", "toggle")
; APP STORE APPS - use this ps1 cmd to find needed appId (replace "*Claude" with the app you need):
; (New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items() | Where-Object { $_.Name -like '*Claude*' } | Select-Object Name, Path, @{N='AppId'; E={$_.ExtendedProperty('System.AppUserModel.ID')}}  
^!+c:: ManageAppWindows("claude.exe", () => LaunchStoreApp("Claude_pzs8sxrjxfjjc!Claude"), "toggle")   

; -- Folder shortcuts
^!+a:: {
    run "G:\My Drive\apps-drivers-saves-portable"
    return
}

; Sleep screens
^!+Esc:: {
    psScript := psScript := A_ScriptDir "\lib\screenOff.ps1"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}

; --- Hotkey quick reference (auto-generated from this file) ---
^!+/:: ShowTextGui("Hotkey Reference", _BuildHotkeyRef(), 1250, 28)

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: {
    profileMap := GetChromiumProfileDirMap()

    tabDebug := ""
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", "http://localhost:9876/debugtabs", false)
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send()
        if http.Status = 200
            tabDebug := Trim(StrReplace(http.ResponseText, "`r", ""))
        else
            tabDebug := "(HTTP " . http.Status . " - endpoint missing? restart the PS server)"
        if tabDebug = ""
            tabDebug := "(store empty - switch any browser tab to trigger a re-post"
    } catch {
        tabDebug := "(server not running)"
    }

    ShowTextGui("AltTabSucks Debug", "=== Profile Directories ===`n" . profileMap . "`n=== Tabs ===`n" . tabDebug, 900, 30)
}

