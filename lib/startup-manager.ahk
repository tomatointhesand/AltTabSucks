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
SM_W := 700, SM_H := 570
global _sm := {gui: 0, items: [], states: Map(), config: Map(), running: false, trigger: "", runStart: 0,
               skipDelays: false, historyWritten: false, keepOpen: true, closeAt: 0, sel: 0, filling: false,
               plan: Map(), cells: Map(), hidden: false, moved: false, nextPlace: 0, mode: "", scanPid: 0, scanOut: "", newEntries: [], view: "items",
               configError: "", outcomes: [], textColor: 0, colors: Map()}

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
        _sm.keepOpen := _sm.config.Get("stayOpen", 0) ? true : false
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
    }
    _SmWatch()
    if _sm.running && _SmAllDone()
        _SmRunFinished()
    ; The countdown starts once everything is up, even if that's after the run finished (an item
    ; that timed out showed up late). Not while something is still missing: the window stays open
    ; so you can see what.
    if !_sm.running && _sm.historyWritten && !_sm.closeAt && !_sm.keepOpen && !_sm.hidden
            && StartupAllUp(_sm.items, _sm.states)
        _sm.closeAt := A_TickCount + (_StartupNum(_sm.config, "autoCloseSeconds") || 5) * 1000
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

; Moves launched items along: process seen, then ready, or timed out. A timed-out item (nowindow,
; noprocess with a process to watch for) keeps being watched and turns ready if it shows up late;
; its doneMs stays the timeout, which is what the items after it were scheduled from.
_SmWatch() {
    timeoutMs := _StartupNum(_sm.config, "readyTimeoutSeconds") * 1000 || 30000
    for item in _sm.items {
        st := _sm.states[item], s := st["status"]
        proc := item.Get("process", "")
        late := s = "nowindow" || s = "noprocess"
        if !(s = "launched" || s = "running" || late) || proc = ""
            continue
        if (s = "launched" || s = "noprocess") && _SmProcessRunning(proc)
            st["processMs"] := _SmNow(), s := st["status"] := late ? "nowindow" : "running"
        if (s = "running" || s = "nowindow") && _SmIsReady(item, proc) {
            st["readyMs"] := _SmNow(), st["status"] := "ready"
            if !late
                st["doneMs"] := st["readyMs"]
        } else if !late && _SmNow() - st["launchMs"] > timeoutMs {
            st["doneMs"] := _SmNow(), st["status"] := s = "running" ? "nowindow" : "noprocess"
        }
    }
}

