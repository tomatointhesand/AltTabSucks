#!/usr/bin/env python3
"""
Ranking for the tab search popup (Ctrl+Alt+Shift+A by default): given what the browser extensions
have reported, which results to show for a query. Pure functions, no I/O — alttabsucks_server.py's
GET /tab-search gathers the data and calls search().

Sections, like the Quick Tabs extension this is modeled on: open tabs and recently closed tabs
always show together; bookmarks are added as a third section only when those two have fewer
than BOOKMARKS_BELOW results between them, or when the query starts or ends with a space. Two
spaces search bookmarks only. An empty query lists open tabs and recently closed tabs.

Within a section every query word has to appear in the title or the URL (any order,
case-insensitive); results with more words in the title rank first, then the most recently
used / closed. The tab you're on is left out: it's never somewhere to go.

Item shapes (dicts), as returned to the popup and posted back to POST /tab-search/action:
  {"kind": "tab", "profile", "windowId", "tabId", "title", "url", "lastUsed"}
  {"kind": "recent", "profile", "sessionId", "title", "url", "closedAt", "live"}
  {"kind": "bookmark", "profile", "id", "title", "url", "live"}
"live": whether that profile's browser is running right now (its extension is checking in), which
decides between restoring/opening in the running browser and launching it first.
"""

from urllib.parse import urlsplit

DEFAULT_LIMIT = 50


def icon_key(url: str):
    """Which favicon a URL shows: its host plus first path segment ("docs.google.com/document"),
    so sites that serve different apps under one host still get different icons. None for
    non-web URLs. Shared by search results (iconKey) and favicon uploads (see favicon_store.py)."""
    try:
        parts = urlsplit(url or "")
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    host = parts.hostname + (f":{parts.port}" if parts.port else "")
    seg = parts.path.lstrip("/").split("/", 1)[0]
    return host + ("/" + seg if seg else "")


def query_words(query: str) -> list:
    return [w for w in (query or "").lower().split() if w]


def _title_hits(item: dict, words: list):
    """How many query words are in the title, or None if some word is in neither title nor URL."""
    title = (item.get("title") or "").lower()
    url = (item.get("url") or "").lower()
    hits = 0
    for w in words:
        if w in title:
            hits += 1
        elif w not in url:
            return None
    return hits


def rank(items: list, words: list, recency_key: str = "", limit: int = DEFAULT_LIMIT) -> list:
    """Matching items, best first. Stable for ties, so callers can pre-order."""
    scored = []
    for i, item in enumerate(items):
        hits = _title_hits(item, words)
        if hits is None:
            continue
        recency = item.get(recency_key) or 0 if recency_key else 0
        scored.append((-hits, -recency, i, item))
    scored.sort(key=lambda s: s[:3])
    return [s[3] for s in scored[:limit]]


def open_tab_items(tabs_by_profile: dict, live_profiles: set, current_caption=None) -> list:
    """Flattens the extension's POST /tabs data ({profile: [window, ...]}) into tab items, most
    recently used first, for live profiles only: a closed browser's last tab list stays on the
    server, but those tabs are gone.

    Leaves out the tab you're on. current_caption is the title of the window that was in front
    when the popup was opened (from KWin, see BeginTabSearch): an active tab whose title is in it
    is the one you're on, and if the window in front isn't a browser nothing matches. Without it
    (None), the active tab of a focused browser window is used instead."""
    items = []
    for profile, windows in tabs_by_profile.items():
        if profile not in live_profiles:
            continue
        for w in windows or []:
            for t in w.get("tabs") or []:
                title = t.get("title") or ""
                if t.get("active") and (
                        (title and title in current_caption) if current_caption is not None else w.get("focused")):
                    continue
                items.append({
                    "kind": "tab", "profile": profile, "windowId": w.get("id"), "tabId": t.get("id"),
                    "title": title, "url": t.get("fullUrl") or t.get("url") or "",
                    # lastUsed: only counted once a tab stays active for 1.5s (see the extension)
                    "lastUsed": t.get("lastUsed") or t.get("lastAccessed") or 0,
                })
    items.sort(key=lambda t: -t["lastUsed"])
    return items


BOOKMARKS_BELOW = 5  # bookmarks join when open + recently closed tabs have fewer results than this


def search(query: str, tabs_by_profile: dict, recent_by_profile: dict, live_profiles: set,
           search_bookmarks, limit: int = DEFAULT_LIMIT, current_caption=None) -> dict:
    """{"sections": [{"category": "tabs" | "recent" | "bookmarks", "items": [...]}, ...],
    "showProfile": bool}. Only sections with results are listed, in that order.

    search_bookmarks(words) -> bookmark items (already tagged with profile/live); only called when
    bookmarks are wanted (see the module docstring), since it may have to ask the browser."""
    words = query_words(query)
    tabs = open_tab_items(tabs_by_profile, live_profiles, current_caption)
    recent = []
    for profile, items in recent_by_profile.items():
        for r in items or []:
            recent.append(dict(r, kind="recent", profile=profile, live=profile in live_profiles))

    if words and (query.startswith("  ") or query.endswith("  ")):
        found_tabs, found_recent, want_bookmarks = [], [], True  # two spaces: bookmarks only
    else:
        found_tabs = rank(tabs, words, limit=limit)  # already most recently used first
        found_recent = rank(recent, words, recency_key="closedAt", limit=limit)
        want_bookmarks = bool(words) and (
            query.startswith(" ") or query.endswith(" ") or len(found_tabs) + len(found_recent) < BOOKMARKS_BELOW)
    found_bookmarks = rank(search_bookmarks(words), words, limit=limit) if want_bookmarks else []

    sections = [{"category": c, "items": [dict(i, iconKey=icon_key(i.get("url"))) for i in found]}
                for c, found in (("tabs", found_tabs), ("recent", found_recent), ("bookmarks", found_bookmarks))
                if found]
    # Profile labels only when more than one profile has tabs open.
    return {"sections": sections, "showProfile": len({t["profile"] for t in tabs}) > 1}
