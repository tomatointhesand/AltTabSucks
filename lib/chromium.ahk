; chromium.ahk - Chromium multi-profile window cycling and tab focusing via AltTabSucks
; Reads CHROMIUM_EXE and CHROMIUM_USERDATA from lib/config.ahk (gitignored).

global _chromiumCache           := Map()
global _focusTabLast            := Map()
global _focusTabOpenedAt        := Map()
global _cycleProfileOpenedAt    := Map()
global _chromiumProfileDirCache := Map()
global _chromiumExe             := ""
global _origFgLockTimeout       := 0
global _serverToken             := ""

; Returns array of active-tab titles for the given profile (via AltTabSucks server)
GetProfileWindowTitles(profileName) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", "http://localhost:9876/activetitles?profile=" . profileName, false)
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send()
        result := Trim(StrReplace(http.ResponseText, "`r", ""))
        if result = ""
            return []
        return StrSplit(result, "`n")
    } catch as e {
        ShowTextGui("Error getting profile tabs", e.Message, 600, 10)
        return []
    }
}

; Reads the info_cache section of the configured browser's Local State JSON, or "" on failure
ReadChromiumInfoCache() {
    path := CHROMIUM_USERDATA . "\Local State"
    try
        content := FileRead(path, "UTF-8")
    catch
        return ""
    cacheStart := InStr(content, '"info_cache"')
    return cacheStart ? SubStr(content, cacheStart) : ""
}

; Cache is fully populated at startup by _InitChromiumState - this is now just a lookup
GetChromiumProfileDir(displayName) {
    return _chromiumProfileDirCache.Has(displayName) ? _chromiumProfileDirCache[displayName] : ""
}

; Returns a formatted string of all profile directory -> display name mappings
GetChromiumProfileDirMap() {
    if _chromiumProfileDirCache.Count = 0
        return "(no profiles cached - Local State could not be read at startup)"
    result := ""
    for name, dir in _chromiumProfileDirCache
        result .= dir . " -> " . name . "`n"
    return result
}

; Detects the system's default Chromium-based browser by reading the https UserChoice ProgId
; from the registry, then trying known install paths. Populates name/exePath/userDataPath by
; reference. Returns true on success.
_DetectDefaultBrowserPaths(&name, &exePath, &userDataPath) {
    name := ""
    exePath := ""
    userDataPath := ""
    try
        progId := RegRead("HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId")
    catch
        return false

    localAppData := EnvGet("LOCALAPPDATA")
    pf           := A_ProgramFiles
    pf86         := EnvGet("ProgramFiles(x86)")
    appData      := EnvGet("APPDATA")

    ; Each entry: {id: ProgId prefix, name, exes: [candidates...], data: userdata path}
    browsers := [
        {id: "BraveHTML",    name: "Brave",
         exes: [pf . "\BraveSoftware\Brave-Browser\Application\brave.exe"],
         data: localAppData . "\BraveSoftware\Brave-Browser\User Data"},
        {id: "ChromeHTML",   name: "Chrome",
         exes: [pf . "\Google\Chrome\Application\chrome.exe",
                pf86 . "\Google\Chrome\Application\chrome.exe",
                localAppData . "\Google\Chrome\Application\chrome.exe"],
         data: localAppData . "\Google\Chrome\User Data"},
        {id: "MSEdgeHTM",    name: "Edge",
         exes: [pf86 . "\Microsoft\Edge\Application\msedge.exe",
                pf . "\Microsoft\Edge\Application\msedge.exe"],
         data: localAppData . "\Microsoft\Edge\User Data"},
        {id: "VivaldiHTM",   name: "Vivaldi",
         exes: [localAppData . "\Vivaldi\Application\vivaldi.exe"],
         data: localAppData . "\Vivaldi\User Data"},
        {id: "VivaldiStable", name: "Vivaldi",
         exes: [localAppData . "\Vivaldi\Application\vivaldi.exe"],
         data: localAppData . "\Vivaldi\User Data"},
        {id: "OperaStable",  name: "Opera",
         exes: [localAppData . "\Programs\Opera\opera.exe"],
         data: appData . "\Opera Software\Opera Stable"},
    ]

    for b in browsers {
        if InStr(progId, b.id) != 1
            continue
        for exeCandidate in b.exes {
            if FileExist(exeCandidate) {
                name         := b.name
                exePath      := exeCandidate
                userDataPath := b.data
                return true
            }
        }
    }
    return false
}

