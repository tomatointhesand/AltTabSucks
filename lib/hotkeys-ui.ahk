; hotkeys-ui.ahk - runtime side of the web hotkeys UI (http://localhost:9876/hotkeys-ui).
; On Save the server regenerates lib/hotkeys-ui.generated.ahk from lib/hotkeys.json
; (Server/HotkeysGenerator.ps1); that file calls _UiHotkey() once per binding.

; Registered with Hotkey() at startup rather than as static :: hotkeys, so a bad or duplicate
; binding shows a tray warning instead of failing the whole script load. browserOnly limits it
; to when a browser window is active (split/merge).
_UiHotkey(keys, title, fn, browserOnly := false) {
    HotIf(browserOnly ? _UiBrowserActive : _UiHotkeysAllowed)
    try Hotkey(keys, fn, "On")
    catch as e
        TrayTip(title " (" keys "): " e.Message, "AltTabSucks: UI hotkey not registered", "Iconx")
    HotIf()
}
_UiHotkeysAllowed(*) => UI_HOTKEYS_SUPPRESS_WHEN = "" || !WinActive(UI_HOTKEYS_SUPPRESS_WHEN)
_UiBrowserActive(*) => _UiHotkeysAllowed() && (WinActive("ahk_class Chrome_WidgetWin_1") || WinActive("ahk_class MozillaWindowClass"))

; Startup, via the server (which validates and regenerates hotkeys-ui.generated.ahk the same way
; a UI save does; the watcher below then reloads to apply the result):
;  1. Move convertible static hotkeys from app-hotkeys.ahk into the UI — a no-op once none are left.
;  2. First run with nothing migrated and no lib\hotkeys.json: seed suggested hotkeys from
;     lib\hotkeys.template.json, with __PROFILE__ filled in by the browser's default profile.
_InitUiHotkeys(attempt := 1) {
    tpl := A_ScriptDir "\lib\hotkeys.template.json"
    try {
        resp := _UiServerPost("/migrate-app-hotkeys", "")
        if resp = ""
            return  ; migration failed (already reported) — don't seed over unmigrated hotkeys
        if RegExMatch(resp, '"migrated":\s*(\d+)', &m) && m[1] > 0 {
            TrayTip("Moved " m[1] " hotkeys from app-hotkeys.ahk into the Hotkeys UI. Press Ctrl+Alt+/ to view and edit them.", "AltTabSucks")
            return
        }
        if FileExist(A_ScriptDir "\lib\hotkeys.json") || !FileExist(tpl) || (profile := _DefaultBrowserProfile()) = ""
            return  ; already set up, or no browser configured yet (try again next launch)
        if _UiServerPost("/hotkeys-config", StrReplace(FileRead(tpl, "UTF-8"), "__PROFILE__", JsonEscape(profile))) != ""
            TrayTip("Suggested hotkeys added. Press Ctrl+Alt+/ to view and edit them.", "AltTabSucks")
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

; Reload when a UI save rewrites the generated file.
_UiHotkeysStamp() {
    path := A_ScriptDir "\lib\hotkeys-ui.generated.ahk"
    return FileExist(path) ? FileGetTime(path) "|" FileGetSize(path) : ""
}
_UiHotkeysWatch() {
    global _uiHotkeysLastStamp
    if _UiHotkeysStamp() != _uiHotkeysLastStamp
        Reload()
}
_uiHotkeysLastStamp := _UiHotkeysStamp()
SetTimer(_UiHotkeysWatch, 1000)
