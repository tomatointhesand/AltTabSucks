#!/usr/bin/env python3
"""
AltTabSucks bridge server — Linux port of Server/AltTabSucksServer.ps1.

The HTTP side (this file) is stdlib only, single-threaded (mirrors the PS1's serial
HttpListener loop — this is polled by one browser extension every 50ms, there's no concurrency
to gain and it keeps state access lock-free for that part). Endpoint set, auth model, CORS
policy, and body-size caps are meant to match the PS1 exactly; see CLAUDE.md's "AltTabSucks
Server" section for the endpoint contract consumed by lib/chromium.ahk / lib/firefox.ahk today
and by BrowserExtension/background.js on Linux.

main() additionally starts dbus_bridge (see that module) on its own thread, so the KWin script
can reach the same state via `callDBus` — its scripting sandbox has no XMLHttpRequest. That part
needs dbus-python + PyGObject (system packages, not pip; see _start_dbus_bridge for the install
message). Constructing AppState/make_handler directly (as the tests do) never touches D-Bus.

State lives in an AppState instance rather than module globals, and the handler class is built
per-instance by make_handler(state) — this is what lets tests/test_server.py spin up isolated
server instances (own token, own store) instead of sharing process-wide state, and is also what
dbus_bridge.Bridge shares directly rather than looping back through HTTP.
"""

import json
import secrets
import base64
import sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

PORT = 9876

# Server/token.txt at the repo root — same relative location the Windows server and
# BrowserExtension setup docs already point at, so nothing else about the install needs to change.
REPO_ROOT = Path(__file__).resolve().parents[2]
TOKEN_PATH = REPO_ROOT / "Server" / "token.txt"

TABS_MAX_BODY = 1 * 1024 * 1024   # 1 MB, matches PS1
SMALL_MAX_BODY = 4 * 1024         # 4 KB, matches PS1 (/profiles and /switchtab POST bodies)
DRAIN_CAP = 8 * 1024 * 1024       # hard ceiling for draining a rejected body off the socket


def load_or_create_token(token_path: Path) -> str:
    if token_path.exists():
        return token_path.read_text(encoding="utf-8").strip()
    token_path.parent.mkdir(parents=True, exist_ok=True)
    token = base64.b64encode(secrets.token_bytes(32)).decode("ascii")
    token_path.write_text(token, encoding="utf-8")
    print(f"Generated new auth token: {token}")
    print("Paste this token into the extension Options page.")
    return token


def is_extension_origin(origin: str | None) -> bool:
    return bool(origin) and (origin.startswith("chrome-extension://") or origin.startswith("moz-extension://"))


class AppState:
    """All server-side state, keyed by browser profile display name — same shape as the PS1's
    hashtables. One instance per running server; tests create a fresh one per server they spin up."""

    def __init__(self, secret: str):
        self.secret = secret
        self.store: dict[str, list] = {}         # profile -> windows (list of {id, focused, tabs:[...]})
        self.switch_queue: dict[str, dict] = {}   # profile -> pending switch command, or absent/None
        self.profile_list: list[str] = []         # display names pushed by the hotkey layer at startup


