; startup-logic.ahk - pure decision logic behind the startup manager (lib/startup-manager.ahk).
;
; Nothing in here launches anything or looks at a real window, so tests/ahk/test-startup.ahk can
; run it anywhere, including under Wine. startup-manager.ahk keeps the live state, calls into this
; every tick, and acts on the answer.
;
; An item is a Map from startup.json: name, command, workingDir, process, delay (seconds), afterReady
; (1: wait for the previous item to be ready, not just launched), ready ("window" or "process"),
; enabled, and optionally builtin ("alttabsucks") and windows (the Windows startup entry it took
; over, kept by Server/StartupItems.ps1).
;
; A state is a Map per item: status, plus launchMs / processMs / readyMs / doneMs once known, all in
; ms since the manager started. Statuses:
;   pending   - not launched yet
;   launched  - launched, its process not seen yet
;   running   - process seen, waiting for its first window (ready = "window")
;   ready     - first window seen (or process seen, for ready = "process")
;   nowindow  - process seen, but no window before the timeout (still watched: it can turn ready)
;   noprocess - its process never showed up before the timeout (likewise)
;   failed    - the launch itself failed (state["error"] says why)
;   already   - was already running, so not launched
;   off       - disabled, or not launched because this isn't a startup run (the editor)

StartupIsDone(status) {
    return status = "ready" || status = "nowindow" || status = "noprocess" || status = "failed" || status = "already"
}

STARTUP_CHECK := Chr(0x2714)  ; heavy check mark, shown green

; How an item's start went: "ok" (it's up), "warn" (timed out), "error" (the launch failed), "" (not
; done yet, or off). Colors the status column, and only a run where everything is "ok" closes the
; window by itself.
StartupOutcome(item, st) {
    switch st["status"] {
        case "ready", "already": return "ok"
        case "noprocess":        return item.Get("process", "") = "" ? "ok" : "warn"
        case "nowindow":         return "warn"
        case "failed":           return "error"
    }
    return ""
}

; True when every item taking part in the run (not "off") is up.
StartupAllUp(items, states) {
    for item in items {
        st := states[item]
        if st["status"] != "off" && StartupOutcome(item, st) != "ok"
            return false
    }
    return true
}

