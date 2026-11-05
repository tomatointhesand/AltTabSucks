; test-startup.ahk - tests for lib/startup-logic.ahk (the startup manager's scheduling, status text
; and history) and lib/json.ahk (its file format). Run with: bash dev-scripts/run-ahk-tests.sh

#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_ScriptDir%\assert.ahk
#Include %A_ScriptDir%\..\..\lib\json.ahk
#Include %A_ScriptDir%\..\..\lib\startup-logic.ahk

Item(name, delay := 0, afterReady := 0) => Map("name", name, "delay", delay, "afterReady", afterReady, "enabled", 1)
State(status, extra*) {
    st := Map("status", status)
    i := 1
    while i < extra.Length
        st[extra[i]] := extra[i + 1], i += 2
    return st
}
StatesFor(items, statuses*) {
    m := Map()
    for i, item in items
        m[item] := statuses.Has(i) ? statuses[i] : State("pending")
    return m
}

; ---- json -------------------------------------------------------------------------------------
v := Json_Parse('{"b": 1, "a": [true, false, null, -2.5, "x\"y\\z\n\u00e9"], "e": {}, "f": []}')
AssertEq(Type(v), "Map", "objects parse to Maps")
keys := ""
for k in v
    keys .= k ","
AssertEq(keys, "a,b,e,f,", "  ...with all their keys")
AssertEq(v["a"][1] " " v["a"][2] " [" v["a"][3] "]", "1 0 []", "true/false/null -> 1/0/empty")
AssertEq(v["a"][4], -2.5, "numbers")
AssertEq(v["a"][5], 'x"y\z`né', "string escapes")
AssertEq(Json_Stringify(v), '{"a":[1,0,"",-2.5,"x\"y\\z\né"],"b":1,"e":{},"f":[]}', "stringify round trip")
AssertEq(Json_Stringify(Map("k", "1")), '{"k":"1"}', "a numeric-looking string stays a string")
AssertEq(Json_Stringify(Map("a", [1, 2]), "  "), '{`n  "a": [`n    1,`n    2`n  ]`n}', "indented output")
AssertEq(Json_Parse(Json_Stringify(Map("path", "C:\Program Files\x.exe", "tab", "a`tb")))["path"], "C:\Program Files\x.exe", "backslashes round trip")
bad := ""
try Json_Parse('{"a": 1')
catch as e
    bad := e.Message
AssertEq(InStr(bad, "JSON") > 0, true, "truncated JSON throws")
AssertEq(Json_Parse('  [ ]  ').Length, 0, "empty array with whitespace")

; ---- StartupProcessFromCommand ------------------------------------------------------------------
AssertEq(StartupProcessFromCommand('"C:\Program Files\Steam\steam.exe" -silent'), "steam.exe", "quoted exe with args")
AssertEq(StartupProcessFromCommand('C:\Program Files\App\app.exe /min'), "app.exe", "unquoted exe with spaces in the path")
AssertEq(StartupProcessFromCommand('C:\Users\me\AppData\Local\Discord\Update.exe --processStart Discord.exe'), "Discord.exe", "Update.exe --processStart names the real process")
AssertEq(StartupProcessFromCommand('notepad'), "notepad", "bare command")

; ---- StartupPlan --------------------------------------------------------------------------------
a := Item("A", 0), b := Item("B", 2), c := Item("C", 1.5)
items := [a, b, c]
p := StartupPlan(items, StatesFor(items))
AssertEq(p[a].at " " p[b].at " " p[c].at, "0 2000 3500", "delays chain: each counts from the previous item's launch")

st := StatesFor(items, State("launched", "launchMs", 300))
p := StartupPlan(items, st)
AssertEq(p.Has(a), false, "a launched item isn't planned")
AssertEq(p[b].at " " p[c].at, "2300 3800", "  ...and the next ones count from when it actually launched")

b["afterReady"] := 1
p := StartupPlan(items, StatesFor(items, State("launched", "launchMs", 300)))
AssertEq(p[b].at = "" && p[b].after = a && p[b].why = "ready", true, "afterReady waits for the previous item to be ready")
AssertEq(p[c].at = "" && p[c].after = b && p[c].why = "launch", true, "  ...and the item behind it waits too")
AssertEq(StartupStatusText(b, State("pending"), p[b], 500), "after A is ready", "  status text for the blocked item")
AssertEq(StartupStatusText(c, State("pending"), p[c], 500), "after B launches", "  ...and the one behind it")

p := StartupPlan(items, StatesFor(items, State("ready", "launchMs", 300, "readyMs", 4000, "doneMs", 4000)))
AssertEq(p[b].at " " p[c].at, "6000 7500", "once it's ready, the countdown starts from then")
p := StartupPlan(items, StatesFor(items, State("nowindow", "launchMs", 300, "doneMs", 30300)))
AssertEq(p[b].at, 32300, "a timed-out item counts as done too")

p := StartupPlan(items, StatesFor(items, State("launched", "launchMs", 300)), true)
AssertEq(p[b].at " " p[c].at, "300 300", "Launch all now: no delays, no waiting for ready")

