; startup-manager.ahk - the startup manager (StartupManager.ahk is the entry point): launches the
; items in %LOCALAPPDATA%\AltTabSucks\startup.json one after another, with their delays, in place of
; Windows' own Run keys and Startup folders (which Server/StartupItems.ps1 switched off at install).
; Its window shows each item's countdown and status, lets you edit the list, and shows the history:
; every run appends one row to startup-history.jsonl with each item's launch, process and first
; window times.
;
;   StartupManager.ahk --logon   the "AltTabSucks Startup" logon task: launch, then close itself
;   StartupManager.ahk --run     the same, for testing (recorded as "manual")
;   StartupManager.ahk           just the editor (the tray menu's "Startup items")
;
; The scheduling decisions are in lib/startup-logic.ahk, tested on their own.

SM_TITLE := "AltTabSucks Startup"
SM_W := 700, SM_H := 540
global _sm := {gui: 0, items: [], states: Map(), config: Map(), running: false, trigger: "", runStart: 0,
               skipDelays: false, historyWritten: false, keepOpen: true, closeAt: 0, sel: 0, filling: false,
               plan: Map(), cells: Map(), hidden: false, moved: false, nextPlace: 0, mode: "", scanPid: 0, scanOut: "", newEntries: [], view: "items",
               configError: ""}

StartupManagerMain(args) {
    OnError(_SmLogError)
    mode := "edit"
    for a in args
        mode := a = "--logon" ? "logon" : a = "--run" ? "manual" : mode
    SetTitleMatchMode(2)
    if WinExist(SM_TITLE " ahk_class AutoHotkeyGUI") {  ; one manager at a time
        if mode = "edit"
            WinActivate()
        ExitApp()
    }
    bootMs := DllCall("GetTickCount64", "int64")
    logonMs := _SmLogonAgeMs()
    _sm.mode := mode
    dir := EnvGet("LOCALAPPDATA") "\AltTabSucks"
    _sm.configPath := dir "\startup.json"
    _sm.historyPath := dir "\startup-history.jsonl"
    _sm.bootToStartMs := mode = "logon" ? bootMs : ""
    _sm.logonToStartMs := mode = "logon" ? logonMs : ""
    _SmLoadConfig()
    for item in _sm.items
        _sm.states[item] := Map("status", "off")
    if mode != "edit" {
        _sm.keepOpen := false
        _SmStartRun(mode)
        _SmTick()  ; launch whatever is due at 0 s before spending time on the window
    }
    _SmBuildGui(mode)
    if mode = "edit"
        _SmScanWindowsStartup()
    SetTimer(_SmTick, 50)
}

; Errors still show AutoHotkey's dialog, but at logon nobody may be looking: keep a log too.
_SmLogError(err, mode) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " Type(err) ": " err.Message " (" err.File ":" err.Line ")`n",
                   EnvGet("LOCALAPPDATA") "\AltTabSucks\startup-errors.log", "UTF-8")
    return 0
}

; ---- config -----------------------------------------------------------------------------------

_SmLoadConfig() {
    _sm.configError := ""
    config := ""
    if FileExist(_sm.configPath) {
        try config := Json_Parse(FileRead(_sm.configPath, "UTF-8"))
        catch as e
            _sm.configError := "startup.json can't be read (" e.Message "), so only AltTabSucks starts and nothing is saved."
    }
    if !(config is Map) || !(config.Get("items", "") is Array)
        config := Map("version", 1, "autoCloseSeconds", 5, "readyTimeoutSeconds", 30, "items", [])
    hasBuiltin := false
    for item in config["items"]
        hasBuiltin := hasBuiltin || item.Get("builtin", "") = "alttabsucks"
    if !hasBuiltin
        config["items"].InsertAt(1, Map("name", "AltTabSucks", "builtin", "alttabsucks", "command", "", "workingDir", "",
                                        "process", "AltTabSucks.ahk", "delay", 0, "afterReady", 0, "ready", "process", "enabled", 1))
    _sm.config := config
    _sm.items := config["items"]
}

_SmSave(*) {
    if _sm.configError != ""
        return
    tmp := _sm.configPath ".tmp"
    try {
        DirCreate(RegExReplace(_sm.configPath, "\\[^\\]+$"))
        try FileDelete(tmp)
        FileAppend(Json_Stringify(_sm.config, "  ") "`n", tmp, "UTF-8-RAW")
        FileMove(tmp, _sm.configPath, true)
    } catch as e {
        _sm.footer.Value := "Couldn't save startup.json: " e.Message
    }
}

