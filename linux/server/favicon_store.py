#!/usr/bin/env python3
"""
Favicons for the tab search popup, one per tab_search.icon_key (host + first path segment).

The extension gets them from the browser's own favicon cache (the `_favicon` endpoint, which
also covers bookmarks and recently closed tabs, unlike a tab's favIconUrl), asks which ones the
server is missing (POST /favicons/missing), and uploads only those (POST /favicons). They're
kept on disk under $XDG_STATE_HOME/alttabsucks/favicons/, so they survive restarts and a
closed browser. The popup fetches each one once (GET /favicon?key=) and caches it itself.
"""

import base64
import hashlib
import threading
from pathlib import Path

MAX_ICON_BYTES = 64 * 1024
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class FaviconStore:
    def __init__(self, directory: Path):
        self.dir = Path(directory)
        self._known = None  # set of file stems, read lazily from disk
        self._lock = threading.Lock()

    @staticmethod
    def _stem(key: str) -> str:
        return hashlib.sha1(key.encode("utf-8")).hexdigest()

    def _known_stems(self) -> set:
        if self._known is None:
            try:
                self._known = {p.stem for p in self.dir.glob("*.png")}
            except OSError:
                self._known = set()
        return self._known

    def missing(self, keys) -> list:
        with self._lock:
            known = self._known_stems()
            return [k for k in dict.fromkeys(keys) if k and self._stem(k) not in known]

    def put(self, key: str, png: bytes) -> bool:
        """Stores a PNG for key. False (and nothing stored) for anything that isn't a small PNG."""
        if not key or len(png) > MAX_ICON_BYTES or not png.startswith(PNG_MAGIC):
            return False
        stem = self._stem(key)
        with self._lock:
            try:
                self.dir.mkdir(parents=True, exist_ok=True)
                tmp = self.dir / (stem + ".tmp")
                tmp.write_bytes(png)
                tmp.replace(self.dir / (stem + ".png"))
            except OSError:
                return False
            self._known_stems().add(stem)
        return True

    def put_base64(self, key: str, data: str) -> bool:
        try:
            return self.put(key, base64.b64decode(data, validate=True))
        except (ValueError, TypeError):
            return False

    def get(self, key: str):
        """The PNG bytes for key, or None."""
        if not key:
            return None
        try:
            return (self.dir / (self._stem(key) + ".png")).read_bytes()
        except OSError:
            return None