b["afterReady"] := 0
p := StartupPlan(items, StatesFor(items, State("pending"), State("off")))
AssertEq(p.Has(b) " " p[c].at, "0 1500", "an off item is skipped: the next one counts from the one before it")
p := StartupPlan(items, StatesFor(items, State("off"), State("pending")))
AssertEq(p[b].at, 2000, "  ...including when the first item is off")
p := StartupPlan(items, StatesFor(items, State("already", "launchMs", 50, "doneMs", 50)))
AssertEq(p[b].at, 2050, "an already-running item counts as launched when it was checked")
b["delay"] := "oops"
AssertEq(StartupPlan(items, StatesFor(items))[b].at, 0, "a non-numeric delay counts as 0")
b["delay"] := 2

; ---- StartupStatusText --------------------------------------------------------------------------
AssertEq(StartupStatusText(b, State("pending"), {at: 2000, after: "", why: ""}, 750), "in 1.3 s", "countdown")
AssertEq(StartupStatusText(b, State("pending"), {at: 2000, after: "", why: ""}, 2100), "launching", "due now")
AssertEq(StartupStatusText(b, State("failed", "error", "not found"), "", 0), "failed: not found", "failed shows the error")
AssertEq(StartupStatusText(Map("name", "x", "enabled", 0), State("off"), "", 0), "off", "disabled item")
AssertEq(StartupStatusText(Map("name", "x", "enabled", 1), State("off"), "", 0), "", "enabled item in the editor: no status")
AssertEq(StartupStatusText(b, State("ready"), "", 0), STARTUP_CHECK, "ready is a check mark")
AssertEq(StartupStatusText(b, State("already"), "", 0), STARTUP_CHECK " already running", "  ...already running too")
AssertEq(StartupStatusText(Map("process", "x.exe"), State("noprocess"), "", 0), "no x.exe seen yet", "a timed-out item is still watched")

; ---- StartupOutcome / StartupAllUp ---------------------------------------------------------------
AssertEq(StartupOutcome(b, State("ready")) StartupOutcome(b, State("already")), "okok", "ready and already running are up")
AssertEq(StartupOutcome(Map("process", ""), State("noprocess")), "ok", "  ...and launched with nothing to watch")
AssertEq(StartupOutcome(Map("process", "x.exe"), State("noprocess")) StartupOutcome(b, State("nowindow")), "warnwarn", "timeouts are warnings")
AssertEq(StartupOutcome(b, State("failed")), "error", "a failed launch is an error")
AssertEq(StartupOutcome(b, State("running")) StartupOutcome(b, State("pending")), "", "not done yet")
two := [Item("A"), Item("B")]
AssertEq(StartupAllUp(two, StatesFor(two, State("ready"), State("off"))), true, "everything up (off items don't count)")
AssertEq(StartupAllUp(two, StatesFor(two, State("ready"), State("nowindow"))), false, "  ...not while one timed out")
AssertEq(StartupAllUp(two, StatesFor(two, State("ready"), State("running"))), false, "  ...or is still starting")

; ---- history ------------------------------------------------------------------------------------
st := StatesFor(items, State("ready", "launchMs", 10, "processMs", 40, "readyMs", 900, "doneMs", 900),
                       State("nowindow", "launchMs", 2900, "processMs", 3000, "doneMs", 32900),
                       State("already", "launchMs", 2900, "doneMs", 2900))
row := StartupHistoryRow(items, st, "logon", "2026-10-26T08:00:00", 41000, 1200)
AssertEq(row["allReadyMs"], 32900, "allReadyMs: the last item to finish (already-running ones don't count)")
AssertEq(Json_Stringify(row["items"][1]), '{"afterReady":0,"delayMs":0,"launchMs":10,"name":"A","processMs":40,"ready":"window","readyMs":900,"status":"ready"}', "an item row has its settings and timings")
AssertEq(row["items"][2].Has("readyMs"), false, "  ...and no readyMs when no window showed up")
line := Json_Stringify(row)
AssertEq(InStr(line, "`n"), 0, "a history row is one line")

older := Json_Parse(line)
older["time"] := "2026-10-25T08:00:00"
older["items"][1]["name"] := "Old app"
t := StartupHistoryTable([older, Json_Parse(line)], ["C", "A", "B"])
AssertEq(t.header.Length, 8, "history header: 4 fixed columns + one per item name ever seen")
AssertEq(t.header[5] " " t.header[6] " " t.header[7] " " t.header[8], "C A B Old app", "  ...current order first, then older names")
AssertEq(t.rows[1][1], "2026-10-26 08:00:00", "newest row first")
AssertEq(t.rows[1][3] " | " t.rows[1][4], "1.2 s | 32.9 s", "  ...with logon-to-start and all-ready times")
AssertEq(t.rows[1][6], "0.9 s (0.9 s)", "a cell: ready time (time after launch)")
AssertEq(t.rows[1][7], "3.0 s (0.1 s) no window", "  ...no window: process time")
AssertEq(t.rows[1][5], "already running", "  ...already running")
AssertEq(t.rows[2][6] " | " t.rows[2][8], " | 0.9 s (0.9 s)", "an item missing from an old row is blank")

AssertDone()