; ---- running ----------------------------------------------------------------------------------

_SmStartRun(trigger) {
    _sm.trigger := trigger, _sm.running := true, _sm.historyWritten := false, _sm.skipDelays := false
    _sm.runStart := A_TickCount
    for item in _sm.items
        _sm.states[item] := Map("status", item.Get("enabled", 1) ? "pending" : "off")
}

_SmTick() {
    if _sm.running {
        loop {  ; launch everything that's due (several can be due at once with 0 s delays)
            plan := StartupPlan(_sm.items, _sm.states, _sm.skipDelays)
            due := ""
            for item in _sm.items
                if plan.Has(item) && plan[item].at != "" && plan[item].at <= _SmNow() {
                    due := item
                    break
                }
            if due = ""
                break
            _SmLaunch(due)
        }
        _sm.plan := plan
        timeoutMs := _StartupNum(_sm.config, "readyTimeoutSeconds") * 1000 || 30000
        allDone := true
        for item in _sm.items {
            st := _sm.states[item], s := st["status"]
            if s = "launched" || s = "running" {
                proc := item.Get("process", "")
                if s = "launched" && _SmProcessRunning(proc)
                    st["processMs"] := _SmNow(), s := st["status"] := "running"
                if s = "running" && (item.Get("ready", "window") = "process" || _SmWindowShown(proc))
                    st["readyMs"] := st["doneMs"] := _SmNow(), s := st["status"] := "ready"
                else if _SmNow() - st["launchMs"] > timeoutMs
                    st["doneMs"] := _SmNow(), s := st["status"] := s = "running" ? "nowindow" : "noprocess"
            }
            allDone := allDone && (s = "off" || StartupIsDone(s))
        }
        if allDone
            _SmRunFinished()
    }
    if _sm.scanPid && !ProcessExist(_sm.scanPid)
        _SmScanDone()
    if _sm.gui {
        _SmUpdateUi()
        if A_TickCount >= _sm.nextPlace
            _SmPlace(), _sm.nextPlace := A_TickCount + 500
    }
    if _sm.closeAt && !_sm.keepOpen && !_sm.newEntries.Length && A_TickCount >= _sm.closeAt
        ExitApp()
}

; ms since the run started. Taken at each event rather than once per tick: a launch can block for a
; while (starting a task, a slow CreateProcess), and everything after it in the same tick happens later.
_SmNow() => A_TickCount - _sm.runStart

_SmLaunch(item) {
    st := _sm.states[item]
    st["launchMs"] := _SmNow()
    if _SmProcessRunning(item.Get("process", "")) {
        st["status"] := "already", st["doneMs"] := _SmNow()
        return
    }
    try {
        if item.Get("builtin", "") = "alttabsucks"
            _SmLaunchAltTabSucks()
        else
            Run(item.Get("command", ""), item.Get("workingDir", ""))
        st["status"] := item.Get("process", "") = "" ? "noprocess" : "launched"
        if st["status"] = "noprocess"  ; nothing to watch for: done as soon as it's launched
            st["doneMs"] := _SmNow()
    } catch as e {
        st["status"] := "failed", st["error"] := StrSplit(e.Message, "`n")[1], st["doneMs"] := _SmNow()
    }
}

; Through the on-demand "AltTabSucks AHK" task the installer registers (RunLevel Highest), so
; AltTabSucks.ahk starts elevated without a UAC prompt while everything else here starts as a normal
; user. Without that task, its own *RunAs self-elevation asks.
_SmLaunchAltTabSucks() {
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        svc.GetFolder("\").GetTask("AltTabSucks AHK").Run(ComValue(1, 0))  ; VT_NULL: no parameters
        return
    }
    Run('"' A_AhkPath '" "' A_ScriptDir '\AltTabSucks.ahk"', A_ScriptDir)
}

