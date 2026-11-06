#!/usr/bin/env python3
"""
Pure decision logic behind the Linux startup manager (startup_manager.py) — the port of
lib/startup-logic.ahk, with the same rules, statuses and history format, so a startup.json or
startup-history.jsonl row means the same thing on both platforms.

Nothing in here launches anything or looks at a real process or window, so tests can run it
anywhere. startup_manager.py keeps the live state, calls into this every tick, and acts on the
answer.

An item is a dict from startup.json: name, command, workingDir, process, delay (seconds),
afterReady (1: wait for the previous item to be ready, not just launched), ready ("window" or
"process"), enabled, and optionally builtin ("alttabsucks"), windowClass (a window's resourceClass
that also counts as this app's window) and autostart (the XDG autostart entry it took over, kept by
autostart_items.py).

A state is a dict per item: status, plus launchMs / processMs / readyMs / doneMs once known, all in
ms since the manager started. Statuses:
  pending   - not launched yet
  launched  - launched, its process not seen yet
  running   - process seen, waiting for its first window (ready = "window")
  ready     - first window seen (or process seen, for ready = "process")
  nowindow  - process seen, but no window before the timeout (still watched: it can turn ready)
  noprocess - its process never showed up before the timeout (likewise)
  failed    - the launch itself failed (state["error"] says why)
  already   - was already running, so not launched
  off       - disabled, or not launched because this isn't a startup run (the editor)

States are keyed by the item's index in the list (items are plain dicts, so not hashable).
"""

import math

CHECK = "✔"  # heavy check mark, shown green

DONE = {"ready", "nowindow", "noprocess", "failed", "already"}


def is_done(status: str) -> bool:
    return status in DONE


def num(item: dict, key: str) -> float:
    v = item.get(key, 0)
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v))
    except ValueError:
        return 0.0


def plan(items: list, states: list, skip_delays: bool = False) -> dict:
    """When each pending item launches. Items launch in order: an item's countdown starts when
    the previous enabled item launched (or, with afterReady, finished). Returns {index: {"at",
    "after", "why"}}:
      at    - ms (since start) the item is due, None if it can't be known yet
      after - when at is None: the index of the item it's waiting on, and why: "ready"
              (afterReady) or "launch" (that item is itself waiting)
    at can lie in the past: the caller launches everything due. With skip_delays (the "Launch the
    rest now" button), delays and afterReady are ignored."""
    out = {}
    prev, prev_at = None, 0
    for i, item in enumerate(items):
        st = states[i]
        if st["status"] == "off":
            continue
        delay_ms = 0 if skip_delays else round(num(item, "delay") * 1000)
        if st["status"] != "pending":
            launched_at = st.get("launchMs", 0)
        elif prev is None:
            out[i] = {"at": delay_ms, "after": None, "why": ""}
            launched_at = delay_ms
        elif item.get("afterReady") and not skip_delays:
            pst = states[prev]
            if is_done(pst["status"]):
                out[i] = {"at": pst["doneMs"] + delay_ms, "after": None, "why": ""}
                launched_at = pst["doneMs"] + delay_ms
            else:
                out[i] = {"at": None, "after": prev, "why": "ready"}
                launched_at = None
        elif prev_at is None:
            out[i] = {"at": None, "after": prev, "why": "launch"}  # behind an item that's itself blocked
            launched_at = None
        else:
            out[i] = {"at": prev_at + delay_ms, "after": None, "why": ""}
            launched_at = prev_at + delay_ms
        prev, prev_at = i, launched_at
    return out