_SmAllDone() {
    for item in _sm.items {
        s := _sm.states[item]["status"]
        if s != "off" && !StartupIsDone(s)
            return false
    }
    return true
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

; AltTabSucks.ahk is ready once its tray icon is there: its process alone shows up long before
; that, and at logon the icon can go missing (see lib/tray-icon.ahk). Others: by their "ready".
_SmIsReady(item, proc) {
    if item.Get("builtin", "") = "alttabsucks" {
        prev := A_DetectHiddenWindows
        DetectHiddenWindows(true)
        hwnd := WinExist("\AltTabSucks.ahk - AutoHotkey ahk_class AutoHotkey")
        DetectHiddenWindows(prev)
        return hwnd && TrayIconShown(hwnd)
    }
    return item.Get("ready", "window") = "process" || _SmWindowShown(proc)
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
    g := Gui((mode = "edit" ? "" : "+AlwaysOnTop ") "+Resize +MinSize560x420", SM_TITLE)
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
    ; Status colors: green check mark, amber timeouts, red failures (custom draw, per cell).
    _sm.textColor := SendMessage(0x1023, 0, 0, _sm.lv)  ; LVM_GETTEXTCOLOR
    if _sm.textColor = 0xFF000000  ; CLR_DEFAULT: the system's window text color
        _sm.textColor := DllCall("GetSysColor", "int", 8, "uint")
    _sm.colors := dark ? Map("ok", 0x50B93F, "warn", 0x30A0E0, "error", 0x4951F8)
                       : Map("ok", 0x2A8A1F, "warn", 0x0070C0, "error", 0x2020C8)  ; COLORREF: 0xBBGGRR
    _sm.lv.OnNotify(-12, _SmLvCustomDraw)  ; NM_CUSTOMDRAW

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
    _sm.fReady := add(g.AddDropDownList("x96 y420 w250", ["its first window appears", "its process is running", "its tray icon appears"]))
    _sm.editCtrls := editCtrls
    for f in [_sm.fName, _sm.fProcess, _sm.fCommand, _sm.fDelay]
        f.OnEvent("Change", _SmOnEdit)
    _sm.fAfter.OnEvent("Click", _SmOnEdit)
    _sm.fReady.OnEvent("Change", _SmOnEdit)

    _sm.notice := g.AddText("x12 y456 w566 h40 Hidden cE0A030")
    _sm.takeOver := g.AddButton("x588 y458 w100 Hidden", "Take over")
    _sm.takeOver.OnEvent("Click", _SmTakeOver)
    _sm.stayOpen := g.AddCheckbox("x12 y540 w260", "Keep this window open after startup")
    _sm.stayOpen.Value := _sm.config.Get("stayOpen", 0) ? 1 : 0
    _sm.stayOpen.OnEvent("Click", _SmOnStayOpen)
    _sm.footer := g.AddText("x280 y540 w408")
    _sm.histFile := g.AddButton("x274 y502 w120 Hidden", "Open history file")
    _sm.histFile.OnEvent("Click", (*) => FileExist(_sm.historyPath) && Run('notepad.exe "' _sm.historyPath '"'))
    _sm.launchAll := g.AddButton("x400 y502 w180", "Launch the rest now")
    _sm.launchAll.OnEvent("Click", (*) => (_SmKeepOpen(), _sm.skipDelays := true))
    _sm.runNow := g.AddButton("x400 y502 w180 Hidden", "Run startup now")
    _sm.runNow.OnEvent("Click", (*) => (_SmKeepOpen(), _SmStartRun("manual")))
    _sm.closeBtn := g.AddButton("x588 y502 w100", "Close")
    _sm.closeBtn.OnEvent("Click", _SmClose)
    g.OnEvent("Close", _SmClose)
    g.OnEvent("Escape", _SmClose)
    ; Real input on the window keeps it open. Not activation: at logon Windows activates this window
    ; by itself (it's the first one on the desktop).
    for msg in [0x0021, 0x00A1, 0x0201, 0x0204, 0x0100]  ; WM_MOUSEACTIVATE, WM_NCLBUTTONDOWN, WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_KEYDOWN
        OnMessage(msg, _SmOnInput)
    OnMessage(0x0232, _SmOnMoved)  ; WM_EXITSIZEMOVE

    _SmFillList()
    _SmSelect(_sm.items.Length ? 1 : 0)
    ; Laid out for SM_W x SM_H; shown hidden at that size first, so every control's position is
    ; recorded in the same units the Size event works in. Then shown tall enough for every item.
    g.Show("Hide w" SM_W " h" SM_H)
    _SmRecordLayout()
    g.OnEvent("Size", _SmOnSize)
    h := SM_H + _SmListExtraHeight()
    if mode = "edit" {
        g.Show("w" SM_W " h" h)
    } else {  ; bottom right, without taking the focus from whatever the user starts using
        g.Show("NA w" SM_W " h" h)
    }
    _SmFitToScreen()
    if mode != "edit"
        _SmPlace()
}

; ---- resizing ---------------------------------------------------------------------------------
; Each control is anchored by flags: x/y move it with the window's right/bottom edge, w/h stretch
; it. The lists stretch both ways; everything under them moves down; the buttons on the right and
; the long fields follow the right edge.
_SmRecordLayout() {
    g := _sm.gui
    g.GetClientPos(, , &cw, &ch)
    _sm.baseW := cw, _sm.baseH := ch
    _sm.lv.GetPos(, &lvY, , &lvH)
    below := lvY + lvH  ; controls under the items list move down with the window's bottom edge
    special := Map(_sm.summary.Hwnd, "w", _sm.lv.Hwnd, "wh", _sm.lvHist.Hwnd, "wh",
                   _sm.fProcess.Hwnd, "yw", _sm.fCommand.Hwnd, "yw", _sm.notice.Hwnd, "yw", _sm.footer.Hwnd, "yw")
    for c in [_sm.viewBtn, _sm.fBrowse, _sm.takeOver, _sm.launchAll, _sm.runNow, _sm.closeBtn]
        special[c.Hwnd] := "xy"
    _sm.anchors := []
    for hwnd, ctrl in g {
        ctrl.GetPos(&x, &y, &w, &h)
        flags := special.Has(ctrl.Hwnd) ? special[ctrl.Hwnd] : y >= below ? "y" : ""
        if flags != ""
            _sm.anchors.Push({ctrl: ctrl, f: flags, x: x, y: y, w: w, h: h})
    }
}

_SmOnSize(g, minMax, *) {
    if minMax = -1 || !_sm.HasOwnProp("anchors")  ; minimized, or not laid out yet
        return
    g.GetClientPos(, , &cw, &ch)
    dx := cw - _sm.baseW, dy := ch - _sm.baseH
    for a in _sm.anchors
        a.ctrl.Move(a.x + (InStr(a.f, "x") ? dx : 0), a.y + (InStr(a.f, "y") ? dy : 0),
                    a.w + (InStr(a.f, "w") ? dx : 0), a.h + (InStr(a.f, "h") ? dy : 0))
    _SmFitStatusColumn()
    WinRedraw(g.Hwnd)
}

; The Status column takes whatever width the other columns leave (all in pixels, from the list).
_SmFitStatusColumn() {
    lv := _sm.lv
    rc := Buffer(16)
    DllCall("GetClientRect", "ptr", lv.Hwnd, "ptr", rc)
    others := 0
    for i in [0, 1, 3, 4]
        others += SendMessage(0x101D, i, 0, lv)  ; LVM_GETCOLUMNWIDTH
    w := Max(NumGet(rc, 8, "int") - others, Round(180 * A_ScreenDPI / 96))
    SendMessage(0x101E, 2, w, lv)  ; LVM_SETCOLUMNWIDTH
}

; How much taller than its designed 250 the items list must be to show every row without a
; scrollbar (in the units Gui.Show takes), 0 if it already fits.
_SmListExtraHeight() {
    lv := _sm.lv
    if !_sm.items.Length
        return 0
    rc := Buffer(16, 0)
    if !SendMessage(0x100E, 0, rc.Ptr, lv)  ; LVM_GETITEMRECT, item 0, LVIR_BOUNDS
        return 0
    rowPx := NumGet(rc, 12, "int") - NumGet(rc, 4, "int")
    WinGetPos(, , , &headerPx, SendMessage(0x101F, 0, 0, lv))  ; LVM_GETHEADER
    lv.GetPos(, , , &lvH)
    WinGetPos(, , , &lvPx, lv.Hwnd)
    scale := lvH / lvPx  ; pixels -> the units GetPos/Show use
    needPx := headerPx + rowPx * _sm.items.Length + (lvPx - _SmClientHeight(lv.Hwnd)) + 2
    return Max(0, Ceil(needPx * scale) - lvH)
}

_SmClientHeight(hwnd) {
    rc := Buffer(16)
    DllCall("GetClientRect", "ptr", hwnd, "ptr", rc)
    return NumGet(rc, 12, "int")
}

; No taller than the work area of the monitor it's on (pixels throughout).
_SmFitToScreen() {
    hwnd := _sm.gui.Hwnd
    WinGetPos(&x, &y, &w, &h, hwnd)
    MonitorGetWorkArea(_SmMonitorOf(x + w // 2, y + h // 2), &left, &top, &right, &bottom)
    if h > bottom - top
        WinMove(, top, , bottom - top, hwnd)
}

_SmMonitorOf(x, y) {
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if x >= l && x < r && y >= t && y < b
            return A_Index
    }
    return MonitorGetPrimary()
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
    ready := 0, total := 0, up := 0, lastUpMs := 0
    for i, item in _sm.items {
        st := _sm.states.Has(item) ? _sm.states[item] : Map("status", "off")
        outcome := StartupOutcome(item, st)
        if _sm.outcomes.Length < i
            _sm.outcomes.Length := i
        _sm.outcomes[i] := outcome
        if st["status"] != "off"
            total++, ready += StartupIsDone(st["status"])
        if st["status"] != "off" && outcome = "ok"
            up++, lastUpMs := Max(lastUpMs, st.Get("readyMs", st.Get("doneMs", 0)))
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
    else if _sm.historyWritten && up = total
        summary := "Startup done: everything up after " StartupFormatSeconds(lastUpMs)
    else if _sm.historyWritten
        summary := "Startup: " up " of " total " up, still watching for the rest"
    else
        summary := _sm.items.Length " startup items, launched in this order at logon. Changes save as you make them."
    if _sm.summary.Value != summary
        _sm.summary.Value := summary
    footer := _sm.closeAt && !_sm.keepOpen && !_sm.newEntries.Length
        ? "Closing in " Ceil((_sm.closeAt - A_TickCount) / 1000) " s (click here to keep it open)"
        : _sm.historyWritten && !_sm.running && !_sm.keepOpen && up < total ? "Staying open until everything is up" : ""
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

; The saved preference (startup.json's stayOpen). Checking it keeps this window open now too;
; unchecking it applies from the next startup (you're using the window right now).
_SmOnStayOpen(ctrl, *) {
    _SmKeepOpen()
    _sm.config["stayOpen"] := ctrl.Value ? 1 : 0
    _SmSave()
}

; NM_CUSTOMDRAW for the items list: the Status column (subitem 2) in its outcome's color, the
; other cells in the list's own text color (a color set for one cell carries over to the next).
; A row flagged selected gets its text in the theme's color, ignoring ours, so the flag is cleared
; here. The theme still draws the selection highlight behind it (from the row's real state; the flag
; itself is set on every row in dark mode, so it couldn't tell which row is selected anyway).
_SmLvCustomDraw(lv, lParam) {
    x64 := A_PtrSize = 8
    stage := NumGet(lParam, x64 ? 24 : 12, "uint")
    if stage = 0x1  ; CDDS_PREPAINT
        return 0x20  ; CDRF_NOTIFYITEMDRAW
    if stage = 0x10001 {  ; CDDS_ITEMPREPAINT
        state := NumGet(lParam, x64 ? 64 : 40, "uint")  ; uItemState
        NumPut("uint", state & ~0x1, lParam, x64 ? 64 : 40)  ; CDIS_SELECTED
        return 0x20  ; CDRF_NOTIFYSUBITEMDRAW
    }
    if stage != 0x30001  ; CDDS_ITEMPREPAINT | CDDS_SUBITEM
        return 0
    row := NumGet(lParam, x64 ? 56 : 36, "uptr") + 1
    sub := NumGet(lParam, x64 ? 88 : 56, "int")
    outcome := sub = 2 && row <= _sm.outcomes.Length ? _sm.outcomes[row] : ""
    NumPut("uint", outcome != "" && _sm.colors.Has(outcome) ? _sm.colors[outcome] : _sm.textColor, lParam, x64 ? 80 : 48)
    return 0x2  ; CDRF_NEWFONT
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
    WinGetPos(&x, &y, &w, &h, _sm.gui.Hwnd)  ; pixels, like the work area
    nx := Max(left, right - w - 12), ny := Max(top, bottom - h - 12)
    if nx != x || ny != y
        WinMove(nx, ny, , , _sm.gui.Hwnd)
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
    _sm.fReady.Value := builtin ? 3 : row && item.Get("ready", "window") = "process" ? 2 : 1  ; 3: AltTabSucks only
    _sm.filling := false
    for f in [_sm.fName, _sm.fDelay, _sm.fAfter]
        f.Enabled := row != 0
    for f in [_sm.fCommand, _sm.fProcess, _sm.fBrowse, _sm.fReady]
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
            if ctrl.Value = 3  ; the tray icon is AltTabSucks' own (that item can't be edited here)
                ctrl.Value := 1
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