; An AutoHotkey script ("X.ahk") is found by its hidden main window: its process is
; AutoHotkey64.exe, like this manager's.
_SmProcessRunning(proc) {
    if proc = ""
        return false
    if StrLower(SubStr(proc, -4)) = ".ahk" {
        prev := A_DetectHiddenWindows
        DetectHiddenWindows(true)
        found := WinExist("\" proc " - AutoHotkey ahk_class AutoHotkey")
        DetectHiddenWindows(prev)
        return found != 0
    }
    return ProcessExist(proc) != 0
}

; Ready: a visible, uncloaked window of the process that's at least 50x50 (or minimized).
_SmWindowShown(proc) {
    if StrLower(SubStr(proc, -4)) = ".ahk"
        return _SmProcessRunning(proc)
    try {
        for hwnd in WinGetList("ahk_exe " proc) {
            cloaked := 0
            DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &cloaked, "uint", 4)  ; DWMWA_CLOAKED
            if cloaked
                continue
            if WinGetMinMax(hwnd) = -1
                return true
            WinGetPos(, , &w, &h, hwnd)
            if w >= 50 && h >= 50
                return true
        }
    }
    return false
}

_SmRunFinished() {
    _sm.running := false
    if _sm.historyWritten
        return
    _sm.historyWritten := true
    time := FormatTime(, "yyyy-MM-dd") "T" FormatTime(, "HH:mm:ss")
    row := StartupHistoryRow(_sm.items, _sm.states, _sm.trigger, time, _sm.bootToStartMs, _sm.logonToStartMs)
    _sm.lastAllReadyMs := row["allReadyMs"]
    try {
        DirCreate(RegExReplace(_sm.historyPath, "\\[^\\]+$"))
        FileAppend(Json_Stringify(row) "`n", _sm.historyPath, "UTF-8-RAW")
    }
    if _sm.hidden  ; closed while starting up: nothing left to show
        ExitApp()
    if _sm.gui {
        _sm.gui.Opt("-AlwaysOnTop")
        if _sm.view = "history"
            _SmShowHistory()
    }
    if !_sm.keepOpen
        _sm.closeAt := A_TickCount + (_StartupNum(_sm.config, "autoCloseSeconds") || 5) * 1000
    ; Declined at install (takeOver: false): don't bring it up at every logon, only in the editor.
    if _sm.config.Get("takeOver", 1) || _sm.mode = "edit"
        _SmScanWindowsStartup()
}