def status_text(items: list, i: int, st: dict, planned, now_ms: int) -> str:
    """The Status column's text for item i."""
    item = items[i]
    builtin = item.get("builtin") == "alttabsucks"
    s = st["status"]
    if s == "pending":
        if planned is None:
            return ""
        if planned["at"] is None:
            other = items[planned["after"]].get("name", "?") if planned["after"] is not None else "?"
            return f"after {other} " + ("is ready" if planned["why"] == "ready" else "launches")
        remaining = planned["at"] - now_ms
        # Rounded up: never "in 0.0 s".
        return f"in {math.ceil(remaining / 100) / 10:.1f} s" if remaining > 0 else "launching"
    if s == "launched":
        return "starting"
    if s == "running":
        return "waiting for AltTabSucks" if builtin else "waiting for window"
    if s == "ready":
        return CHECK
    if s == "nowindow":
        return "AltTabSucks not answering yet" if builtin else "no window yet (Ready: process?)"
    if s == "noprocess":
        p = item.get("process", "")
        return f"{CHECK} launched" if not p else f"no {p} seen yet"
    if s == "failed":
        return "failed: " + st.get("error", "")
    if s == "already":
        return f"{CHECK} already running"
    if s == "off":
        return "" if item.get("enabled", 1) else "off"
    return s


def outcome(item: dict, st: dict) -> str:
    """How an item's start went: "ok" (it's up), "warn" (timed out), "error" (the launch failed),
    "" (not done yet, or off). Colors the status column, and only a run where everything is "ok"
    closes the window by itself."""
    s = st["status"]
    if s in ("ready", "already"):
        return "ok"
    if s == "noprocess":
        return "ok" if not item.get("process", "") else "warn"
    if s == "nowindow":
        return "warn"
    if s == "failed":
        return "error"
    return ""


def all_up(items: list, states: list) -> bool:
    """True when every item taking part in the run (not "off") is up."""
    return all(states[i]["status"] == "off" or outcome(item, states[i]) == "ok" for i, item in enumerate(items))


def all_done(states: list) -> bool:
    return all(st["status"] == "off" or is_done(st["status"]) for st in states)


def format_seconds(ms) -> str:
    return "" if ms is None or ms == "" else f"{ms / 1000:.1f} s"


def history_row(items: list, states: list, trigger: str, time: str, boot_to_start_ms, logon_to_start_ms) -> dict:
    """One startup-history.jsonl line (same fields as lib/startup-logic.ahk's StartupHistoryRow)."""
    rows, all_ready = [], 0
    for i, item in enumerate(items):
        st = states[i]
        r = {"name": item.get("name", ""), "status": st["status"],
             "delayMs": round(num(item, "delay") * 1000), "afterReady": 1 if item.get("afterReady") else 0,
             "ready": item.get("ready", "window")}
        for k in ("launchMs", "processMs", "readyMs"):
            if k in st:
                r[k] = st[k]
        if "doneMs" in st and st["status"] != "already":
            all_ready = max(all_ready, st["doneMs"])
        rows.append(r)
    return {"time": time, "trigger": trigger, "bootToStartMs": boot_to_start_ms, "logonToStartMs": logon_to_start_ms,
            "allReadyMs": all_ready, "items": rows}


def _history_cell(it: dict) -> str:
    s = it.get("status", "")
    if s in ("ready", "nowindow"):
        at = it.get("readyMs", it.get("processMs", ""))
        own = f" ({format_seconds(at - it['launchMs'])})" if at != "" and "launchMs" in it else ""
        return format_seconds(at) + own + (" no window" if s == "nowindow" else "")
    if s == "already":
        return "already running"
    return s


def history_table(history_rows: list, current_names: list) -> dict:
    """The History view: newest run first, one column per item name (current order first, then
    names only older runs have). {"header": [...], "rows": [[...], ...]}."""
    names, seen = [], set()
    for n in current_names:
        if n.lower() not in seen:
            names.append(n)
            seen.add(n.lower())
    for row in history_rows:
        for it in row.get("items", []):
            n = it.get("name", "")
            if n.lower() not in seen:
                names.append(n)
                seen.add(n.lower())
    header = ["When", "Trigger", "Logon to start", "All ready"] + names
    out = []
    for row in reversed(history_rows):
        cells = {it.get("name", "").lower(): _history_cell(it) for it in row.get("items", [])}
        line = [str(row.get("time", "")).replace("T", " "), row.get("trigger", ""),
                format_seconds(row.get("logonToStartMs", "")), format_seconds(row.get("allReadyMs", ""))]
        line += [cells.get(n.lower(), "") for n in names]
        out.append(line)
    return {"header": header, "rows": out}
