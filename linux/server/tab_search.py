#!/usr/bin/env python3
"""
Ranking for the tab search popup (Ctrl+Alt+Shift+A by default): given what the browser extensions
have reported, which results to show for a query. Pure functions, no I/O — alttabsucks_server.py's
GET /tab-search gathers the data and calls search().

Categories are exclusive and tried in order: open tabs; only if none match, recently closed tabs;
only if none of those match either, bookmarks. Within a category every query word has to appear
in the title or the URL (any order, case-insensitive); results with more words in the title rank
first, then the most recently used / closed.

Item shapes (dicts), as returned to the popup and posted back to POST /tab-search/action:
  {"kind": "tab", "profile", "windowId", "tabId", "title", "url", "lastAccessed"}
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


def _with_icons(result: dict) -> dict:
    result["items"] = [dict(i, iconKey=icon_key(i.get("url"))) for i in result["items"]]
    return result


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


def open_tab_items(tabs_by_profile: dict, live_profiles: set) -> list:
    """Flattens the extension's POST /tabs data ({profile: [window, ...]}) into tab items, for live
    profiles only: a closed browser's last tab list stays on the server, but those tabs are gone.

    The tab you're already looking at (the active tab of a focused browser window) is moved to
    the end, so the top result, which is selected by default, is somewhere to go."""
    items, current = [], []
    for profile, windows in tabs_by_profile.items():
        if profile not in live_profiles:
            continue
        for w in windows or []:
            for t in w.get("tabs") or []:
                item = {
                    "kind": "tab", "profile": profile, "windowId": w.get("id"), "tabId": t.get("id"),
                    "title": t.get("title") or "", "url": t.get("fullUrl") or t.get("url") or "",
                    "lastAccessed": t.get("lastAccessed") or 0,
                }
                (current if w.get("focused") and t.get("active") else items).append(item)
    items.sort(key=lambda t: -t["lastAccessed"])
    return items + current


def search(query: str, tabs_by_profile: dict, recent_by_profile: dict, live_profiles: set,
           search_bookmarks, limit: int = DEFAULT_LIMIT) -> dict:
    """{"category": "tabs" | "recent" | "bookmarks" | "", "showProfile": bool, "items": [...]}.

    search_bookmarks(words) -> bookmark items (already tagged with profile/live); only called when
    neither open nor recently closed tabs match, since it may have to ask the browser."""
    words = query_words(query)
    tabs = open_tab_items(tabs_by_profile, live_profiles)
    # Profile labels only matter when results could come from more than one browser profile.
    show_profile = len({t["profile"] for t in tabs}) > 1

    found = rank(tabs, words, limit=limit)  # open_tab_items already put them in MRU order
    if found:
        return _with_icons({"category": "tabs", "showProfile": show_profile, "items": found})

    recent = []
    for profile, items in recent_by_profile.items():
        for r in items or []:
            recent.append(dict(r, kind="recent", profile=profile, live=profile in live_profiles))
    found = rank(recent, words, recency_key="closedAt", limit=limit)
    if found:
        return _with_icons({"category": "recent", "showProfile": len({r["profile"] for r in recent}) > 1, "items": found})

    bookmarks = search_bookmarks(words)
    found = rank(bookmarks, words, limit=limit)
    if found:
        return _with_icons({"category": "bookmarks", "showProfile": len({b["profile"] for b in bookmarks}) > 1, "items": found})
    return {"category": "", "showProfile": False, "items": []}
