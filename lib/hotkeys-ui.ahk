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