; Called at startup: if CHROMIUM_EXE is unset or the exe doesn't exist on disk, auto-detect
; the default browser, write config.ahk with the resolved paths, and show a setup toast.
_AutoConfigIfNeeded() {
    global CHROMIUM_EXE, CHROMIUM_USERDATA
    if CHROMIUM_EXE != "" && FileExist(CHROMIUM_EXE)
        return
    if !_DetectDefaultBrowserPaths(&name, &exePath, &userDataPath) {
        ShowTextGui("Browser auto-detection failed",
            "AltTabSucks could not detect your default Chromium browser.`n`n"
            . "Copy lib\config.template.ahk to lib\config.ahk and fill in the paths.",
            600, 5)
        return
    }
    CHROMIUM_EXE      := exePath
    CHROMIUM_USERDATA := userDataPath
    configPath := A_ScriptDir . "\lib\config.ahk"
    content := "; config.ahk - Auto-configured at first launch. Edit if needed.`n"
             . "; This file is gitignored.`n"
             . "`n"
             . 'global CHROMIUM_EXE      := "' . exePath . '"' . "`n"
             . 'global CHROMIUM_USERDATA := "' . userDataPath . '"' . "`n"
    try {
        if FileExist(configPath)
            FileDelete(configPath)
        FileAppend(content, configPath, "UTF-8")
    }
    ShowSetupToast(name, exePath, userDataPath)
}

