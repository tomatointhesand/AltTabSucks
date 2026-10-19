; general.ahk - General-purpose UI helpers

; Escapes a string for safe embedding in a JSON double-quoted value.
JsonEscape(s) {
    s := StrReplace(s, "\",  "\\")
    s := StrReplace(s, '"',  '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return s
}

ShowTextGui(title, text, width := 700, rows := 20) {  ; rows ignored — height auto-sizes to content
    isDark := _SwitcherIsDark()
    bg     := isDark ? "1E1E1E" : "F5F5F5"
    editBg := isDark ? "2D2D2D" : "FFFFFF"
    fg     := isDark ? "EFEFEF" : "1A1A1A"

    lineCount := 0
    Loop Parse, text, "`n"
        lineCount++

    g := Gui("+Resize", title)
    g.SetFont("s10", "Segoe UI")
    if isDark
        g.BackColor := bg
    editCtrl := g.Add("Edit", "r" (lineCount + 1) " w" width " ReadOnly", text)
    editCtrl.SetFont("c" . fg)
    if isDark
        editCtrl.Opt("+Background" . editBg)
    closeBtn := g.Add("Button", "Default w" width, "Close")
    closeBtn.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Size", (g, mm, w, h) => (editCtrl.Move(,, w-16, h-47), closeBtn.Move(, h-31, w-16)))

    g.Show("Hide AutoSize")
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 20, "Int*", isDark ? 1 : 0, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    _ThemeEdit(editCtrl, isDark)
    _ThemeButton(closeBtn, isDark)

    MonitorGetWorkArea(, &waL, &waT, &waR, &waB)
    WinGetPos(&_x, &_y, &ww, &wh, "ahk_id " g.Hwnd)
    finalH := Min(wh, waB - waT)
    finalX := (waL + waR - ww) // 2
    finalY := Max(waT, (waT + waB - finalH) // 2)
    g.Show("x" finalX " y" finalY " w" ww " h" finalH)

    closeBtn.Focus()
}

; Converts a clipboard column (one value per line, e.g. from SSMS) to a SQL IN clause.
; Usage: select a column of cells, Ctrl+C, fire the hotkey, then Ctrl+V.
; Result: ('VAL1','VAL2','VAL3')
ClipboardToSqlIn() {
    words := StrUpper(A_Clipboard)
    text  := ""
    Loop Parse, words, "`n", "`r" {
        field := Trim(A_LoopField)
        if field = ""
            continue
        text .= (text ? ",'" : "'") . field . "'"
    }
    if text != ""
        A_Clipboard := "(" . text . ")"
}

; Converts highlighted text (a number in cm) to feet and inches, saves result to clipboard.
; Usage: select the number, fire the hotkey, then Ctrl+V.
; Result: e.g. "5 11.2" (feet inches)
ClipboardCmToFtIn() {
    ; Send("^c")
    ClipWait(0.5)
    try
        num_in := Number(Trim(A_Clipboard)) / 2.54
    catch {
        ShowProfileToast(WinGetID("A"), "not a number", "CC0000")
        return
    }
    num_ft := Floor(num_in / 12)
    num_in := num_in - num_ft * 12
    A_Clipboard := num_ft . "' " . Round(num_in, 1) . Chr(34) ; Chr(34) = double quote
}

; Returns the current time as a Unix timestamp and copies it to the clipboard.
UnixTimestampToClipboard() {
    ts := DateDiff(A_Now, "19700101000000", "Seconds")
    A_Clipboard := ts
    MsgBox(ts " has been copied to clipboard.")
}

; Prompts for a Jira-style issue number and opens `prefix-<number>` in the browser.
; prefix should end with the project key, e.g. "https://jira.example.com/browse/PROJ".
OpenIssue(prefix) {
    proj := SubStr(prefix, -3)
    insults := ["POXED WOODLOUSE", "SCRUB-FACED CIVILIAN", "HIDEOUS SEABIRD", "BEEF-WITTED NINNY",
        "DISAGREEABLE BILGE DWELLER", "SOGGY RODENT THIEF", "SCURRILOUS INSECT",
        "INFAMOUS SCOUNDREL", "BANKRUPT SEA LIZARD", "FLEA RIDDEN LANDLUBBER",
        "YELLOWBELLIED BARNACLE EATER", "FRESHWATER POND LARVAE", "LANKY BOTTOMSCRAPER",
        "COWARDLY SEAGULL", "BLUBBERIN SQUID", "MILK HEADED BABOON", "TOOTHLESS OLD MAN",
        "ILL BRED BILIOUS OX", "UNREDEEMABLE VILLIAN", "VILE FELLOW",
        "THICK HEADED MISCREANT", "UNRELENTING PARASITE"]
    insult := insults[Random(1, insults.Length)]
    result := InputBox(
        "AARGHGH! Enter ye olde " proj " issue number AND FIRE THE CANNONS YE " insult "!",
        "Open " proj " Issue", "H150 T15")
    if result.Result != "OK" || result.Value = ""
        return
    url := (SubStr(prefix, 1, 4) = "http") ? prefix : "https://" prefix
    Run(url "-" result.Value)
}

; Restarts the server task (installer.ps1 -Action restart waits until it answers), then reloads
; this script — one key to apply code changes on either side. The extension re-pushes its tabs
; as soon as it sees the server again; AHK re-pushes profiles on startup.
RestartAltTabSucks() {
    ToolTip("Restarting AltTabSucks…")
    RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\installer.ps1" -Action restart',, "Hide")
    Reload()
}
