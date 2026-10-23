; tab-search.ahk - the tab search popup (tabSearch hotkeys, Ctrl+Alt+Shift+A in the starter set):
; open browser tabs (most recently used first), recently closed tabs and bookmarks, typeahead,
; across every browser profile. Windows side of the Linux popup in linux/toast/alttabsucks_toast.py.
;
; The server does the searching (Server/TabSearch.ps1, GET /tab-search, one request per keystroke)
; and the browser side of picking a result (POST /tab-search/action: switch, restore, open, close);
; this file shows the list and brings the right browser window forward, the same way FocusTab does.
;
; Keys: type to filter, Up/Down select (the top result after each keystroke), Enter goes there,
; Ctrl+W closes the selected open tab, Esc (or clicking elsewhere) closes the popup.
; Chromium-based browsers only for now.

global _tsGui := 0, _tsLV := 0, _tsEdit := 0
global _tsItems := []          ; one per ListView row, in row order
global _tsCaption := ""        ; title of the window in front when opened ("" if not a browser)
global _tsIcons := Map()       ; iconKey -> ImageList index (shared image list, kept across popups)
global _tsImageList := 0

ShowTabSearch() {
    global _tsGui, _tsLV, _tsEdit, _tsCaption
    if CHROMIUM_EXE = "" {
        ShowTextGui("Tab search", "Tab search works with Chromium-based browsers (Brave, Chrome, Edge, Vivaldi, Opera) for now.", 600, 5)
        return
    }
    if _tsGui {
        WinActivate("ahk_id " _tsGui.Hwnd)
        return
    }
    ; The tab you're on is left out of the list: the server finds it by this window title.
    _tsCaption := WinActive("ahk_class Chrome_WidgetWin_1 ahk_exe " _chromiumExe) ? WinGetTitle("A") : ""

    isDark := _SwitcherIsDark()
    g := Gui("+AlwaysOnTop -Caption +Border +ToolWindow", "AltTabSucks_TabSearch")
    g.SetFont("s12", "Segoe UI")
    g.MarginX := 10, g.MarginY := 10
    edit := g.AddEdit("xm ym w760 h32")
    ; +0x40 LVS_SHAREIMAGELISTS: the favicon image list outlives this popup. +0x8 LVS_SHOWSELALWAYS.
    lv := g.AddListView("xm y+6 w760 h480 -Hdr -Multi +0x8 +0x40", ["Title", "Address"])
    g.SetFont("s9 c" (isDark ? "8A8A8A" : "707070"), "Segoe UI")
    g.AddText("xm y+4 w760", "↑↓ select   Enter open   Ctrl+W close tab   Esc cancel")
    _ApplySwitcherTheme(g, edit, lv, isDark)
    lv.SetImageList(_TabSearchImageList(), 1)
    lv.ModifyCol(1, 470), lv.ModifyCol(2, 260)
    SendMessage(0x109D, 1, 0, lv)  ; LVM_ENABLEGROUPVIEW: section headers

    _tsGui := g, _tsLV := lv, _tsEdit := edit
    edit.OnEvent("Change", (*) => _TabSearchRefresh())
    lv.OnEvent("DoubleClick", (*) => _TabSearchChoose())
    g.OnEvent("Escape", (*) => _TabSearchClose())
    _TabSearchRefresh()

    ; Centered on the monitor of the window that was in front.
    MonitorGetWorkArea(_TabSearchMonitor(), &l, &t, &r, &b)
    g.Show("Hide")
    g.GetPos(, , &w, &h)
    g.Show("x" (l + (r - l - w) // 2) " y" (t + (b - t - h) // 3))
    edit.Focus()
}

_TabSearchMonitor() {
    try {
        WinGetPos(&x, &y, &w, &h, "A")
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &l, &t, &r, &b)
            if x + w // 2 >= l && x + w // 2 < r && y + h // 2 >= t && y + h // 2 < b
                return A_Index
        }
    }
    return MonitorGetPrimary()
}

_TabSearchClose() {
    global _tsGui, _tsLV, _tsEdit, _tsItems
    if !_tsGui
        return
    g := _tsGui
    _tsGui := 0, _tsLV := 0, _tsEdit := 0, _tsItems := []
    g.Destroy()
}

; Keys while the popup is in front. Registered once; the predicate scopes them to the popup.
HotIf((*) => _tsGui && WinActive("ahk_id " _tsGui.Hwnd))
Hotkey("Up", (*) => _TabSearchMove(-1))
Hotkey("Down", (*) => _TabSearchMove(1))
Hotkey("PgUp", (*) => _TabSearchMove(-10))
Hotkey("PgDn", (*) => _TabSearchMove(10))
Hotkey("Enter", (*) => _TabSearchChoose())
Hotkey("NumpadEnter", (*) => _TabSearchChoose())
Hotkey("^w", (*) => _TabSearchCloseTab())
HotIf()

