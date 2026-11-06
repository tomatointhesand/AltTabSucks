#!/usr/bin/env python3
"""
The startup manager's run: launches due items, watches them come up, times them out — the Linux
side of _SmTick/_SmWatch/_SmLaunch in lib/startup-manager.ahk. The window (startup_manager.py)
owns one Runner and calls tick() several times a second; everything that touches the real system
goes through a Probes object, so tests drive it with fakes.
"""

import startup_logic as L


class Probes:
    """What the runner asks the system. startup_manager.py's SystemProbes is the real one."""

    def launch(self, item: dict):
        """Starts the item; returns a handle (a pid) or raises OSError/ValueError with the reason."""
        raise NotImplementedError

    def already_running(self, item: dict) -> bool:
        raise NotImplementedError

    def process_seen(self, item: dict, handle) -> bool:
        raise NotImplementedError

    def window_seen(self, item: dict, handle) -> bool:
        raise NotImplementedError

    def builtin_ready(self) -> bool:
        raise NotImplementedError


def watchable(item: dict) -> bool:
    """Whether there's anything to watch for after launching: otherwise the item is done as soon
    as it's launched (✔ launched)."""
    return bool(item.get("builtin") or item.get("process") or item.get("windowClass"))


class Runner:
    def __init__(self, items: list, config: dict, probes: Probes, now):
        self.items = items          # the same list the window edits
        self.config = config
        self.probes = probes
        self.now = now              # () -> ms since the run started
        self.states = [{"status": "off"} for _ in items]
        self.handles = [None for _ in items]
        self.running = False
        self.finished = False
        self.skip_delays = False
        self.plan = {}

    def start(self):
        self.states[:] = [{"status": "pending" if item.get("enabled", 1) else "off"} for item in self.items]
        self.handles[:] = [None for _ in self.items]
        self.running, self.finished, self.skip_delays = True, False, False

    # Kept in step with the window's list edits.
    def insert(self, i: int):
        self.states.insert(i, {"status": "off"})
        self.handles.insert(i, None)

    def remove(self, i: int):
        del self.states[i]
        del self.handles[i]

    def swap(self, i: int, j: int):
        for lst in (self.states, self.handles):
            lst[i], lst[j] = lst[j], lst[i]

    def set_enabled(self, i: int, enabled: bool):
        """Ticking an item on or off during a run: a pending one is dropped, an unlaunched one
        joins in."""
        st = self.states[i]
        if self.running and not enabled and st["status"] == "pending":
            st["status"] = "off"
        elif self.running and enabled and st["status"] == "off" and "launchMs" not in st:
            st["status"] = "pending"

    def timeout_ms(self) -> int:
        return int(L.num(self.config, "readyTimeoutSeconds") * 1000) or 30000

    def tick(self) -> bool:
        """One step. Returns True on the tick the run finished (every item done)."""
        if self.running:
            while True:  # launch everything that's due (several can be due at once with 0 s delays)
                self.plan = L.plan(self.items, self.states, self.skip_delays)
                due = next((i for i in range(len(self.items))
                            if i in self.plan and self.plan[i]["at"] is not None and self.plan[i]["at"] <= self.now()), None)
                if due is None:
                    break
                self._launch(due)
        self._watch()
        if self.running and L.all_done(self.states):
            self.running, self.finished = False, True
            return True
        return False

    def _launch(self, i: int):
        item, st = self.items[i], self.states[i]
        st["launchMs"] = self.now()
        try:
            if not item.get("builtin") and self.probes.already_running(item):
                st["status"], st["doneMs"] = "already", self.now()
                return
            self.handles[i] = self.probes.launch(item)
        except (OSError, ValueError) as e:
            st["status"], st["error"], st["doneMs"] = "failed", str(e).splitlines()[0] if str(e) else type(e).__name__, self.now()
            return
        if watchable(item):
            st["status"] = "launched"
        else:  # nothing to watch for: done as soon as it's launched
            st["status"], st["doneMs"] = "noprocess", self.now()

    def _ready(self, item: dict, handle) -> bool:
        if item.get("builtin"):
            return self.probes.builtin_ready()
        if item.get("ready", "window") == "process":
            return self.probes.process_seen(item, handle)
        return self.probes.window_seen(item, handle)

    def _watch(self):
        """Moves launched items along: process seen, then ready, or timed out. A timed-out item
        keeps being watched and turns ready if it shows up late; its doneMs stays the timeout,
        which is what the items after it were scheduled from."""
        for i, item in enumerate(self.items):
            st = self.states[i]
            s = st["status"]
            late = s in ("nowindow", "noprocess")
            if not (s in ("launched", "running") or late) or not watchable(item):
                continue
            handle = self.handles[i]
            if s in ("launched", "noprocess") and (item.get("builtin") or self.probes.process_seen(item, handle)):
                st["processMs"] = self.now()
                s = st["status"] = "nowindow" if late else "running"
            if s in ("running", "nowindow") and self._ready(item, handle):
                st["readyMs"] = self.now()
                st["status"] = "ready"
                if not late:
                    st["doneMs"] = st["readyMs"]
            elif not late and self.now() - st["launchMs"] > self.timeout_ms():
                st["doneMs"] = self.now()
                st["status"] = "nowindow" if s == "running" else "noprocess"