def make_handler(state: AppState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "AltTabSucks/1.0"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass  # PS1 doesn't log per-request either; keep stdout to the token banner only

        # ---- shared plumbing -------------------------------------------------

        def _origin(self) -> str | None:
            return self.headers.get("Origin")

        def _apply_cors(self):
            origin = self._origin()
            if is_extension_origin(origin):
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type, X-AltTabSucks-Token")
                self.send_header("Access-Control-Max-Age", "86400")
                self.send_header("Vary", "Origin")

        def _end(self, status: int, body: bytes = b"", content_type: str | None = None):
            self.send_response(status)
            self._apply_cors()
            if content_type:
                self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _end_json(self, status: int, obj):
            self._end(status, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")

        def _end_text(self, status: int, text: str):
            self._end(status, text.encode("utf-8"), "text/plain; charset=utf-8")

        def _check_auth(self) -> bool:
            # AHK/the KWin script send no Origin header and are unaffected by CORS but must still
            # send the token; OPTIONS preflights are exempt (checked by caller before this runs).
            return self.headers.get("X-AltTabSucks-Token") == state.secret

        def _drain_unread_body(self):
            """Consumes any declared-but-unread request body (bounded by DRAIN_CAP) so a
            keep-alive connection isn't left desynced by whatever's still sitting in the socket
            buffer — otherwise it gets parsed as garbage for the "next request" on this socket.
            Called before every early-return error response that hasn't read the body itself
            (auth failures, oversized bodies). Only skips draining (and force-closes instead)
            when the declared length is missing/malformed or too large to bound the drain by."""
            length = self.headers.get("Content-Length")
            try:
                length = int(length)
            except (TypeError, ValueError):
                length = 0
            if length <= 0:
                return
            if length > DRAIN_CAP:
                self.close_connection = True
                return
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)

        def _read_body(self, max_len: int) -> bytes | None:
            """Returns the body, or None (and already wrote a 413) if it exceeds max_len."""
            length = self.headers.get("Content-Length")
            try:
                length = int(length)
            except (TypeError, ValueError):
                length = -1
            if length < 0 or length > max_len:
                self._drain_unread_body()
                self._end(413)
                return None
            return self.rfile.read(length)

        # ---- dispatch ----------------------------------------------------

        def do_OPTIONS(self):
            self._end(204)

        def do_GET(self):
            if not self._check_auth():
                self._drain_unread_body()
                self._end(403)
                return
            parts = urlsplit(self.path)
            path = parts.path
            qs = parse_qs(parts.query)
            profile = qs.get("profile", [None])[0]

            if path == "/profiles":
                self._end_json(200, state.profile_list)
            elif path == "/tabs":
                self._end_json(200, state.store)
            elif path == "/activetitles":
                windows = state.store.get(profile, [])
                titles = []
                for w in windows:
                    active = next((t for t in w.get("tabs", []) if t.get("active")), None)
                    if active:
                        titles.append(active.get("title", ""))
                self._end_text(200, "\n".join(titles))
            elif path == "/findtab":
                url_pattern = qs.get("url", [None])[0] or ""
                windows = state.store.get(profile, [])
                found = []
                for w in windows:
                    for tab in w.get("tabs", []):
                        if url_pattern in (tab.get("url") or ""):
                            found.append({
                                "line": f"{w.get('id')}|{tab.get('id')}",
                                "micActive": bool(tab.get("micActive")),
                                "audible": bool(tab.get("audible")),
                                "index": int(tab.get("index", 0)),
                            })
                # micActive first, then audible, then leftmost by tab index — matches PS1's sort
                found.sort(key=lambda f: (not f["micActive"], not f["audible"], f["index"]))
                self._end_text(200, "\n".join(f["line"] for f in found))
            elif path == "/switchtab":
                origin = self._origin()
                # Reject simple-request GETs from non-extension origins so a webpage can't drain
                # the queue ahead of the real extension — same guard as the PS1.
                if origin and not is_extension_origin(origin):
                    self._end(204)
                    return
                cmd = state.switch_queue.get(profile)
                if cmd:
                    state.switch_queue[profile] = None
                    self._end_json(200, cmd)
                else:
                    self._end(204)
            elif path == "/debugtabs":
                lines = []
                for prof, windows in state.store.items():
                    lines.append(f"=== {prof} ===")
                    for w in windows:
                        label = f"  Window {w.get('id')}" + (" (focused)" if w.get("focused") else "")
                        lines.append(label)
                        for tab in w.get("tabs", []):
                            flags = ""
                            if tab.get("micActive"):
                                flags += " [MIC]"
                            if tab.get("audible"):
                                flags += " [audible]"
                            if tab.get("active"):
                                flags += " [active]"
                            lines.append(f"    [{tab.get('index')}] {tab.get('title')}{flags}")
                    lines.append("")
                self._end_text(200, "\n".join(lines))
            else:
                self._end(404)

        def do_POST(self):
            if not self._check_auth():
                self._drain_unread_body()
                self._end(403)
                return
            path = urlsplit(self.path).path

            if path == "/profiles":
                body = self._read_body(SMALL_MAX_BODY)
                if body is None:
                    return
                try:
                    parsed = json.loads(body)
                except json.JSONDecodeError:
                    self._end(400)
                    return
                state.profile_list = parsed  # replaces, doesn't accumulate — matches PS1's assignment
                self._end(204)

            elif path == "/tabs":
                body = self._read_body(TABS_MAX_BODY)
                if body is None:
                    return
                try:
                    parsed = json.loads(body)
                except json.JSONDecodeError:
                    self._end(400)
                    return
                state.store[parsed.get("profile")] = parsed.get("windows")
                self._end(204)

            elif path == "/switchtab":
                body = self._read_body(SMALL_MAX_BODY)
                if body is None:
                    return
                try:
                    payload = json.loads(body)
                except json.JSONDecodeError:
                    self._end(400)
                    return
                profile = payload.get("profile")
                if payload.get("splitTab"):
                    state.switch_queue[profile] = {"splitTab": True}
                elif payload.get("mergeTabs"):
                    state.switch_queue[profile] = {"mergeTabs": True}
                elif payload.get("openUrl"):
                    state.switch_queue[profile] = {"openUrl": payload["openUrl"]}
                else:
                    state.switch_queue[profile] = {"windowId": payload.get("windowId"), "tabId": payload.get("tabId")}
                self._end(204)

            else:
                self._drain_unread_body()
                self._end(404)

        def do_DELETE(self):
            if not self._check_auth():
                self._drain_unread_body()
                self._end(403)
                return
            parts = urlsplit(self.path)
            if parts.path == "/tabs":
                profile = parse_qs(parts.query).get("profile", [None])[0]
                state.store.pop(profile, None)
                self._end(204)
            else:
                self._end(404)

    return Handler


def _start_dbus_bridge(state):
    """Imports and starts dbus_bridge, failing with an actionable message rather than a bare
    ImportError/connection traceback if the (system, not pip) dependencies or session bus aren't
    available. Only called from main() — never at module import time — so the HTTP handler logic
    and its test suite stay dependency-free regardless of whether this succeeds."""
    try:
        import dbus
        import dbus_bridge
    except ImportError as e:
        sys.exit(
            "AltTabSucks server: missing the D-Bus bridge's dependencies "
            f"({e}).\nInstall on Arch with: sudo pacman -S python-dbus python-gobject\n"
            "(These aren't pip packages — they wrap the system libdbus/GLib.)"
        )
    try:
        dbus_bridge.start(state)
    except dbus.exceptions.DBusException as e:
        sys.exit(f"AltTabSucks server: couldn't connect to the D-Bus session bus ({e}).")


def main():
    secret = load_or_create_token(TOKEN_PATH)
    state = AppState(secret)
    _start_dbus_bridge(state)
    httpd = HTTPServer(("127.0.0.1", PORT), make_handler(state))
    print(f"AltTabSucks server listening on http://127.0.0.1:{PORT}/ (Ctrl+C to stop)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        print("Server stopped.")


if __name__ == "__main__":
    sys.exit(main())
