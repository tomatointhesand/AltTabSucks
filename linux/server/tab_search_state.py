#!/usr/bin/env python3
"""
Server-side state behind the tab search popup (see tab_search.py for the ranking itself):

- Recently closed tabs and a bookmark snapshot per browser profile, pushed by the extension
  whenever they change and saved to disk (browser-data.json under $XDG_STATE_HOME/alttabsucks),
  so the popup can still offer them while the browser is closed, or after the server restarts.
- Which profiles are live: a profile's browser counts as running while its extension keeps
  polling GET /switchtab (every 50ms when it's up). Open tabs of profiles that aren't live are
  never shown, since the server keeps a closed browser's last tab list.
- Query-time bookmark search: for a live profile the query goes to the browser itself (a
  searchBookmarks command through the switch queue, answered with POST /bookmark-results); a
  profile that isn't live, or doesn't answer in time, is searched in its snapshot instead.
- The handshake with the KWin script, which is the only thing that can raise a window on Wayland:
  main.js calls BeginTabSearch before showing the popup, then polls TakeTabSearchResult until the
  popup reports a choice (or a cancel) through POST /tab-search/action or /tab-search/closed.
"""

import json
import os
import threading
import time
import uuid
from pathlib import Path

LIVE_SECONDS = 2.0               # no GET /switchtab poll for this long -> the browser is closed
BOOKMARK_SEARCH_TIMEOUT = 0.5    # how long a live browser gets to answer a bookmark search


def default_state_path() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "alttabsucks" / "browser-data.json"


class TabSearchState:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.recent: dict = {}      # profile -> [{sessionId, title, url, closedAt}]
        self.bookmarks: dict = {}   # profile -> [{id, title, url}]
        self._last_poll: dict = {}  # profile -> time.monotonic() of its last GET /switchtab
        self._requests: dict = {}   # requestId -> {"event": Event, "items": [...]}
        self._result = None         # None (no popup), "pending" (open), or the popup's choice
        self._closes: dict = {}     # profile -> [tabId] waiting for the extension's next poll
        self._lock = threading.Lock()

    # ---- persisted data ----------------------------------------------------------------------

    def load(self):
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        self.recent = data.get("recent") or {}
        self.bookmarks = data.get("bookmarks") or {}

    def _save(self):
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_name(self.path.name + ".tmp")
            tmp.write_text(json.dumps({"recent": self.recent, "bookmarks": self.bookmarks}), encoding="utf-8")
            tmp.replace(self.path)
        except OSError:
            pass  # best-effort: in memory it's still current

    def set_recent(self, profile: str, items: list):
        with self._lock:
            self.recent[profile] = items
            self._save()

    def set_bookmarks(self, profile: str, items: list):
        with self._lock:
            self.bookmarks[profile] = items
            self._save()

    # ---- liveness ----------------------------------------------------------------------------

    def mark_poll(self, profile: str, now: float = None):
        self._last_poll[profile] = time.monotonic() if now is None else now

    def live_profiles(self, now: float = None) -> set:
        now = time.monotonic() if now is None else now
        return {p for p, t in self._last_poll.items() if now - t < LIVE_SECONDS}

    # ---- bookmarks ---------------------------------------------------------------------------

    def search_bookmarks(self, query: str, switch_queue: dict, live: set,
                         timeout: float = BOOKMARK_SEARCH_TIMEOUT) -> list:
        """Bookmark items for every profile that has bookmarks or is live: asked of the browser
        for live profiles, from the snapshot otherwise (or when the browser doesn't answer in
        time). Not filtered here; tab_search.rank() applies the query to all of them alike."""
        asked = {}
        for profile in live:
            request_id = uuid.uuid4().hex
            with self._lock:
                self._requests[request_id] = {"event": threading.Event(), "items": None}
            switch_queue[profile] = {"searchBookmarks": query, "requestId": request_id}
            asked[profile] = request_id
        deadline = time.monotonic() + timeout
        items = []
        for profile in set(self.bookmarks) | set(live):
            found = None
            if profile in asked:
                req = self._requests[asked[profile]]
                req["event"].wait(max(0.0, deadline - time.monotonic()))
                with self._lock:
                    found = self._requests.pop(asked[profile])["items"]
                if found is None and switch_queue.get(profile, {}) and switch_queue[profile].get("requestId") == asked[profile]:
                    switch_queue[profile] = None  # never picked up; don't leave it for later
            if found is None:
                found = self.bookmarks.get(profile) or []
            items += [dict(b, kind="bookmark", profile=profile, live=profile in live) for b in found]
        return items

    def deliver_bookmark_results(self, request_id: str, items: list) -> bool:
        with self._lock:
            req = self._requests.get(request_id)
            if not req:
                return False
            req["items"] = items
        req["event"].set()
        return True

    # ---- closing tabs ------------------------------------------------------------------------
    # Kept apart from the switch queue: that holds one command per profile, latest wins, so a
    # close queued there was lost to anything queued within the extension's next 50ms poll (a
    # second Ctrl+W, Enter on another result, a live bookmark search).

    def add_close(self, profile: str, tab_id: int):
        with self._lock:
            self._closes.setdefault(profile, []).append(tab_id)

    def take_closes(self, profile: str) -> list:
        with self._lock:
            return self._closes.pop(profile, [])

    # ---- KWin handshake ----------------------------------------------------------------------

    def begin(self):
        with self._lock:
            self._result = "pending"

    def finish(self, result: dict):
        """The popup's choice or cancel; ignored unless a popup is open (begin() was called)."""
        with self._lock:
            if self._result == "pending":
                self._result = result

    def take(self) -> str:
        """For main.js's poll: "" while the popup is open, else the result as JSON (once)."""
        with self._lock:
            if self._result is None or self._result == "pending":
                return ""
            result, self._result = self._result, None
        return json.dumps(result)