; When each pending item launches. Items launch in order: an item's countdown starts when the
; previous enabled item launched (or, with afterReady, finished). Returns a Map item -> {at, after, why}:
;   at    - ms (since start) the item is due, "" if it can't be known yet
;   after - when at = "": the item it's waiting on, and why: "ready" (afterReady) or "launch" (that
;           item is itself waiting)
; at can lie in the past: the caller launches everything due. With skipDelays (the "Launch all
; now" button), delays and afterReady are ignored.
StartupPlan(items, states, skipDelays := false) {
    plan := Map()
    prev := "", prevAt := 0  ; projected launch time of the previous item; the first counts from 0
    for item in items {
        st := states[item]
        if st["status"] = "off"
            continue
        delayMs := skipDelays ? 0 : Round(_StartupNum(item, "delay") * 1000)
        if st["status"] != "pending" {
            launchedAt := st.Has("launchMs") ? st["launchMs"] : 0
        } else if prev = "" {
            plan[item] := {at: delayMs, after: "", why: ""}
            launchedAt := delayMs
        } else if item.Get("afterReady", 0) && !skipDelays {
            pst := states[prev]
            if StartupIsDone(pst["status"]) {
                plan[item] := {at: pst["doneMs"] + delayMs, after: "", why: ""}
                launchedAt := pst["doneMs"] + delayMs
            } else {
                plan[item] := {at: "", after: prev, why: "ready"}
                launchedAt := ""
            }
        } else if prevAt = "" {
            plan[item] := {at: "", after: prev, why: "launch"}  ; behind an item that's itself blocked
            launchedAt := ""
        } else {
            plan[item] := {at: prevAt + delayMs, after: "", why: ""}
            launchedAt := prevAt + delayMs
        }
        prev := item, prevAt := launchedAt
    }
    return plan
}

_StartupNum(item, key) {
    v := item.Get(key, 0)
    return IsNumber(v) ? v + 0 : 0
}

; The status column's text for one item.
StartupStatusText(item, st, planned, nowMs) {
    switch st["status"] {
        case "pending":
            if planned.at = ""
                return "after " planned.after["name"] (planned.why = "ready" ? " is ready" : " launches")
            remaining := planned.at - nowMs
            return remaining > 0 ? "in " Format("{:.1f} s", Ceil(remaining / 100) / 10) : "launching"  ; up: never "in 0.0 s"
        case "launched": return "starting"
        case "running":  return "waiting for window"
        case "ready":    return STARTUP_CHECK
        case "nowindow": return "no window yet (Ready: process?)"
        case "noprocess":
            p := item.Get("process", "")
            return p = "" ? STARTUP_CHECK " launched" : "no " p " seen yet"
        case "failed":   return "failed: " st.Get("error", "")
        case "already":  return STARTUP_CHECK " already running"
        case "off":      return item.Get("enabled", 1) ? "" : "off"
    }
    return st["status"]
}

; 1234 -> "1.2 s", "" -> ""
StartupFormatSeconds(ms) {
    return ms = "" ? "" : Format("{:.1f} s", ms / 1000)
}

; The process whose window marks a command as ready: Discord-style "Update.exe --processStart
; Discord.exe" launchers name it in their arguments; otherwise it's the program the command runs.
StartupProcessFromCommand(command) {
    command := Trim(command)
    if RegExMatch(command, 'i)--processStart\s+"?([^"\s]+)', &m)
        return m[1]
    if SubStr(command, 1, 1) = '"'
        exe := SubStr(command, 2, InStr(command, '"', , 2) - 2)
    else if RegExMatch(command, "i)^.*?\.exe(?=\s|$)", &m)
        exe := m[0]
    else
        exe := StrSplit(command, " ")[1]
    SplitPath(exe, &name)
    return name
}

; One startup-history.jsonl row: when, how (logon / manual), how long after boot and logon the
; manager started, when everything was ready, and each item's settings and timings (ms since the
; manager started), so a change in delays can be lined up against the timings it produced.
StartupHistoryRow(items, states, trigger, time, bootToStartMs, logonToStartMs) {
    rows := [], allReady := 0
    for item in items {
        st := states[item]
        r := Map("name", item["name"], "status", st["status"],
                 "delayMs", Round(_StartupNum(item, "delay") * 1000), "afterReady", item.Get("afterReady", 0) ? 1 : 0,
                 "ready", item.Get("ready", "window"))
        for k in ["launchMs", "processMs", "readyMs"]
            if st.Has(k)
                r[k] := st[k]
        if st.Has("doneMs") && st["status"] != "already"
            allReady := Max(allReady, st["doneMs"])
        rows.Push(r)
    }
    return Map("time", time, "trigger", trigger, "bootToStartMs", bootToStartMs, "logonToStartMs", logonToStartMs,
               "allReadyMs", allReady, "items", rows)
}

; The history tab's table from parsed history rows (oldest first): newest first, one column per item
; name (the current list's order, then names only seen in older rows), each cell the item's ready
; time and, in brackets, how long it took after launching. Returns {header, rows}.
StartupHistoryTable(historyRows, currentNames) {
    names := [], seen := Map()
    seen.CaseSense := false
    for n in currentNames
        if !seen.Has(n)
            names.Push(n), seen[n] := 1
    for row in historyRows
        for it in row.Get("items", [])
            if !seen.Has(it["name"])
                names.Push(it["name"]), seen[it["name"]] := 1
    header := ["When", "Trigger", "Logon to start", "All ready"]
    for n in names
        header.Push(n)
    out := []
    i := historyRows.Length
    while i >= 1 {
        row := historyRows[i--]
        cells := Map()
        cells.CaseSense := false
        for it in row.Get("items", [])
            cells[it["name"]] := _StartupHistoryCell(it)
        line := [StrReplace(row.Get("time", ""), "T", " "), row.Get("trigger", ""),
                 StartupFormatSeconds(row.Get("logonToStartMs", "")), StartupFormatSeconds(row.Get("allReadyMs", ""))]
        for n in names
            line.Push(cells.Get(n, ""))
        out.Push(line)
    }
    return {header: header, rows: out}
}

_StartupHistoryCell(it) {
    switch it.Get("status", "") {
        case "ready", "nowindow":
            at := it.Has("readyMs") ? it["readyMs"] : it.Get("processMs", "")
            own := at != "" && it.Has("launchMs") ? " (" StartupFormatSeconds(at - it["launchMs"]) ")" : ""
            return StartupFormatSeconds(at) own (it["status"] = "nowindow" ? " no window" : "")
        case "already": return "already running"
        case "off": return "off"
    }
    return it.Get("status", "")
}