; ms since this logon session began (from the session's own LogonTime), "" if unknown.
_SmLogonAgeMs() {
    try {
        hTok := 0, len := 0, pData := 0, now := 0
        DllCall("advapi32\OpenProcessToken", "ptr", DllCall("GetCurrentProcess", "ptr"), "uint", 0x8, "ptr*", &hTok)  ; TOKEN_QUERY
        stats := Buffer(56, 0)
        ok := DllCall("advapi32\GetTokenInformation", "ptr", hTok, "int", 10, "ptr", stats, "uint", 56, "uint*", &len)  ; TokenStatistics
        DllCall("CloseHandle", "ptr", hTok)
        if !ok || DllCall("secur32\LsaGetLogonSessionData", "ptr", stats.Ptr + 8, "ptr*", &pData) != 0  ; AuthenticationId
            return ""
        logon := NumGet(pData, 80, "int64")  ; SECURITY_LOGON_SESSION_DATA.LogonTime
        DllCall("secur32\LsaFreeReturnBuffer", "ptr", pData)
        DllCall("GetSystemTimeAsFileTime", "int64*", &now)
        return logon > 0 ? (now - logon) // 10000 : ""
    }
    return ""
}

; ---- Windows startup entries that aren't taken over yet -----------------------------------------

; Asks installer.ps1 (in the background) which Windows startup entries are on and not ours: apps
; installed since add themselves there, and Explorer would launch them in its delayed burst.
_SmScanWindowsStartup() {
    _sm.scanOut := A_Temp "\alttabsucks-startup-scan.txt"
    try FileDelete(_sm.scanOut)
    cmd := A_ComSpec ' /c ""pwsh.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' A_ScriptDir '\installer.ps1" -Action startup-scan > "' _sm.scanOut '" 2>&1"'
    try {
        Run(cmd, A_ScriptDir, "Hide", &pid)
        _sm.scanPid := pid
    }
}

_SmScanDone() {
    _sm.scanPid := 0
    names := []
    try {
        for line in StrSplit(FileRead(_sm.scanOut, "UTF-8"), "`n", "`r")
            if SubStr(line, 1, 4) = "NEW`t"
                names.Push(SubStr(line, 5))
    }
    _sm.newEntries := names
    if !_sm.gui
        return
    if names.Length {
        list := ""
        for n in names
            list .= (list = "" ? "" : ", ") n
        _sm.notice.Value := names.Length " Windows startup item" (names.Length = 1 ? "" : "s") " not in this list yet: " list
                          ". Take " (names.Length = 1 ? "it" : "them") " over, or turn " (names.Length = 1 ? "it" : "them") " off in Task Manager's Startup apps."
    }
    _sm.notice.Visible := _sm.takeOver.Visible := names.Length > 0 && _sm.view = "items"
}

_SmTakeOver(*) {
    _SmKeepOpen()
    _sm.takeOver.Enabled := false
    _sm.notice.Value := "Taking over..."
    try RunWait('*RunAs pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\installer.ps1" -Action startup-import', A_ScriptDir, "Hide")
    _sm.takeOver.Enabled := true
    old := _sm.states
    _SmLoadConfig()
    _sm.states := Map()
    for item in _sm.items  ; the new items aren't launched this time; the others keep their status
        _sm.states[item] := Map("status", "off")
    for item, st in old
        for i, it in _sm.items
            if it["name"] = item["name"] && it.Get("command", "") = item.Get("command", "")
                _sm.states[it] := st
    _SmFillList()
    _SmScanWindowsStartup()
}

; ---- window -----------------------------------------------------------------------------------

_SmBuildGui(mode) {
    dark := false
    try dark := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0
    fg := dark ? "cE8E8E8" : "c000000"
    g := Gui((mode = "edit" ? "" : "+AlwaysOnTop ") "-MaximizeBox", SM_TITLE)
    _sm.gui := g
    g.SetFont("s10 " fg, "Segoe UI")
    if dark {
        g.BackColor := "202020"
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "uint", 20, "int*", 1, "uint", 4)  ; dark title bar
    }
    edit(opts) {
        e := g.AddEdit(opts)
        if dark
            e.Opt("+Background2D2D2D")
        return e
    }
    g.SetFont("s11 Bold")
    _sm.summary := g.AddText("x12 y10 w676 h24")
    g.SetFont("s10 Norm")
    _sm.lv := g.AddListView("x12 y38 w676 h250 Checked -Multi NoSortHdr", ["Name", "Delay", "Status", "Ready at", "Took"])
    _sm.lvHist := g.AddListView("x12 y38 w676 h450 Hidden NoSortHdr", ["When"])
    for lv in [_sm.lv, _sm.lvHist]
        if dark
            lv.Opt("+Background1E1E1E"), DllCall("uxtheme\SetWindowTheme", "ptr", lv.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    _sm.lv.ModifyCol(1, 230), _sm.lv.ModifyCol(2, 110), _sm.lv.ModifyCol(3, 180), _sm.lv.ModifyCol(4, 70), _sm.lv.ModifyCol(5, 70)
    _sm.lv.OnEvent("ItemSelect", _SmOnSelect)
    _sm.lv.OnEvent("ItemCheck", _SmOnCheck)
    _sm.lv.OnEvent("Click", (*) => _SmKeepOpen())

    editCtrls := []
    add(ctrl) => (editCtrls.Push(ctrl), ctrl)
    add(g.AddButton("x12 y296 w70", "Add")).OnEvent("Click", _SmAdd)
    add(g.AddButton("x88 y296 w80", "Remove")).OnEvent("Click", _SmRemove)
    add(g.AddButton("x174 y296 w50", "Up")).OnEvent("Click", (*) => _SmMove(-1))
    add(g.AddButton("x230 y296 w60", "Down")).OnEvent("Click", (*) => _SmMove(1))
    _sm.viewBtn := g.AddButton("x588 y296 w100", "History")
    _sm.viewBtn.OnEvent("Click", _SmToggleView)
    add(g.AddText("x12 y334 w80", "Name"))
    _sm.fName := add(edit("x96 y330 w250"))
    add(g.AddText("x360 y334 w60", "Process"))
    _sm.fProcess := add(edit("x424 y330 w264"))
    add(g.AddText("x12 y364 w80", "Command"))
    _sm.fCommand := add(edit("x96 y360 w512 r1 -Wrap"))
    _sm.fBrowse := add(g.AddButton("x614 y359 w74", "Browse"))
    _sm.fBrowse.OnEvent("Click", _SmBrowse)
    add(g.AddText("x12 y394 w80", "Delay (s)"))
    _sm.fDelay := add(edit("x96 y390 w60"))
    _sm.fAfter := add(g.AddCheckbox("x168 y393 w520", "Count it from when the previous item is ready, not launched"))
    add(g.AddText("x12 y424 w80", "Ready when"))
    _sm.fReady := add(g.AddDropDownList("x96 y420 w250", ["its first window appears", "its process is running"]))
    _sm.editCtrls := editCtrls
    for f in [_sm.fName, _sm.fProcess, _sm.fCommand, _sm.fDelay]
        f.OnEvent("Change", _SmOnEdit)
    _sm.fAfter.OnEvent("Click", _SmOnEdit)
    _sm.fReady.OnEvent("Change", _SmOnEdit)

    _sm.notice := g.AddText("x12 y456 w566 h40 Hidden cE0A030")
    _sm.takeOver := g.AddButton("x588 y458 w100 Hidden", "Take over")
    _sm.takeOver.OnEvent("Click", _SmTakeOver)
    _sm.footer := g.AddText("x12 y508 w380")
    _sm.histFile := g.AddButton("x274 y502 w120 Hidden", "Open history file")
    _sm.histFile.OnEvent("Click", (*) => FileExist(_sm.historyPath) && Run('notepad.exe "' _sm.historyPath '"'))
    _sm.launchAll := g.AddButton("x400 y502 w180", "Launch the rest now")
    _sm.launchAll.OnEvent("Click", (*) => (_SmKeepOpen(), _sm.skipDelays := true))
    _sm.runNow := g.AddButton("x400 y502 w180 Hidden", "Run startup now")
    _sm.runNow.OnEvent("Click", (*) => (_SmKeepOpen(), _SmStartRun("manual")))
    g.AddButton("x588 y502 w100", "Close").OnEvent("Click", _SmClose)
    g.OnEvent("Close", _SmClose)
    g.OnEvent("Escape", _SmClose)
    ; Real input on the window keeps it open. Not activation: at logon Windows activates this window
    ; by itself (it's the first one on the desktop).
    for msg in [0x0021, 0x00A1, 0x0201, 0x0204, 0x0100]  ; WM_MOUSEACTIVATE, WM_NCLBUTTONDOWN, WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_KEYDOWN
        OnMessage(msg, _SmOnInput)
    OnMessage(0x0232, _SmOnMoved)  ; WM_EXITSIZEMOVE

    _SmFillList()
    _SmSelect(_sm.items.Length ? 1 : 0)
    if mode = "edit" {
        g.Show("w" SM_W " h" SM_H)
    } else {  ; bottom right, without taking the focus from whatever the user starts using
        g.Show("NA w" SM_W " h" SM_H)
        _SmPlace()
    }
}

_SmFillList() {
    _sm.lv.Opt("-Redraw")
    _sm.lv.Delete()
    _sm.cells := Map()
    for item in _sm.items
        _sm.lv.Add(item.Get("enabled", 1) ? "Check" : "", item.Get("name", ""))
    _sm.lv.Opt("+Redraw")
    _SmUpdateUi()
}

_SmUpdateUi() {
    now := A_TickCount - _sm.runStart
    ready := 0, total := 0
    for i, item in _sm.items {
        st := _sm.states.Has(item) ? _sm.states[item] : Map("status", "off")
        if st["status"] != "off"
            total++, ready += StartupIsDone(st["status"])
        d := RegExReplace(Format("{:.1f}", _StartupNum(item, "delay")), "\.0$")
        readyAt := st.Get("readyMs", st["status"] = "nowindow" ? st.Get("processMs", "") : "")
        cells := [item.Get("name", ""), d " s" (item.Get("afterReady", 0) ? " after ready" : ""),
                  StartupStatusText(item, st, _sm.plan.Has(item) ? _sm.plan[item] : {at: "", after: Map("name", "?"), why: "launch"}, now),
                  StartupFormatSeconds(readyAt), readyAt != "" && st.Has("launchMs") ? StartupFormatSeconds(readyAt - st["launchMs"]) : ""]
        for c, text in cells {
            key := i "," c
            if !_sm.cells.Has(key) || _sm.cells[key] !== text
                _sm.lv.Modify(i, "Col" c, text), _sm.cells[key] := text
        }
    }
    if _sm.configError != ""
        summary := _sm.configError
    else if _sm.running
        summary := "Starting up: " ready " of " total " ready, " StartupFormatSeconds(now)
    else if _sm.historyWritten
        summary := "Startup done: everything ready after " StartupFormatSeconds(_sm.lastAllReadyMs)
    else
        summary := _sm.items.Length " startup items, launched in this order at logon. Changes save as you make them."
    if _sm.summary.Value != summary
        _sm.summary.Value := summary
    footer := _sm.closeAt && !_sm.keepOpen && !_sm.newEntries.Length
        ? "Closing in " Ceil((_sm.closeAt - A_TickCount) / 1000) " s (click here to keep it open)" : ""
    if _sm.footer.Value != footer && SubStr(_sm.footer.Value, 1, 13) != "Couldn't save"
        _sm.footer.Value := footer
    if _sm.view = "items" {
        _sm.launchAll.Visible := _sm.running
        _sm.runNow.Visible := !_sm.running
    }
}

_SmKeepOpen() {
    _sm.keepOpen := true, _sm.closeAt := 0
}

_SmOnInput(wParam, lParam, msg, hwnd) {
    if _sm.gui && DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") = _sm.gui.Hwnd  ; GA_ROOT
        _SmKeepOpen()
}

; Bottom right of the primary monitor's work area, unless the user moved it. Checked again every
; half second (from _SmTick): at logon the taskbar appears after this window does, and the work
; area or resolution can change while it's up.
_SmPlace() {
    if _sm.moved || _sm.mode = "edit" || _sm.hidden
        return
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    _sm.gui.GetPos(&x, &y, &w, &h)
    nx := Max(left, right - w - 12), ny := Max(top, bottom - h - 12)
    if nx != x || ny != y
        _sm.gui.Move(nx, ny)
}

_SmOnMoved(wParam, lParam, msg, hwnd) {
    if _sm.gui && hwnd = _sm.gui.Hwnd
        _sm.moved := true
}

_SmClose(*) {
    if _sm.running {  ; keep launching the rest in the background, then exit
        _sm.hidden := true
        _sm.gui.Hide()
        return true
    }
    ExitApp()
}

_SmToggleView(*) {
    _SmKeepOpen()
    _sm.view := _sm.view = "items" ? "history" : "items"
    hist := _sm.view = "history"
    for c in _sm.editCtrls
        c.Visible := !hist
    _sm.lv.Visible := !hist
    _sm.lvHist.Visible := hist
    _sm.histFile.Visible := hist
    _sm.notice.Visible := _sm.takeOver.Visible := !hist && _sm.newEntries.Length > 0
    _sm.launchAll.Visible := !hist && _sm.running
    _sm.runNow.Visible := !hist && !_sm.running
    _sm.viewBtn.Text := hist ? "Items" : "History"
    if hist
        _SmShowHistory()
}

_SmShowHistory() {
    rows := []
    try {
        lines := StrSplit(Trim(FileRead(_sm.historyPath, "UTF-8"), "`r`n"), "`n", "`r")
        start := Max(1, lines.Length - 199)  ; the last 200 runs
        loop lines.Length - start + 1 {
            try rows.Push(Json_Parse(lines[start + A_Index - 1]))
        }
    }
    names := []
    for item in _sm.items
        names.Push(item.Get("name", ""))
    t := StartupHistoryTable(rows, names)
    lv := _sm.lvHist
    lv.Opt("-Redraw")
    lv.Delete()
    while lv.GetCount("Col") > 1
        lv.DeleteCol(2)
    for i, h in t.header
        i = 1 ? lv.ModifyCol(1, , h) : lv.InsertCol(i, , h)
    for r in t.rows
        lv.Add(, r*)
    loop t.header.Length
        lv.ModifyCol(A_Index, "AutoHdr")
    lv.Opt("+Redraw")
}

; ---- editing ----------------------------------------------------------------------------------

_SmSelect(row) {
    _sm.sel := row
    item := row ? _sm.items[row] : ""
    builtin := row && item.Get("builtin", "") != ""
    _sm.filling := true
    _sm.fName.Value := row ? item.Get("name", "") : ""
    _sm.fCommand.Value := builtin ? "(the AltTabSucks AHK task, elevated)" : row ? item.Get("command", "") : ""
    _sm.fProcess.Value := row ? item.Get("process", "") : ""
    _sm.fDelay.Value := row ? RegExReplace(Format("{:.1f}", _StartupNum(item, "delay")), "\.0$") : ""
    _sm.fAfter.Value := row ? (item.Get("afterReady", 0) ? 1 : 0) : 0
    _sm.fReady.Value := row && item.Get("ready", "window") = "process" ? 2 : 1
    _sm.filling := false
    for f in [_sm.fName, _sm.fDelay, _sm.fAfter, _sm.fReady]
        f.Enabled := row != 0
    for f in [_sm.fCommand, _sm.fProcess, _sm.fBrowse]
        f.Enabled := row != 0 && !builtin
    if row && !(_sm.lv.GetNext(0) = row)
        _sm.lv.Modify(row, "Select Focus Vis")
}

_SmOnSelect(lv, row, selected) {
    if selected
        _SmSelect(row)
}

_SmOnCheck(lv, row, checked) {
    _SmKeepOpen()
    item := _sm.items[row]
    item["enabled"] := checked ? 1 : 0
    st := _sm.states[item]
    if _sm.running && !checked && st["status"] = "pending"
        st["status"] := "off"
    else if _sm.running && checked && st["status"] = "off" && !st.Has("launchMs")
        st["status"] := "pending"
    SetTimer(_SmSave, -500)
}

_SmOnEdit(ctrl, *) {
    if _sm.filling || !_sm.sel
        return
    _SmKeepOpen()
    item := _sm.items[_sm.sel]
    switch ctrl {
        case _sm.fName:
            item["name"] := ctrl.Value
        case _sm.fCommand:
            ; The process follows the command while it's the one the command implies.
            old := item.Get("process", "")
            if old = "" || old = StartupProcessFromCommand(item.Get("command", "")) {
                item["process"] := StartupProcessFromCommand(ctrl.Value)
                _sm.filling := true, _sm.fProcess.Value := item["process"], _sm.filling := false
            }
            item["command"] := ctrl.Value
        case _sm.fProcess:
            item["process"] := Trim(ctrl.Value)
        case _sm.fDelay:
            if !IsNumber(ctrl.Value) || ctrl.Value < 0
                return
            item["delay"] := ctrl.Value + 0
        case _sm.fAfter:
            item["afterReady"] := ctrl.Value ? 1 : 0
        case _sm.fReady:
            item["ready"] := ctrl.Value = 2 ? "process" : "window"
    }
    SetTimer(_SmSave, -500)
}

_SmBrowse(*) {
    _SmKeepOpen()
    if !_sm.sel || !(path := FileSelect(1, , "Program to start", "Programs (*.exe; *.lnk; *.bat; *.cmd; *.ahk)"))
        return
    item := _sm.items[_sm.sel]
    SplitPath(path, &file, , , &bare)
    if item.Get("name", "") = "New item"
        _sm.fName.Value := item["name"] := bare
    _sm.fCommand.Value := '"' path '"'  ; fires _SmOnEdit, which updates the process too
}

_SmAdd(*) {
    _SmKeepOpen()
    item := Map("name", "New item", "command", "", "workingDir", "", "process", "", "delay", 1, "afterReady", 0,
                "ready", "window", "enabled", 1)
    _sm.items.Push(item)
    _sm.states[item] := Map("status", "off")  ; not launched in a startup that's already running
    _SmFillList()
    _SmSelect(_sm.items.Length)
    _sm.fName.Focus()
    SetTimer(_SmSave, -500)
}

_SmRemove(*) {
    _SmKeepOpen()
    if !_sm.sel
        return
    item := _sm.items[_sm.sel]
    if item.Get("builtin", "") != "" {
        MsgBox("AltTabSucks itself can't be removed, only unchecked.", SM_TITLE, "Iconi Owner" _sm.gui.Hwnd)
        return
    }
    if item.Has("windows") && MsgBox("Remove " item["name"] "?`n`nIt came from Windows startup, where it stays turned off. "
            . "To have Windows start it again, turn it on in Task Manager's Startup apps.", SM_TITLE, "OKCancel Icon? Owner" _sm.gui.Hwnd) != "OK"
        return
    _sm.items.RemoveAt(_sm.sel)
    _SmFillList()
    _SmSelect(Min(_sm.sel, _sm.items.Length))
    SetTimer(_SmSave, -500)
}

_SmMove(dir) {
    _SmKeepOpen()
    i := _sm.sel, j := i + dir
    if !i || j < 1 || j > _sm.items.Length
        return
    item := _sm.items[i]
    _sm.items[i] := _sm.items[j], _sm.items[j] := item
    _SmFillList()
    _SmSelect(j)
    SetTimer(_SmSave, -500)
}
