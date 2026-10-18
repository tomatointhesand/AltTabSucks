; explorer-logic.ahk - pure decision logic behind FocusOrOpenFolder (lib/explorer.ahk).
;
; Kept separate from explorer.ahk on purpose: nothing in here touches a real window, COM object,
; or another lib/ file, so tests/ahk/test-explorer.ahk can #Include it on its own and run it
; anywhere — including on Linux under Wine (dev-scripts/run-ahk-tests.sh), where there's no real
; Explorer shell to talk to. explorer.ahk gathers the live data, calls into this, and acts on the
; answer.

; Lowercased, forward slashes -> backslashes, surrounding whitespace and trailing backslashes
; removed. Windows paths are case-insensitive, and the hotkeys pass paths in whatever form they
; were written ("C:\Program Files\", EnvGet("ONEDRIVE") "\Desktop", ...) while
; Shell.Application reports them without a trailing backslash. A drive root normalizes to "c:"
; whether written "C:\", "C:" or "C:/".
_NormalizeFolderPath(path) {
    return RTrim(StrLower(Trim(StrReplace(path, "/", "\"))), "\")
}

; Decides what a folder hotkey should do, given:
;   targetPath     - the folder the hotkey opens
;   openWindows    - Array of {hwnd, path, isActiveTab}, one per open Explorer window — or per tab
;                    on Windows 11, where tabs in the same window share an hwnd
;   lastLaunchTick - A_TickCount when this hotkey last launched this folder, 0 if never
;   nowTick        - current A_TickCount
;   cooldownMs     - how long after a launch to wait for its window rather than launch again
;
; Returns {action, hwnd, switchTab}:
;   "activate" - hwnd shows the folder (switchTab: true if only in a background tab)
;   "wait"     - nothing shows it yet, but a launch for it is still in flight: do nothing.
;                Without this, each press while the first window is still appearing launched
;                another duplicate.
;   "launch"   - nothing shows it and no recent launch: open it
;
; Exact folder matches only — a subfolder ("C:\Program Files\Common Files") or a sibling with the
; target as a prefix ("C:\Program Files (x86)") is a different folder. Among several matches, a
; window where the folder is already the active tab beats one where it's a background tab;
; otherwise the first match wins.
_ExplorerFolderAction(targetPath, openWindows, lastLaunchTick, nowTick, cooldownMs := 3000) {
    target := _NormalizeFolderPath(targetPath)
    best := 0
    for w in openWindows {
        p := _NormalizeFolderPath(w.path)
        ; No filesystem path (This PC, Home, Recycle Bin are "::{CLSID}" or empty) — skip.
        if p = "" || SubStr(p, 1, 2) = "::" || p != target
            continue
        if w.isActiveTab {
            best := w
            break
        }
        if !best
            best := w
    }
    if best
        return {action: "activate", hwnd: best.hwnd, switchTab: !best.isActiveTab}
    if lastLaunchTick && (nowTick - lastLaunchTick) < cooldownMs
        return {action: "wait", hwnd: 0, switchTab: false}
    return {action: "launch", hwnd: 0, switchTab: false}
}
