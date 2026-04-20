; firefox.ahk - Firefox multi-profile window cycling and tab focusing via AltTabSucks
; Reads FIREFOX_EXE and FIREFOX_PROFILE_INI from lib/config.ahk (gitignored).

global _firefoxCache             := Map()
global _focusTabLastFF           := Map()
global _focusTabOpenedAtFF       := Map()
global _cycleProfileOpenedAtFF   := Map()
global _firefoxProfileDirCache   := Map()

; Parses Firefox's profiles.ini and returns a Map of displayName -> absolute profile path
ReadFirefoxProfilesInfo() {
    result  := Map()
    iniPath := FIREFOX_PROFILE_INI
    if !FileExist(iniPath)
        return result
    iniDir := ""
    SplitPath(iniPath, , &iniDir)

    content := FileRead(iniPath, "UTF-8")
    pos     := 1
    while RegExMatch(content, "\[Profile\d+\]", &sm, pos) {
        sectionStart := sm.Pos + sm.Len
        nextBracket  := InStr(content, "[", , sectionStart)
        chunk        := nextBracket ? SubStr(content, sectionStart, nextBracket - sectionStart)
                                    : SubStr(content, sectionStart)

        if RegExMatch(chunk, "(?m)^Name=(.+)$", &nm) && RegExMatch(chunk, "(?m)^Path=(.+)$", &pm) {
            displayName := Trim(nm[1])
            rawPath     := Trim(pm[1])
            if RegExMatch(chunk, "(?m)^IsRelative=(\d+)", &irm)
                isRelative := irm[1] != "0"
            else
                isRelative := true
            absPath := isRelative ? (iniDir . "\" . StrReplace(rawPath, "/", "\"))
                                  : StrReplace(rawPath, "/", "\")
            result[displayName] := absPath
        }
        pos := sm.Pos + 1
    }
    return result
}

GetFirefoxProfileDir(displayName) {
    return _firefoxProfileDirCache.Has(displayName) ? _firefoxProfileDirCache[displayName] : ""
}

GetFirefoxProfileDirMap() {
    if _firefoxProfileDirCache.Count = 0
        return "(no Firefox profiles cached - profiles.ini could not be read at startup)"
    result := ""
    for name, dir in _firefoxProfileDirCache
        result .= dir . " -> " . name . "`n"
    return result
}

_PostFirefoxProfilesToServer() {
    global _firefoxProfileDirCache, _serverToken
    if _firefoxProfileDirCache.Count = 0
        return
    parts := ""
    for displayName in _firefoxProfileDirCache {
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
}

_InitFirefoxState() {
    global _firefoxProfileDirCache
    if FIREFOX_EXE = "" || !FileExist(FIREFOX_EXE)
        return
    _firefoxProfileDirCache := ReadFirefoxProfilesInfo()
    SetTimer(_PostFirefoxProfilesToServer, -2000)
}
_InitFirefoxState()

CycleFirefoxProfile(profileName) {
    profileTitles := GetProfileWindowTitles(profileName)

    titlesKey := ""
    for title in profileTitles
        titlesKey .= title . "`n"

    matchingWindows := []
    if _firefoxCache.Has(profileName) {
        c := _firefoxCache[profileName]
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

    winFilter := "ahk_class MozillaWindowClass ahk_exe firefox.exe"
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
        _firefoxCache[profileName] := { titlesKey: titlesKey, hwnds: matchingWindows }
    }

    if matchingWindows.Length = 0 {
        ; Server had no title data for this profile — fall back to all visible Firefox windows
        ; rather than launching a new instance. This handles the case where the extension
        ; hasn't posted yet or the profile name doesn't match exactly.
        for hwnd in WinGetList(winFilter) {
            if !(WinGetStyle("ahk_id " hwnd) & 0x10000000)
                continue
            if DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")
                continue
            if WinGetTitle("ahk_id " hwnd) = ""
                continue
            matchingWindows.Push(hwnd)
        }
    }

    if matchingWindows.Length = 0 {
        if _cycleProfileOpenedAtFF.Has(profileName) && (A_TickCount - _cycleProfileOpenedAtFF[profileName]) < 3000
            return
        RunFirefoxProfile(profileName)
        _cycleProfileOpenedAtFF[profileName] := A_TickCount
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

; Returns the first Firefox HWND whose title matches any of the given tab titles
FindHwndByAnyTitleFF(titles, excludeHwnds := []) {
    winFilter := "ahk_class MozillaWindowClass ahk_exe firefox.exe"
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

; Focus a specific tab by URL pattern within a Firefox profile, cycling if multiple matches exist.
; If no matching tabs exist, opens openUrl in a new tab in an existing profile window.
; urlPatterns may be a single string or an Array of strings.
FocusTabFirefox(profileName, urlPatterns, openUrl) {
    if !(urlPatterns is Array)
        urlPatterns := [urlPatterns]
    cleanPatterns := []
    for p in urlPatterns
        cleanPatterns.Push(RegExReplace(p, "^https?://"))

    patternKey := ""
    for p in cleanPatterns
        patternKey .= (patternKey ? "|" : "") . p

    winFilter := "ahk_class MozillaWindowClass ahk_exe firefox.exe"

    ; Fast path: Firefox not running — skip server queries (stale data would produce
    ; a /switchtab POST that nobody picks up) and launch directly.
    firefoxRunning := false
    for _hwnd in WinGetList(winFilter) {
        if !(WinGetStyle("ahk_id " _hwnd) & 0x10000000)
            continue
        if DllCall("GetWindow", "Ptr", _hwnd, "UInt", 4, "Ptr")
            continue
        if WinGetTitle("ahk_id " _hwnd) = ""
            continue
        firefoxRunning := true
        break
    }
    if !firefoxRunning {
        cooldownKey := profileName . ":" . patternKey
        if _focusTabOpenedAtFF.Has(cooldownKey) && (A_TickCount - _focusTabOpenedAtFF[cooldownKey]) < 2000
            return
        _focusTabOpenedAtFF[cooldownKey] := A_TickCount
        Run('"' . FIREFOX_EXE . '" -P "' . profileName . '" "' . openUrl . '"')
        return
    }

    arrivedFromOutside := !WinActive(winFilter)
    if arrivedFromOutside {
        for _hwnd in WinGetList(winFilter) {
            if !(WinGetStyle("ahk_id " _hwnd) & 0x10000000)
                continue
            if DllCall("GetWindow", "Ptr", _hwnd, "UInt", 4, "Ptr")
                continue
            if WinGetTitle("ahk_id " _hwnd) = ""
                continue
            WinActivate("ahk_id " _hwnd)
            break
        }
    }

    matchLines := []
    seen       := Map()
    for pattern in cleanPatterns {
        try {
            http := ComObject("WinHttp.WinHttpRequest.5.1")
            http.Open("GET", "http://localhost:9876/findtab?profile=" . profileName . "&url=" . pattern, false)
            http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
            http.Send()
            body := Trim(StrReplace(http.ResponseText, "`r", ""))
            if body != "" {
                for line in StrSplit(body, "`n") {
                    if !seen.Has(line) {
                        seen[line] := true
                        matchLines.Push(line)
                    }
                }
            }
        } catch {
            return
        }
    }

    if matchLines.Length = 0 {
        cooldownKey := profileName . ":" . patternKey
        if _focusTabOpenedAtFF.Has(cooldownKey) && (A_TickCount - _focusTabOpenedAtFF[cooldownKey]) < 2000
            return
        _focusTabOpenedAtFF[cooldownKey] := A_TickCount
        ; Find any visible Firefox window — if one exists, route the URL open through
        ; the extension (POST openUrl) to avoid "Firefox is already running" errors.
        hwnd := 0
        for _hwnd in WinGetList("ahk_class MozillaWindowClass ahk_exe firefox.exe") {
            if !(WinGetStyle("ahk_id " _hwnd) & 0x10000000)
                continue
            if DllCall("GetWindow", "Ptr", _hwnd, "UInt", 4, "Ptr")
                continue
            if WinGetTitle("ahk_id " _hwnd) = ""
                continue
            hwnd := _hwnd
            break
        }
        if hwnd != 0 {
            WinActivate("ahk_id " hwnd)
            postBody := '{"profile":"' . JsonEscape(profileName) . '","openUrl":"' . JsonEscape(openUrl) . '"}'
            try {
                http := ComObject("WinHttp.WinHttpRequest.5.1")
                http.Open("POST", "http://localhost:9876/switchtab", false)
                http.SetRequestHeader("Content-Type", "application/json")
                http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
                http.Send(postBody)
            }
            return
        }
        ; No Firefox windows at all — safe to launch a new instance with -P
        Run('"' . FIREFOX_EXE . '" -P "' . profileName . '" "' . openUrl . '"')
        return
    }

    matchCount := matchLines.Length
    cacheKey   := profileName . ":" . patternKey
    if arrivedFromOutside
        _focusTabLastFF[cacheKey] := 0
    currentIdx := _focusTabLastFF.Has(cacheKey) ? _focusTabLastFF[cacheKey] : 0
    nextIdx    := Mod(currentIdx, matchCount)
    _focusTabLastFF[cacheKey] := nextIdx + 1

    line     := matchLines[nextIdx + 1]
    pipe     := InStr(line, "|")
    windowId := Integer(SubStr(line, 1, pipe - 1))
    tabId    := Integer(SubStr(line, pipe + 1))

    escapedProfile := StrReplace(StrReplace(profileName, "\", "\\"), '"', '\"')
    postBody := '{"profile":"' . escapedProfile . '","windowId":' . windowId . ',"tabId":' . tabId . '}'
    http2 := ComObject("WinHttp.WinHttpRequest.5.1")
    http2.Open("POST", "http://localhost:9876/switchtab", false)
    http2.SetRequestHeader("Content-Type", "application/json")
    http2.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
    http2.Send(postBody)

    _label    := profileName
    _deadline := A_TickCount + 1500
    SetTimer(() => _WaitFirefoxActiveAndToast(_label, _deadline), -50)
}

_WaitFirefoxActiveAndToast(profileName, deadline) {
    h := WinActive("ahk_class MozillaWindowClass ahk_exe firefox.exe")
    if h {
        ShowProfileToast(h, profileName, SampleTitlebarColor(h))
        return
    }
    if A_TickCount < deadline
        SetTimer(() => _WaitFirefoxActiveAndToast(profileName, deadline), -50)
}

; Launches Firefox with the given profile display name using -P flag.
RunFirefoxProfile(profileName) {
    if FIREFOX_EXE = ""
        return false
    Run('"' . FIREFOX_EXE . '" -P "' . profileName . '"')
    return true
}
