; test-explorer.ahk - tests for lib/explorer-logic.ahk's pure decision logic (_ExplorerFolderAction).
;
; Only the decision is tested here, not the COM/window glue around it (FocusOrOpenFolder):
; given the target folder, the Explorer windows/tabs currently open, and when this folder was
; last launched, should the hotkey activate an existing window, launch a new one, or wait? That
; makes the tests independent of a real Explorer shell, so they run on Linux under Wine as well
; as on Windows. See dev-scripts/run-ahk-tests.sh.
;
; openWindows entries mirror what FocusOrOpenFolder gathers from Shell.Application.Windows():
; {hwnd, path, isActiveTab}. On Windows 11 every tab is its own entry, and tabs in the same
; window share an hwnd.

#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_ScriptDir%\assert.ahk
#Include %A_ScriptDir%\..\..\lib\explorer-logic.ahk

Win(hwnd, path, isActiveTab := true) => ({hwnd: hwnd, path: path, isActiveTab: isActiveTab})

NOW := 100000
NEVER := 0

; ---- basics ---------------------------------------------------------------------------------

r := _ExplorerFolderAction("C:\Program Files", [], NEVER, NOW)
AssertEq(r.action, "launch", "nothing open, never launched -> launch")

r := _ExplorerFolderAction("C:\Program Files", [Win(111, "C:\Program Files")], NEVER, NOW)
AssertEq(r.action, "activate", "window already showing the target -> activate (the reported bug: this used to launch a duplicate)")
AssertEq(r.hwnd, 111, "  ...and activates that window")
AssertEq(r.switchTab, false, "  ...without a tab switch when it's the active tab")

r := _ExplorerFolderAction("C:\Program Files", [Win(222, "C:\Users\dab\Downloads")], NEVER, NOW)
AssertEq(r.action, "launch", "only an unrelated folder open -> launch, don't cycle to the unrelated window")

r := _ExplorerFolderAction("C:\Program Files", [Win(333, "C:\Program Files\Common Files")], NEVER, NOW)
AssertEq(r.action, "launch", "a subfolder of the target is not a match")

r := _ExplorerFolderAction("C:\Program Files", [Win(444, "C:\Program Files (x86)")], NEVER, NOW)
AssertEq(r.action, "launch", "a sibling sharing the target as a prefix is not a match")

; ---- path normalization ---------------------------------------------------------------------
; Shell.Application reports paths without a trailing backslash, but the hotkeys pass them in
; whatever form they were written ("C:\Program Files\", EnvGet(...) "\Desktop", ...).

r := _ExplorerFolderAction("C:\Program Files\", [Win(111, "C:\Program Files")], NEVER, NOW)
AssertEq(r.action, "activate", "trailing backslash on the target still matches")

r := _ExplorerFolderAction("c:\program files", [Win(111, "C:\Program Files")], NEVER, NOW)
AssertEq(r.action, "activate", "matching is case-insensitive (Windows paths are)")

r := _ExplorerFolderAction("C:/Program Files/", [Win(111, "C:\Program Files")], NEVER, NOW)
AssertEq(r.action, "activate", "forward slashes still match")

r := _ExplorerFolderAction("  C:\Program Files  ", [Win(111, "C:\Program Files")], NEVER, NOW)
AssertEq(r.action, "activate", "surrounding whitespace is ignored")

r := _ExplorerFolderAction("C:\", [Win(555, "C:\")], NEVER, NOW)
AssertEq(r.action, "activate", "drive root matches itself")

r := _ExplorerFolderAction("C:", [Win(555, "C:\")], NEVER, NOW)
AssertEq(r.action, "activate", "drive root without a backslash matches")

r := _ExplorerFolderAction("C:\", [Win(666, "C:\Windows")], NEVER, NOW)
AssertEq(r.action, "launch", "drive root does not match a folder on that drive")

; Entries Explorer reports with no filesystem path (This PC, Home, Recycle Bin — a "::{CLSID}"
; or empty string) must be skipped, not treated as a match for anything.
r := _ExplorerFolderAction("C:\Program Files", [Win(777, ""), Win(778, "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}")], NEVER, NOW)
AssertEq(r.action, "launch", "entries without a real path are ignored")

; ---- mashing the hotkey (the other reported bug) ---------------------------------------------
; Run() returns immediately but the new window takes a moment to appear in
; Shell.Application.Windows(); every press in that gap used to launch another duplicate.

r := _ExplorerFolderAction("C:\Program Files", [], NOW - 500, NOW)
AssertEq(r.action, "wait", "pressed again 500ms after launching, window not up yet -> wait, don't launch a dupe")

r := _ExplorerFolderAction("C:\Program Files", [], NOW - 2999, NOW)
AssertEq(r.action, "wait", "still inside the default 3s cooldown -> wait")

r := _ExplorerFolderAction("C:\Program Files", [], NOW - 5000, NOW)
AssertEq(r.action, "launch", "cooldown expired and still nothing open -> launch again (never blocked forever)")

r := _ExplorerFolderAction("C:\Program Files", [], NOW - 500, NOW, 200)
AssertEq(r.action, "launch", "cooldown length is configurable")

r := _ExplorerFolderAction("C:\Program Files", [Win(111, "C:\Program Files")], NOW - 500, NOW)
AssertEq(r.action, "activate", "window appeared during the cooldown -> activate it rather than waiting")
AssertEq(r.hwnd, 111, "  ...the window that appeared")

; ---- Windows 11 tabs ------------------------------------------------------------------------

r := _ExplorerFolderAction("C:\Program Files", [Win(888, "C:\Users\dab\Downloads", true), Win(888, "C:\Program Files", false)], NEVER, NOW)
AssertEq(r.action, "activate", "target open in a background tab -> activate that window")
AssertEq(r.hwnd, 888, "  ...the window holding the tab")
AssertEq(r.switchTab, true, "  ...and ask for a switch to that tab")

r := _ExplorerFolderAction("C:\Program Files", [Win(901, "C:\Program Files", false), Win(902, "C:\Program Files", true)], NEVER, NOW)
AssertEq(r.hwnd, 902, "target open twice -> prefer the window where it's already the active tab")
AssertEq(r.switchTab, false, "  ...so no tab switch is needed")

r := _ExplorerFolderAction("C:\Program Files", [Win(903, "C:\Program Files", true), Win(904, "C:\Program Files", true)], NEVER, NOW)
AssertEq(r.hwnd, 903, "two equally good matches -> first one wins (stable)")

AssertDone()
