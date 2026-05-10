; window-management.ahk - Window management utilities

; Launches a Microsoft Store (MSIX) app from an elevated AHK process.
; Pass either an AUMID (e.g. "Claude_pzs8sxrjxfjjc!Claude") or an App Execution
; Alias exe name (e.g. "Claude.exe"). Shell.Application runs in the user (non-elevated)
; context, which is required to activate MSIX apps from an elevated process.
LaunchStoreApp(aumidOrExe) {
    target := InStr(aumidOrExe, "!")
        ? "shell:AppsFolder\" . aumidOrExe
        : EnvGet("LOCALAPPDATA") . "\Microsoft\WindowsApps\" . aumidOrExe
    ComObject("Shell.Application").ShellExecute(target)
}

; ManageAppWindows(processName, exePath, mode)
;
; processName  - executable name, e.g. "notepad++.exe"
; exePath      - path to launch when no windows exist; pass "" to do nothing
; mode         - "cycle"  : advance through all windows (visible then minimized),
;                           wrapping around; restores minimized windows as they
;                           come up in rotation; 0 windows -> launch exePath;
;                           1 window -> same as "toggle" when CYCLE_SINGLE_AS_TOGGLE is true
;              - "toggle" : focus the app if it isn't active; minimize all its
;                           visible windows if one of them is currently active
;
; Visible windows = WS_VISIBLE, unowned, not minimized
ManageAppWindows(processName, exePath := "", mode := "cycle") {
    ; Only consider windows that are:
    ;   - WS_VISIBLE (excludes hidden background windows e.g. Discord tray)
    ;   - unowned (excludes dialogs/toolbars owned by a main window e.g. Notepad++ Find)
    ; DetectHiddenWindows is ON globally, so we must filter manually.
    visible := []
    minimized := []
    for hwnd in WinGetList("ahk_exe " processName) {
        if !(WinGetStyle("ahk_id " hwnd) & 0x10000000)  ; not WS_VISIBLE
            continue
        if DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") != 0  ; owned window
            continue
        if WinGetMinMax("ahk_id " hwnd) = -1
            minimized.Push(hwnd)
        else
            visible.Push(hwnd)
    }

    ; No windows at all -> launch
    if visible.Length = 0 && minimized.Length = 0 {
        if exePath is Func
            exePath()
        else if exePath != ""
            Run(exePath)
        return
    }

    activeHwnd := 0
    try activeHwnd := WinGetID("A")

    if mode = "toggle" {
        ; Use process name to detect ownership — more reliable than HWND matching when
        ; privilege level differences cause some windows to be missed in visible/minimized.
        isMine := false
        try isMine := (WinGetProcessName("A") = processName)
        if !isMine {
            for hwnd in visible
                if hwnd = activeHwnd {
                    isMine := true
                    break
                }
        }
        if isMine {
            for hwnd in visible
                WinMinimize("ahk_id " hwnd)
        } else {
            for hwnd in minimized
                WinRestore("ahk_id " hwnd)
            toastHwnd := visible.Length > 0 ? visible[1] : (minimized.Length > 0 ? minimized[1] : 0)
            if toastHwnd
                WinActivate("ahk_id " toastHwnd)
            if toastHwnd
                ShowProfileToast(toastHwnd, _SwitcherExeName(SubStr(processName, 1, -4)), SampleTitlebarColor(toastHwnd))
        }
        return
    }

    if mode = "cycle" && CYCLE_SINGLE_AS_TOGGLE && (visible.Length + minimized.Length = 1) {
        ManageAppWindows(processName, exePath, "toggle")
        return
    }

    ; cycle: advance through all windows (visible first, then minimized), wrapping around
    all := []
    for hwnd in visible
        all.Push(hwnd)
    for hwnd in minimized
        all.Push(hwnd)

    activeIdx := 0
    for i, hwnd in all
        if hwnd = activeHwnd {
            activeIdx := i
            break
        }

    nextIdx := Mod(activeIdx, all.Length) + 1
    nextHwnd := all[nextIdx]
    if WinGetMinMax("ahk_id " nextHwnd) = -1
        WinRestore("ahk_id " nextHwnd)
    WinActivate("ahk_id " nextHwnd)
    ShowProfileToast(nextHwnd, _SwitcherExeName(SubStr(processName, 1, -4)), SampleTitlebarColor(nextHwnd))
}