; Clicking anywhere else closes it, like Esc.
OnMessage(0x0006, _TabSearchWMActivate)  ; WM_ACTIVATE
_TabSearchWMActivate(wParam, lParam, msg, hwnd) {
    if _tsGui && hwnd = _tsGui.Hwnd && (wParam & 0xFFFF) = 0  ; WA_INACTIVE
        SetTimer(_TabSearchClose, -1)
}

; ---- results ---------------------------------------------------------------------------------

_TabSearchRefresh() {
    global _tsItems
    if !_tsGui
        return
    q := _tsEdit.Value
    url := "http://localhost:9876/tab-search?format=tsv&q=" _UriEncode(q) "&caption=" _UriEncode(_tsCaption)
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", url, false)
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send()
        text := http.Status = 200 ? http.ResponseText : ""
    } catch {
        text := ""
    }
    lv := _tsLV
    lv.Opt("-Redraw")
    lv.Delete()
    SendMessage(0x10A0, 0, 0, lv)  ; LVM_REMOVEALLGROUPS
    _tsItems := []
    showProfile := false, group := 0
    labels := Map("tabs", "Open tabs", "recent", "Recently closed", "bookmarks", "Bookmarks")
    for line in StrSplit(text, "`n", "`r") {
        if line = ""
            continue  ; StrSplit("") is empty: f[1] would throw
        f := StrSplit(line, "`t")
        if f[1] = "showProfile"
            showProfile := f.Length >= 2 && f[2] = "1"
        else if f[1] = "section" && f.Length >= 2
            _TabSearchAddGroup(lv, ++group, labels.Has(f[2]) ? labels[f[2]] : f[2])
        else if f[1] = "item" && f.Length >= 10 {
            item := { kind: f[2], profile: f[3], windowId: f[4], tabId: f[5], sessionId: f[6], iconKey: f[7],
                      live: f[8], title: f[9], url: f[10], group: group }
            title := (showProfile ? "[" item.profile "] " : "") (item.title != "" ? item.title : item.url)
            row := lv.Add("Icon" _TabSearchIcon(item.iconKey), title, item.url)
            _TabSearchSetGroup(lv, row, group)
            _tsItems.Push(item)
        }
    }
    if _tsItems.Length
        lv.Modify(1, "Select Focus Vis")
    else
        _TabSearchAddGroup(lv, 1, text = "" ? "Server unavailable" : "No matches")
    lv.Opt("+Redraw")
}

; LVGROUP (comctl32 v5 part): cbSize, mask, pszHeader, cchHeader, pszFooter, cchFooter, iGroupId.
_TabSearchAddGroup(lv, id, header) {
    grp := Buffer(A_PtrSize = 8 ? 56 : 40, 0)
    NumPut("UInt", grp.Size, grp, 0)
    NumPut("UInt", 0x1 | 0x10, grp, 4)  ; LVGF_HEADER | LVGF_GROUPID
    NumPut("Ptr", StrPtr(header), grp, 8)
    NumPut("Int", id, grp, A_PtrSize = 8 ? 36 : 24)
    SendMessage(0x1091, -1, grp, lv)  ; LVM_INSERTGROUP at the end
}

; LVITEM: mask, iItem, ..., iGroupId (offset 52 on x64, 40 on x86).
_TabSearchSetGroup(lv, row, id) {
    it := Buffer(A_PtrSize = 8 ? 88 : 60, 0)
    NumPut("UInt", 0x100, it, 0)  ; LVIF_GROUPID
    NumPut("Int", row - 1, it, 4)
    NumPut("Int", id, it, A_PtrSize = 8 ? 52 : 40)
    SendMessage(0x104C, 0, it, lv)  ; LVM_SETITEMW
}

_TabSearchMove(step) {
    if !_tsItems.Length
        return
    row := _tsLV.GetNext(0, "F")
    row := Max(1, Min(_tsItems.Length, (row ? row : 1) + step))
    _tsLV.Modify(0, "-Select")
    _tsLV.Modify(row, "Select Focus Vis")
}

; ---- favicons --------------------------------------------------------------------------------
; From the server (GET /favicon?key=, uploaded by the extension), saved as files because the image
; list loads from files, kept in one image list for the whole session. Index 1 is a blank icon.

_TabSearchImageList() {
    global _tsImageList
    if !_tsImageList {
        _tsImageList := IL_Create(64, 64, false)
        IL_Add(_tsImageList, _TabSearchBlankIcon(), 0, true)
    }
    return _tsImageList
}

_TabSearchIconDir() {
    dir := A_Temp "\AltTabSucks\favicons"
    DirCreate(dir)
    return dir
}

