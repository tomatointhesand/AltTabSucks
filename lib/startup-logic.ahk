; startup-logic.ahk - pure decision logic behind the startup manager (lib/startup-manager.ahk).
;
; Nothing in here launches anything or looks at a real window, so tests/ahk/test-startup.ahk can
; run it anywhere, including under Wine. startup-manager.ahk keeps the live state, calls into this
; every tick, and acts on the answer.
;
; An item is a Map from startup.json: name, command, workingDir, process, delay (seconds), afterReady
; (1: wait for the previous item to be ready, not just launched), ready ("window", "process", or
; "launched": done once it's launched, nothing watched),
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
;   noprocess - its process never showed up before the timeout (likewise); for an item that isn't
;               watched (StartupWatched), it was launched, which is all there is to wait for
;   failed    - the launch itself failed (state["error"] says why)
;   already   - was already running, so not launched
;   off       - disabled, or not launched because this isn't a startup run (the editor)

StartupIsDone(status) {
    return status = "ready" || status = "nowindow" || status = "noprocess" || status = "failed" || status = "already"
}

; Whether there's anything to watch for after launching: otherwise the item is done as soon as it's
; launched (✔ launched). Not with ready = "launched", no process, or a process name that's a
; script's (a script runs inside cmd.exe/powershell.exe/wscript.exe, so no process ever has it).
StartupWatched(item) {
    if item.Get("builtin", "") != ""
        return true
    if item.Get("ready", "window") = "launched"
        return false
    proc := item.Get("process", "")
    return proc != "" && !StartupIsScript(proc)
}

StartupIsScript(name) {
    return RegExMatch(name, "i)\.(bat|cmd|ps1|vbs|js|wsf)$") != 0
}

; Whether a command runs a script: nothing to watch, so it's ready once it's launched.
StartupCommandIsScript(command) {
    return StartupIsScript(_StartupProgramOf(command))
}

STARTUP_CHECK := Chr(0x2714)  ; heavy check mark, shown green

; How an item's start went: "ok" (it's up), "warn" (timed out), "error" (the launch failed), "" (not
; done yet, or off). Colors the status column, and only a run where everything is "ok" closes the
; window by itself.
StartupOutcome(item, st) {
    switch st["status"] {
        case "ready", "already": return "ok"
        case "noprocess":        return StartupWatched(item) ? "warn" : "ok"
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
        case "running":  return item.Get("builtin", "") = "alttabsucks" ? "waiting for tray icon" : "waiting for window"
        case "ready":    return STARTUP_CHECK
        case "nowindow": return item.Get("builtin", "") = "alttabsucks" ? "no tray icon yet" : "no window yet (Ready: process?)"
        case "noprocess":
            return StartupWatched(item) ? "no " item.Get("process", "") " seen yet" : STARTUP_CHECK " launched"
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
; Discord.exe" launchers name it in their arguments; otherwise it's the program the command runs,
; "" for a script (no process has its name).
StartupProcessFromCommand(command) {
    if RegExMatch(command, 'i)--processStart\s+"?([^"\s]+)', &m)
        return m[1]
    name := _StartupProgramOf(command)
    return StartupIsScript(name) ? "" : name
}

_StartupProgramOf(command) {
    command := Trim(command)
    if SubStr(command, 1, 1) = '"'
        exe := SubStr(command, 2, InStr(command, '"', , 2) - 2)
    else if RegExMatch(command, "i)^.*?\.(exe|bat|cmd|ps1|vbs|js|wsf)(?=\s|$)", &m)
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
        if !StartupWatched(item)
            r["watched"] := 0
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

STARTUP_HISTORY_HEADER := ["Item", "Result", "Launched at", "Ready at", "Took"]

; The History view from parsed history rows (oldest first): newest run first, each run a heading
; ("when · trigger · started N s after logon · all ready at N s") over one row per item, in that
; run's order, with STARTUP_HISTORY_HEADER's columns. Times are since the manager started.
; Returns {header, runs: [{title, rows}]}.
StartupHistoryTable(historyRows) {
    runs := []
    i := historyRows.Length
    while i >= 1 {
        row := historyRows[i--]
        title := StrReplace(row.Get("time", ""), "T", " ") " · " row.Get("trigger", "")
        if row.Get("logonToStartMs", "") != ""
            title .= " · started " StartupFormatSeconds(row["logonToStartMs"]) " after logon"
        if row.Get("allReadyMs", "") != ""
            title .= " · all ready at " StartupFormatSeconds(row["allReadyMs"])
        lines := []
        for it in row.Get("items", []) {
            launched := it.Get("launchMs", ""), ready := it.Get("readyMs", "")
            lines.Push([it.Get("name", ""), _StartupHistoryResult(it), StartupFormatSeconds(launched),
                        StartupFormatSeconds(ready), ready != "" && launched != "" ? StartupFormatSeconds(ready - launched) : ""])
        }
        runs.Push({title: title, rows: lines})
    }
    return {header: STARTUP_HISTORY_HEADER, runs: runs}
}

_StartupHistoryResult(it) {
    switch it.Get("status", "") {
        case "ready":     return "ready"
        case "nowindow":  return "no window" (it.Has("processMs") ? " (process at " StartupFormatSeconds(it["processMs"]) ")" : "")
        case "noprocess": return it.Get("watched", 1) = 0 ? "launched" : "not seen"
        case "already":   return "already running"
    }
    return it.Get("status", "")  ; failed, off, or an unfinished status
}
