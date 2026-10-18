; explorer.ahk - focus-or-open for File Explorer folder hotkeys
;
; FocusOrOpenFolder(path) replaces a bare Run(path) in a folder hotkey (see app-hotkeys.ahk's
; "Folder shortcuts"). A bare Run() had no idea whether that folder was already open, so every
; press opened another Explorer window — including several in a row when the key was pressed
; again before the first window had finished appearing.
;
; The decision itself (activate / wait / launch) is _ExplorerFolderAction in explorer-logic.ahk,
; covered by tests/ahk/test-explorer.ahk. This file is only the live-Windows glue around it —
; listing real Explorer windows/tabs via Shell.Application, activating, switching tabs — none of
; which can run under Wine, so it's only verifiable on a real Windows machine.

#Include explorer-logic.ahk

global _explorerLaunchedAt := Map()  ; normalized path -> A_TickCount of last launch (mash guard)

FocusOrOpenFolder(path) {
    key := _NormalizeFolderPath(path)
    decision := _ExplorerFolderAction(path, _ListExplorerFolders(), _explorerLaunchedAt.Get(key, 0), A_TickCount)
    switch decision.action {
        case "launch":
            _explorerLaunchedAt[key] := A_TickCount
            Run(path)
        case "activate":
            hwnd := decision.hwnd
            if WinGetMinMax("ahk_id " hwnd) = -1
                WinRestore("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
            if decision.switchTab
                _SwitchExplorerTab(hwnd, key)
            ShowProfileToast(hwnd, _FolderDisplayName(path), SampleTitlebarColor(hwnd))
        ; "wait": a launch for this folder is still in flight — doing nothing is the point.
    }
}

; One {hwnd, path, isActiveTab} per open Explorer window — per tab on Windows 11 (tabs in one
; window share its hwnd). Shell.Application.Windows() also lists the legacy IE-hosted shell
; windows on some systems; the CabinetWClass check keeps only real File Explorer windows.
; Folders with no filesystem path (This PC, Home, ...) are skipped by _ExplorerFolderAction.
_ListExplorerFolders() {
    result := []
    try shellWindows := ComObject("Shell.Application").Windows()
    catch
        return result
    for w in shellWindows {
        try {
            hwnd := w.HWND
            if WinGetClass("ahk_id " hwnd) != "CabinetWClass"
                continue
            path := w.Document.Folder.Self.Path
        } catch {
            continue
        }
        result.Push({hwnd: hwnd, path: path, isActiveTab: _IsActiveExplorerTab(w, hwnd)})
    }
    return result
}

; Windows 11 Explorer tabs each get their own ShellTabWindowClass child of the window; the first
; one (ShellTabWindowClass1) is the visible, active tab. A tab's own ShellTabWindowClass hwnd
; comes from its IShellBrowser (IOleWindow::GetWindow, vtable slot 3), so the two can be compared.
; Windows 10 Explorer has no tabs and no such control: every window is its own "active tab".
_IsActiveExplorerTab(shellWindow, hwnd) {
    static IID_IShellBrowser := "{000214E2-0000-0000-C000-000000000046}"
    try activeTab := ControlGetHwnd("ShellTabWindowClass1", "ahk_id " hwnd)
    catch
        return true
    try {
        shellBrowser := ComObjQuery(shellWindow, IID_IShellBrowser, IID_IShellBrowser)
        ComCall(3, shellBrowser, "uint*", &thisTab := 0)
        return thisTab = activeTab
    } catch {
        return true
    }
}

; There's no API to select an Explorer tab directly, so step through them with Ctrl+Tab until the
; target folder is the active one — bounded by the window's own tab count, so it can't loop
; forever if the tab closes or navigates away mid-switch.
_SwitchExplorerTab(hwnd, targetKey) {
    tabCount := 0
    for e in _ListExplorerFolders()
        if e.hwnd = hwnd
            tabCount += 1
    if !WinWaitActive("ahk_id " hwnd, , 1)
        return
    Loop tabCount {
        for e in _ListExplorerFolders()
            if e.hwnd = hwnd && e.isActiveTab && _NormalizeFolderPath(e.path) = targetKey
                return
        Send("^{Tab}")
        Sleep(50)
    }
}

; "Downloads" for C:\Users\me\Downloads; the path itself for a drive root ("C:\").
_FolderDisplayName(path) {
    trimmed := RTrim(StrReplace(path, "/", "\"), "\")
    SplitPath(trimmed, &name)
    return name != "" ? name : path
}