_TabSearchBlankIcon() {
    path := _TabSearchIconDir() "\_blank.png"
    if !FileExist(path) {  ; 16x16 fully transparent PNG
        b64 := "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAEklEQVR42mNgGAWjYBSMAggAAAQQAAGvRYgsAAAAAElFTkSuQmCC"
        size := 0
        DllCall("Crypt32\CryptStringToBinaryW", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        buf := Buffer(size)
        DllCall("Crypt32\CryptStringToBinaryW", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        FileOpen(path, "w").RawWrite(buf, size)
    }
    return path
}

; ImageList index for an iconKey: fetched once per session, 1 (blank) when there's none yet.
_TabSearchIcon(key) {
    global _tsIcons
    if key = ""
        return 1
    if _tsIcons.Has(key)
        return _tsIcons[key]
    idx := 1
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", "http://localhost:9876/favicon?key=" _UriEncode(key), false)
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send()
        if http.Status = 200 {
            body := http.ResponseBody  ; SAFEARRAY of bytes; pvData is after cDims/fFeatures/cbElements/cLocks
            size := body.MaxIndex() + 1
            path := _TabSearchIconDir() "\" (_tsIcons.Count + 1) ".png"  ; just carries it into the image list
            FileOpen(path, "w").RawWrite(NumGet(ComObjValue(body) + 8 + A_PtrSize, "Ptr"), size)
            idx := IL_Add(_TabSearchImageList(), path, 0, true)
            if !idx
                idx := 1
        } else {
            _tsIcons[key] := 1  ; not uploaded yet: blank for this popup, retried next time
            return 1
        }
    }
    _tsIcons[key] := idx
    return idx
}

; ---- picking ---------------------------------------------------------------------------------

_TabSearchSelected() {
    row := _tsLV ? _tsLV.GetNext(0, "F") : 0
    return row && row <= _tsItems.Length ? _tsItems[row] : 0
}

_TabSearchChoose() {
    item := _TabSearchSelected()
    if !item
        return
    _TabSearchClose()
    reply := _TabSearchAction(item)
    if reply = ""
        return
    f := StrSplit(reply, "`t")  ; kind, profile, windowId, activeTitle, url
    switch f[1] {
        case "tab":
            ; Bring that window forward; the extension then switches to the tab (already queued).
            hwnd := f.Length >= 4 && f[4] != "" ? FindHwndByAnyTitle([f[4]]) : 0
            _TabSearchActivate(hwnd ? hwnd : _TabSearchProfileWindow(f[2]), f[2])
        case "open":
            ; Being restored/opened by the extension; it focuses that window, this brings the browser forward.
            _TabSearchActivate(_TabSearchProfileWindow(f[2]), f[2])
        case "launch":
            RunChromiumProfile(f[2])  ; the queued URL waits for its extension to start
    }
}

_TabSearchProfileWindow(profile) {
    titles := GetProfileWindowTitles(profile)
    hwnd := titles.Length ? FindHwndByAnyTitle(titles) : 0
    if !hwnd {
        wins := _VisibleBrowserWindows("ahk_class Chrome_WidgetWin_1 ahk_exe " _chromiumExe)
        hwnd := wins.Length ? wins[1] : 0
    }
    return hwnd
}

_TabSearchActivate(hwnd, label) {
    if !hwnd
        return
    WinActivate("ahk_id " hwnd)
    ShowProfileToast(hwnd, label, SampleTitlebarColor(hwnd))
}

_TabSearchCloseTab() {
    global _tsItems
    row := _tsLV.GetNext(0, "F")
    item := _TabSearchSelected()
    if !item || item.kind != "tab"
        return  ; only open tabs can be closed
    _TabSearchAction({ kind: "close", profile: item.profile, tabId: item.tabId })
    ; Drop it here right away; the extension's own update arrives a moment later.
    _tsLV.Delete(row)
    _tsItems.RemoveAt(row)
    if _tsItems.Length
        _tsLV.Modify(Min(row, _tsItems.Length), "Select Focus Vis")
}

; POST /tab-search/action; the reply line, or "" on failure.
_TabSearchAction(item) {
    body := '{"kind":"' JsonEscape(item.kind) '","profile":"' JsonEscape(item.profile) '"'
    for name in ["windowId", "tabId"]
        if item.HasProp(name) && item.%name% != ""
            body .= ',"' name '":' item.%name%
    for name in ["sessionId", "url"]
        if item.HasProp(name) && item.%name% != ""
            body .= ',"' name '":"' JsonEscape(item.%name%) '"'
    body .= "}"
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", "http://localhost:9876/tab-search/action", false)
        http.SetRequestHeader("Content-Type", "application/json")
        http.SetRequestHeader("X-AltTabSucks-Token", _serverToken)
        http.Send(body)
        return http.Status = 200 ? Trim(http.ResponseText, "`r`n") : ""
    }
    return ""
}

; Percent-encodes a string for a URL query (UTF-8).
_UriEncode(s) {
    buf := Buffer(StrPut(s, "UTF-8"))
    StrPut(s, buf, "UTF-8")
    out := ""
    Loop buf.Size - 1 {
        c := NumGet(buf, A_Index - 1, "UChar")
        out .= (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c = 0x2D || c = 0x2E || c = 0x5F || c = 0x7E
            ? Chr(c) : Format("%{:02X}", c)
    }
    return out
}
