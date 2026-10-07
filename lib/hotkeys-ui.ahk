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

; First run (no lib\hotkeys.json yet): seed suggested hotkeys from lib\hotkeys.template.json,
; with __PROFILE__ filled in by the browser's default profile. Saved through the server like a UI
; save, so they're validated and generated the same way and the watcher below reloads to apply them.
_SeedUiHotkeys(attempt := 1) {
    tpl := A_ScriptDir "\lib\hotkeys.template.json"
    if FileExist(A_ScriptDir "\lib\hotkeys.json") || !FileExist(tpl)
        return
    if (profile := _DefaultBrowserProfile()) = ""
        return  ; no browser configured yet — try again next launch
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", "http://localhost:9876/hotkeys-config", false)
        http.SetRequestHeader("Content-Type", "application/json")
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send(StrReplace(FileRead(tpl, "UTF-8"), "__PROFILE__", JsonEscape(profile)))
        if http.Status = 200 {
            TrayTip("Suggested hotkeys added. Press Ctrl+Alt+/ to view and edit them.", "AltTabSucks")
            return
        }
    }
    if attempt < 10  ; server may still be starting
        SetTimer(() => _SeedUiHotkeys(attempt + 1), -3000)
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
SetTimer(_SeedUiHotkeys, -3000)

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
