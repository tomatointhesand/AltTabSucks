; app-hotkeys.ahk - General application hotkeys (non-Star Citizen)

; --- Brave tab focus (profile 1) ---
^!+m:: FocusTab("YOUR_BROWSER_PROFILE", "google.com/maps",     "https://YOUR_URL")
^!+v:: FocusTab("YOUR_BROWSER_PROFILE", "chat.google.com",     "https://YOUR_URL")
^!+g:: FocusTab("YOUR_BROWSER_PROFILE", "mail.google.com",     "https://YOUR_URL")
^!+y:: FocusTab("YOUR_BROWSER_PROFILE", "youtube.com",         "https://YOUR_URL")
^!+r:: FocusTab("YOUR_BROWSER_PROFILE", "reddit.com",          "https://YOUR_URL")
^!+x:: FocusTab("YOUR_BROWSER_PROFILE", "messages.google.com", "https://YOUR_URL")
^!+k:: FocusTab("YOUR_BROWSER_PROFILE", "keep.google.com", "https://YOUR_URL")
^!#g:: FocusTab("YOUR_BROWSER_PROFILE", "gemini.google.com", "https://YOUR_URL")
^!#c:: FocusTab("YOUR_BROWSER_PROFILE", "claude.ai", "https://YOUR_URL")
^!+p:: FocusTab("YOUR_BROWSER_PROFILE", "ebay.com", "https://YOUR_URL")

; --- Brave tab focus (profile 2) ---
^!+o:: FocusTab("YOUR_BROWSER_PROFILE", "outlook.cloud.microsoft", "https://YOUR_URL")
^!+u:: FocusTab("YOUR_BROWSER_PROFILE", "teams.microsoft.com",     "https://YOUR_URL")
^!+s:: FocusTab("YOUR_BROWSER_PROFILE", "app.slack.com",           "https://YOUR_URL")
^!+j:: FocusTab("YOUR_BROWSER_PROFILE", "https://YOUR_URL",  "https://YOUR_URL")
^!+b:: FocusTab("YOUR_BROWSER_PROFILE", "bitbucket.org",           "https://YOUR_URL")
^!+z:: FocusTab("YOUR_BROWSER_PROFILE", "app.zoom.us",             "https://YOUR_URL")

; --- Brave window cycling ---
^!+i::  CycleChromiumProfile("YOUR_BROWSER_PROFILE")
^+#i::  CycleChromiumProfile("YOUR_BROWSER_PROFILE")

; --- Utilities ---
^!+C:: ClipboardToSqlIn()
^!+h:: ClipboardCmToFtIn()

; --- App window management ---
^!+n:: ManageAppWindows("notepad++.exe", "C:\YOUR\PATH", "toggle")
^!+d:: ManageAppWindows("discord.exe",   "C:\YOUR\PATH")
^!+e:: ManageAppWindows("cursor.exe",    "C:\YOUR\PATH", "toggle")

^!+a:: {
    run "C:\YOUR\PATH"
    return
}
; -- Disable hardcoded copilot shortcut
^!#+::return

; Sleep screens
^!+Esc:: {
    psScript := psScript := A_ScriptDir "C:\YOUR\PATH"
    Run("powershell.exe -ExecutionPolicy Bypass -File `" " psScript "`"",, "Hide")
}

; --- Debug: show AltTabSucks profile/window state ---
^!+l:: {
    profileMap := GetChromiumProfileDirMap()

    tabDebug := ""
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", "https://YOUR_URL", false)
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
