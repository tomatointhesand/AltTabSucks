; hotkeys-ui.ahk - runtime side of the web hotkeys UI (http://localhost:9876/hotkeys-ui).
; lib/app-hotkeys.ahk is the UI's source of truth: the server parses its recognizable single-line
; hotkeys for the page and rewrites just those lines on Save (Server/AppHotkeys.ps1). This file
; reloads the script when app-hotkeys.ahk changes.

; Startup, via the server: folds a leftover lib\hotkeys.json from the earlier JSON-based UI back
; into app-hotkeys.ahk, or on a file with no hotkeys yet adds the starter set from
; lib\hotkeys.template.json with __PROFILE__ filled in by the browser's default profile. Each
; happens once; the watcher below then reloads to apply the result.
_InitUiHotkeys(attempt := 1) {
    try {
        resp := _UiServerPost("/init-hotkeys", '{"profile":"' JsonEscape(_DefaultBrowserProfile()) '"}')
        if resp = ""
            return
        dropped := RegExMatch(resp, '"dropped":\[[^\]]+\]') ? " Some couldn't be added - see the Hotkeys UI save report." : ""
        if RegExMatch(resp, '"folded":\s*(\d+)', &m) && m[1] > 0
            TrayTip("Moved " m[1] " Hotkeys UI bindings into app-hotkeys.ahk." dropped " Press Ctrl+Alt+/ to view and edit them.", "AltTabSucks")
        else if RegExMatch(resp, '"seeded":\s*(\d+)', &m) && m[1] > 0
            TrayTip("Suggested hotkeys added to app-hotkeys.ahk." dropped " Press Ctrl+Alt+/ to view and edit them.", "AltTabSucks")
    } catch {
        if attempt < 10  ; server may still be starting
            SetTimer(() => _InitUiHotkeys(attempt + 1), -3000)
    }
}
; POSTs to the local server. Throws if it can't be reached; on an error response shows it and
; returns "".
_UiServerPost(path, body) {
    http := ComObject("WinHttp.WinHttpRequest.5.1")
    http.Open("POST", "http://localhost:9876" path, false)
    http.SetRequestHeader("Content-Type", "application/json")
    http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
    http.Send(body)
    if http.Status = 200
        return http.ResponseText
    TrayTip(path ": HTTP " http.Status " " http.ResponseText, "AltTabSucks: Hotkeys UI", "Iconx")
    return ""
}
; "Default"-dir profile for Chromium browsers, "default-release" (or the first) for Firefox.
_DefaultBrowserProfile() {
    cache := CHROMIUM_EXE != "" ? _chromiumProfileDirCache : _firefoxProfileDirCache
    for name, dir in cache
        if dir = "Default" || name = "default-release"
            return name
    for name in cache
        return name
    return ""
}
SetTimer(_InitUiHotkeys, -3000)

; Reload when app-hotkeys.ahk changes (a UI save or a hand edit) - but only once the whole script
; validates. Reload() into a file with an error would stop every hotkey behind an error dialog;
; instead the running script keeps going and the error is shown until the file is fixed.
_UiHotkeysStamp() {
    path := A_ScriptDir "\lib\app-hotkeys.ahk"
    return FileExist(path) ? FileGetTime(path) "|" FileGetSize(path) : ""
}
_UiHotkeysWatch() {
    global _uiHotkeysLastStamp
    if (stamp := _UiHotkeysStamp()) = _uiHotkeysLastStamp
        return
    _uiHotkeysLastStamp := stamp
    if (err := _ValidateScript()) = ""
        Reload()
    else
        TrayTip(SubStr(err, 1, 250), "AltTabSucks: app-hotkeys.ahk not reloaded", "Iconx")
}
; Load-checks the script in a separate process (/Validate doesn't touch this running instance).
; Returns its error text, or "" if it would load.
_ValidateScript() {
    errFile := A_Temp "\AltTabSucks-validate.txt"
    try FileDelete(errFile)
    code := RunWait(A_ComSpec ' /c ""' A_AhkPath '" /ErrorStdOut=UTF-8 /Validate "' A_ScriptFullPath '" 2> "' errFile '""', , "Hide")
    err := FileExist(errFile) ? Trim(FileRead(errFile, "UTF-8"), "`r`n ") : ""
    try FileDelete(errFile)
    return code = 0 ? "" : (err != "" ? err : "exit code " code)
}
_uiHotkeysLastStamp := _UiHotkeysStamp()
SetTimer(_UiHotkeysWatch, 1000)