; Pushes the profile display-name list to the server so the extension Options page can
; populate a dropdown without the user having to type. Called with a short delay at startup
; to give the server time to finish initialising.
_PostProfilesToServer() {
    global _chromiumProfileDirCache, _serverToken
    if _chromiumProfileDirCache.Count = 0
        return
    parts := ""
    for displayName in _chromiumProfileDirCache {
        escaped := StrReplace(StrReplace(displayName, "\", "\\"), '"', '\"')
        parts .= (parts ? "," : "") . '"' . escaped . '"'
    }
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", "http://localhost:9876/profiles", false)
        http.SetRequestHeader("Content-Type", "application/json")
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send("[" . parts . "]")
    }
    ; Silently ignore — server may not be running yet
}

; One-time startup: derive exe filename from CHROMIUM_EXE and pre-populate profile dir cache
; from the browser's Local State. CHROMIUM_EXE and CHROMIUM_USERDATA are set in config.ahk.
; Restores the foreground-lock timeout saved at startup. Called by OnExit so other
; apps are not left with an unrestricted ability to steal focus after AHK closes.
_RestoreFgLockTimeout(ExitReason, ExitCode) {
    global _origFgLockTimeout
    DllCall("SystemParametersInfo", "UInt", 0x2001, "UInt", 0, "Ptr", _origFgLockTimeout, "UInt", 0)
    return 0  ; 0 = allow exit to proceed
}

_InitChromiumState() {
    global _chromiumExe, _chromiumProfileDirCache, _origFgLockTimeout, _serverToken
    _AutoConfigIfNeeded()

    ; Disable foreground-lock timeout so WinActivate/SwitchToThisWindow can always steal
    ; focus. Default is 200 000 ms which blocks focus-steal for the entire lock period.
    ; Save the original value first so _RestoreFgLockTimeout can put it back on exit.
    DllCall("SystemParametersInfo", "UInt", 0x2000, "UInt", 0, "UIntP", &_origFgLockTimeout, "UInt", 0)
    DllCall("SystemParametersInfo", "UInt", 0x2001, "UInt", 0, "Ptr", 0, "UInt", 0)
    OnExit(_RestoreFgLockTimeout)

    tokenPath := A_ScriptDir . "\Server\token.txt"
    if FileExist(tokenPath)
        _serverToken := Trim(FileRead(tokenPath, "UTF-8"))

    SplitPath(CHROMIUM_EXE, &exeName)
    _chromiumExe := exeName

    content := ReadChromiumInfoCache()
    if content = ""
        return
    pos := 1
    while RegExMatch(content, '"(Default|Profile \d+)":\s*\{', &dm, pos) {
        dirName    := dm[1]
        chunkStart := dm.Pos + dm.Len
        chunk      := SubStr(content, chunkStart, 3000)
        if RegExMatch(chunk, '"name"\s*:\s*"([^"]+)"', &nm) {
            ; Validate: backward search from this name position must land on the same dir key.
            nameAbsPos := chunkStart + nm.Pos - 1
            before     := SubStr(content, 1, nameAbsPos)
            if RegExMatch(before, '[\s\S]*"(Default|Profile \d+)":\s*\{', &dm2) && dm2[1] = dirName
                _chromiumProfileDirCache[nm[1]] := dirName
        }
        pos := dm.Pos + 1
    }
    ; Push profile list to the server with a short delay so the server has time to start.
    SetTimer(_PostProfilesToServer, -2000)
}
_InitChromiumState()

CycleChromiumProfile(profileName) {
    profileTitles := GetProfileWindowTitles(profileName)

    ; Build a cache key from the current titles
    titlesKey := ""
    for title in profileTitles
        titlesKey .= title . "`n"

    ; Use cached HWND list if titles unchanged and all windows still exist
    matchingWindows := []
    if _chromiumCache.Has(profileName) {
        c := _chromiumCache[profileName]
        if c.titlesKey = titlesKey {
            allExist := true
            for hwnd in c.hwnds
                if !WinExist("ahk_id " hwnd) {
                    allExist := false
                    break
                }
            if allExist
                matchingWindows := c.hwnds
        }
    }

    ; Cache miss - enumerate and sort Chromium windows by HWND for stable ordering
    winFilter := "ahk_class Chrome_WidgetWin_1 ahk_exe " . _chromiumExe
    if matchingWindows.Length = 0 && profileTitles.Length > 0 {
        for hwnd in WinGetList(winFilter) {
            winTitle := WinGetTitle("ahk_id " hwnd)
            if winTitle = ""
                continue
            for tabTitle in profileTitles {
                if (tabTitle != "" && InStr(winTitle, tabTitle)) {
                    matchingWindows.Push(hwnd)
                    break
                }
            }
        }
        hwndStr := ""
        for hwnd in matchingWindows
            hwndStr .= hwnd "`n"
        hwndStr := Sort(hwndStr, "N")
        matchingWindows := []
        Loop Parse, hwndStr, "`n" {
            if A_LoopField != ""
                matchingWindows.Push(Integer(A_LoopField))
        }
        _chromiumCache[profileName] := { titlesKey: titlesKey, hwnds: matchingWindows }
    }

    if matchingWindows.Length = 0 {
        if _cycleProfileOpenedAt.Has(profileName) && (A_TickCount - _cycleProfileOpenedAt[profileName]) < 3000
            return
        if !RunChromiumProfile(profileName)
            ShowTextGui("Profile not found", "Could not resolve a Chromium profile directory for '" . profileName . "'.", 600, 5)
        else
            _cycleProfileOpenedAt[profileName] := A_TickCount
        return
    }

    activeHwnd := WinExist("A")
    currentIdx := 0
    for i, hwnd in matchingWindows {
        if hwnd = activeHwnd {
            currentIdx := i
            break
        }
    }
    nextIdx    := Mod(currentIdx, matchingWindows.Length) + 1
    targetHwnd := matchingWindows[nextIdx]

    bgColor := SampleTitlebarColor(targetHwnd)
    WinActivate("ahk_id " targetHwnd)
    ShowProfileToast(targetHwnd, profileName, bgColor)
}

; Returns the first Chromium HWND whose title matches any of the given tab titles
FindHwndByAnyTitle(titles, excludeHwnds := []) {
    winFilter := "ahk_class Chrome_WidgetWin_1 ahk_exe " . _chromiumExe
    for hwnd in WinGetList(winFilter) {
        for ex in excludeHwnds
            if ex = hwnd
                continue 2
        winTitle := WinGetTitle("ahk_id " hwnd)
        for title in titles
            if (title != "" && InStr(winTitle, title))
                return hwnd
    }
    return 0
}

; Focus a specific tab by URL pattern within a profile, cycling if multiple matches exist.
; If no matching tabs exist, opens openUrl in a new tab in an existing profile window.
FocusTab(profileName, urlPattern, openUrl) {
    urlPattern := RegExReplace(urlPattern, "^https?://")
    dbg := "profile=" . profileName . "  url=" . urlPattern . "`n`n"

    ; Steal focus BEFORE any HTTP requests, while AHK still has input eligibility
    ; from the hotkey that just fired. Modifier-key repeats during an HTTP round-trip
    ; can transfer eligibility back to the foreground app before WinActivate runs.
    ; Any visible top-level Chromium window is good enough — the extension handles the
    ; specific tab/window switch below.
    ; Also track whether we arrived from outside the browser so we can reset the cycle index.
    winFilter := "ahk_class Chrome_WidgetWin_1 ahk_exe " . _chromiumExe
    arrivedFromOutside := !WinActive(winFilter)
    if arrivedFromOutside {
        for _hwnd in WinGetList(winFilter) {
            if !(WinGetStyle("ahk_id " _hwnd) & 0x10000000)  ; WS_VISIBLE
                continue
            if DllCall("GetWindow", "Ptr", _hwnd, "UInt", 4, "Ptr")  ; GW_OWNER
                continue
            if WinGetTitle("ahk_id " _hwnd) = ""
                continue
            WinActivate("ahk_id " _hwnd)
            break
        }
    }

    findtabUrl := "http://localhost:9876/findtab?profile=" . profileName . "&url=" . urlPattern
    dbg .= "GET " . findtabUrl . "`n"
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", findtabUrl, false)
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send()
        result := Trim(StrReplace(http.ResponseText, "`r", ""))
        dbg .= "status=" . http.Status . "  body='" . result . "'`n`n"
    } catch as e {
        dbg .= "ERROR: " . e.Message . "`n"
        return
    }

    ; No matching tabs - open a new tab in any existing profile window.
    ; Guard against rapid repeated keypresses opening duplicates while the first
    ; tab is still loading and hasn't been posted back to the server yet.
    if result = "" {
        cooldownKey := profileName . ":" . urlPattern
        if _focusTabOpenedAt.Has(cooldownKey) && (A_TickCount - _focusTabOpenedAt[cooldownKey]) < 2000
            return
        dbg .= "no matching tabs - attempting to open " . openUrl . "`n"
        profileTitles := GetProfileWindowTitles(profileName)
        _focusTabOpenedAt[cooldownKey] := A_TickCount
        if profileTitles.Length = 0 {
            ; No windows exist for this profile — launch the browser with both
            ; the profile directory and the URL so it opens directly to the right tab.
            profileDir := GetChromiumProfileDir(profileName)
            if CHROMIUM_EXE != "" && profileDir != ""
                Run('"' . CHROMIUM_EXE . '" --profile-directory="' . profileDir . '" "' . openUrl . '"')
            return
        }
        hwnd := FindHwndByAnyTitle(profileTitles)
        if hwnd = 0
            return
        WinActivate("ahk_id " hwnd)
        Run(openUrl)
        return
    }

    ; Cycle through matches (each line is "windowId|tabId").
    ; Results are pre-sorted by the server: audible (mic active) first, then leftmost tab.
    ; Reset to index 0 whenever arriving from outside the browser so the best tab is always
    ; the first destination; continue cycling when already inside the browser.
    matchLines := StrSplit(result, "`n")
    matchCount := matchLines.Length
    cacheKey   := profileName . ":" . urlPattern
    if arrivedFromOutside
        _focusTabLast[cacheKey] := 0
    currentIdx := _focusTabLast.Has(cacheKey) ? _focusTabLast[cacheKey] : 0
    nextIdx    := Mod(currentIdx, matchCount)
    _focusTabLast[cacheKey] := nextIdx + 1

    line     := matchLines[nextIdx + 1]
    pipe     := InStr(line, "|")
    windowId := Integer(SubStr(line, 1, pipe - 1))
    tabId    := Integer(SubStr(line, pipe + 1))

    ; POST switch command - extension picks it up on its next poll and handles focus natively
    escapedProfile := StrReplace(StrReplace(profileName, "\", "\\"), '"', '\"')
    postBody := '{"profile":"' . escapedProfile . '","windowId":' . windowId . ',"tabId":' . tabId . '}'
    http2 := ComObject("WinHttp.WinHttpRequest.5.1")
    http2.Open("POST", "http://localhost:9876/switchtab", false)
    http2.SetRequestHeader("Content-Type", "application/json")
    http2.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
    http2.Send(postBody)

    ; Poll every 50ms until a Chromium window becomes active (meaning the extension has
    ; completed the switch), then show the toast on it. Timeout after 1.5s.
    _label    := profileName
    _deadline := A_TickCount + 1500
    SetTimer(() => _WaitChromiumActiveAndToast(_label, _deadline), -50)
}

; Polls until a Chromium window is the active foreground window, then shows the toast.
; Uses chained one-shot timers to avoid blocking the AHK thread.
_WaitChromiumActiveAndToast(profileName, deadline) {
    h := WinActive("ahk_class Chrome_WidgetWin_1 ahk_exe " . _chromiumExe)
    if h {
        ShowProfileToast(h, profileName, SampleTitlebarColor(h))
        return
    }
    if A_TickCount < deadline
        SetTimer(() => _WaitChromiumActiveAndToast(profileName, deadline), -50)
}

; Launches the configured Chromium browser with the given profile display name.
; Returns true on success, false if the profile dir could not be resolved.
RunChromiumProfile(profileName) {
    profileDir := GetChromiumProfileDir(profileName)
    if CHROMIUM_EXE = "" || profileDir = ""
        return false
    Run('"' . CHROMIUM_EXE . '" --profile-directory="' . profileDir . '"')
    return true
}
