#!/usr/bin/env python3
"""
AltTabSucks bridge server — Linux port of Server/AltTabSucksServer.ps1.

The HTTP side (this file) is stdlib only. Originally single-threaded (reasoned in Phase 1 as "one
browser extension polling every 50ms, no concurrency to gain") — that assumption turned out wrong
in production: a real, persistently-running deployment under actual extension traffic showed
sustained concurrent connections (several at once, some plausibly stalled — see the porting
checklist's Phase 1 notes) that a single-threaded server serialized behind whichever connection it
was currently stuck on, wedging every other client including a real browser tab. Now
ThreadingHTTPServer — see AppState.lock for the one place that genuinely needs a lock now that
requests can run concurrently (everything else here is single dict-key get/set, already atomic
under the GIL regardless of threading). Endpoint set, auth model, CORS policy, and body-size caps
are meant to match the PS1 exactly; see CLAUDE.md's "AltTabSucks Server" section for the endpoint
contract consumed by lib/chromium.ahk / lib/firefox.ahk today and by BrowserExtension/background.js
on Linux.

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
import subprocess
import sys
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

PORT = 9876

# Server/token.txt at the repo root — same relative location the Windows server and
# BrowserExtension setup docs already point at, so nothing else about the install needs to change.
REPO_ROOT = Path(__file__).resolve().parents[2]
TOKEN_PATH = REPO_ROOT / "Server" / "token.txt"

TABS_MAX_BODY = 1 * 1024 * 1024   # 1 MB, matches PS1
SMALL_MAX_BODY = 4 * 1024         # 4 KB, matches PS1 (/profiles and /switchtab POST bodies)
HOTKEYS_CONFIG_MAX_BODY = 256 * 1024  # generous room for dozens of bindings
DRAIN_CAP = 8 * 1024 * 1024       # hard ceiling for draining a rejected body off the socket

# hotkeys.json/hotkeys.js live alongside main.js in the KWin script package — see
# hotkeys_generator.py's module docstring for how they relate. hotkeys-ui.html is the shared
# (cross-platform, eventually) static settings page GET /hotkeys-ui serves.
KWIN_CODE_DIR = REPO_ROOT / "linux" / "kwin" / "alttabsucks" / "contents" / "code"
HOTKEYS_CONFIG_PATH = KWIN_CODE_DIR / "hotkeys.json"
HOTKEYS_JS_PATH = KWIN_CODE_DIR / "hotkeys.js"
HOTKEYS_UI_PATH = REPO_ROOT / "shared" / "hotkeys-ui.html"


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
        self.profile_list: list[str] = []         # display names — self-discovered at startup on
                                                    # Linux (see _load_chromium_config); pushed via
                                                    # POST /profiles on Windows (AHK) or Firefox
        self.running_resource_classes: list[str] = []  # distinct resourceClass values currently
                                                    # open, per main.js's periodic PushRunningResourceClasses
                                                    # — feeds hotkeys-ui.html's resourceClass <datalist>.
                                                    # Everything else in this file flows KWin-script-
                                                    # to-server, never the other way (the sandbox has
                                                    # no way to be called *into* on demand) — same
                                                    # push shape as the browser extension's POST /tabs.
        self.chromium_profile_dirs: dict[str, str] = {}  # display name -> profile dir name
        self.chromium_exe: str = ""            # from config.py; e.g. "brave" (see dbus_bridge's
                                                 # LaunchChromiumProfile — not always the same as
                                                 # the resourceClass hotkeys.js matches windows by)
        self.chromium_extra_flags: list[str] = []  # from config.py CHROMIUM_EXTRA_FLAGS
        # Real paths by default (see the module-level constants); overridable per-instance so
        # tests can point these at a tmp dir instead of writing the real hotkeys.js/hotkeys.json
        # on every /hotkeys-config POST test.
        self.hotkeys_config_path: Path = HOTKEYS_CONFIG_PATH
        self.hotkeys_js_path: Path = HOTKEYS_JS_PATH
        # Same overridability reasoning as the two paths above: POST /hotkeys-config runs this
        # after writing hotkeys.js, to actually deploy it — real installer.sh in production,
        # overridden to a harmless stub (["true"]/["false"]) in tests so they exercise the real
        # subprocess.run()-and-report-the-result code path without ever touching the real
        # installer.sh or the real KWin script installation.
        self.deploy_command: list = [str(REPO_ROOT / "installer.sh"), "reload-hotkeys"]
        # Only switch_queue's GET /switchtab dequeue needs this: it's a check-then-clear
        # (read switch_queue[profile], then set it back to None) — the one read-modify-write in
        # this whole file, and now that requests can genuinely run concurrently
        # (ThreadingHTTPServer), two threads racing that same profile's dequeue could both see
        # the queued command and one delivery would be lost, or (less likely) corrupted. Every
        # other dict access anywhere in this file is a single get/set/pop on one key, already
        # atomic under the GIL regardless of threading — doesn't need this lock.
        self.lock = threading.Lock()


def make_handler(state: AppState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "AltTabSucks/1.0"
        protocol_version = "HTTP/1.1"
        # Root-caused a real hang via a live deployment (not just testing): with no timeout set,
        # every blocking read here — the request-line/header read inside parse_request() *and*
        # our own _read_body()/_drain_unread_body() — waits forever if a client stalls mid-request
        # (a malformed/partial send from a persistent keep-alive connection, observed in practice
        # under the extension's rapid, occasionally-duplicated 50ms polling — see the porting
        # checklist). Switching to ThreadingHTTPServer (above) means one stalled connection no
        # longer blocks every *other* client, but it'd still leak a thread forever without this —
        # setting `timeout` makes socketserver.StreamRequestHandler.setup() call
        # socket.settimeout(), and BaseHTTPRequestHandler.handle_one_request() already wraps
        # request handling in a try/except TimeoutError that closes just that one connection — no
        # further server-side change needed beyond turning the timeout on. Kept short (this is a
        # loopback-only server; legitimate requests complete in milliseconds) rather than the more
        # usual generous default, specifically so a burst of several simultaneous stalls — which
        # is what actually happened here, not just one in isolation — can't add up to a long
        # user-visible delay even though each one is individually bounded.
        timeout = 3

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
            try:
                self.send_response(status)
                self._apply_cors()
                if content_type:
                    self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if body:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                # Client vanished mid-response — normal/expected on any TCP server (a
                # disconnected browser tab, a killed curl, etc.), not a real error. Swallowed
                # here rather than propagating into socketserver's default handle_error(), which
                # would otherwise log a full traceback for what's a routine occurrence.
                self.close_connection = True

        def _end_json(self, status: int, obj):
            self._end(status, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")

        def _end_text(self, status: int, text: str):
            self._end(status, text.encode("utf-8"), "text/plain; charset=utf-8")

        def _end_html(self, status: int, html: str):
            self._end(status, html.encode("utf-8"), "text/html; charset=utf-8")

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
            # /hotkeys-ui is a public static page, not an API call — a plain browser navigation
            # can't attach the X-AltTabSucks-Token header the way the page's own fetch() calls to
            # /hotkeys-config do, so it can't be behind the same auth check. Nothing sensitive
            # lives in the page itself (no token baked in); the token is entered by hand in the
            # UI and used only for its own subsequent /hotkeys-config calls, same pattern as
            # BrowserExtension/options.js.
            if urlsplit(self.path).path == "/hotkeys-ui":
                try:
                    html = HOTKEYS_UI_PATH.read_text(encoding="utf-8")
                except OSError:
                    self._end(404)
                    return
                self._end_html(200, html)
                return

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
            elif path == "/running-resource-classes":
                self._end_json(200, state.running_resource_classes)
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
                with state.lock:
                    cmd = state.switch_queue.get(profile)
                    if cmd:
                        state.switch_queue[profile] = None
                if cmd:
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
            elif path == "/hotkeys-config":
                try:
                    config = json.loads(state.hotkeys_config_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    config = {"bindings": []}
                self._end_json(200, config)
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

            elif path == "/hotkeys-config":
                body = self._read_body(HOTKEYS_CONFIG_MAX_BODY)
                if body is None:
                    return
                try:
                    config = json.loads(body)
                except json.JSONDecodeError:
                    self._end_json(400, {"error": "invalid JSON"})
                    return
                import hotkeys_generator
                try:
                    js = hotkeys_generator.generate_hotkeys_js(config)
                except ValueError as e:
                    # A bad binding (missing field, unknown type) — the UI should have caught
                    # this client-side already, but never trust that alone; report it back
                    # rather than writing a hotkeys.js that would fail to parse in KWin, where
                    # errors are far harder to see (see the porting checklist's notes on how
                    # silent a KWin script parse failure is).
                    self._end_json(400, {"error": str(e)})
                    return
                state.hotkeys_config_path.parent.mkdir(parents=True, exist_ok=True)
                state.hotkeys_config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
                state.hotkeys_js_path.write_text(js, encoding="utf-8")

                # Deploy immediately rather than making Save a two-step "save, then separately
                # remember to press Ctrl+Alt+Shift+' or run installer.sh" — same command that
                # hotkey itself runs (installer.sh reload-hotkeys), just triggered from here
                # instead of from a runCommand binding. Synchronous: ThreadingHTTPServer means a
                # few hundred ms of kpackagetool6 work blocks only this one request's thread, and
                # the whole point is telling the UI whether the deploy actually succeeded rather
                # than firing it detached and hoping.
                deployed = False
                deploy_error = None
                try:
                    result = subprocess.run(
                        state.deploy_command, capture_output=True, text=True, timeout=15,
                    )
                    deployed = result.returncode == 0
                    if not deployed:
                        deploy_error = (result.stderr or result.stdout or f"exit code {result.returncode}").strip()
                except (OSError, subprocess.TimeoutExpired) as e:
                    deploy_error = str(e)

                if deployed:
                    note = "Deployed to the running KWin script."
                elif deploy_error:
                    note = f"Saved, but deploy failed ({deploy_error}) — press Ctrl+Alt+Shift+' or run ./installer.sh reload-hotkeys by hand."
                else:
                    note = "Saved — press Ctrl+Alt+Shift+' or run ./installer.sh reload-hotkeys to deploy."

                self._end_json(200, {
                    "ok": True,
                    "bindingCount": len(config.get("bindings", [])),
                    "deployed": deployed,
                    "note": note,
                })

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


def _load_chromium_config(state):
    """Populates state.profile_list/chromium_profile_dirs (via profile_discovery.py) and
    state.chromium_exe/chromium_extra_flags, all from linux/server/config.py, if that (gitignored,
    optional) file exists — see profile_discovery.py's docstring for why profile discovery
    happens server-side on Linux instead of being pushed by a hotkey-layer process the way AHK's
    _InitChromiumState does on Windows. Missing config.py (not yet copied from
    config.template.py) just means empty state, same as a fresh Windows install before
    app-hotkeys.ahk/config.ahk exist — not a fatal error, so main() doesn't guard this."""
    try:
        import config
    except ImportError:
        return
    import profile_discovery
    profiles = profile_discovery.discover_chromium_profiles(getattr(config, "CHROMIUM_USERDATA", ""))
    state.chromium_profile_dirs = profiles
    state.profile_list = list(profiles.keys())
    state.chromium_exe = getattr(config, "CHROMIUM_EXE", "")
    state.chromium_extra_flags = getattr(config, "CHROMIUM_EXTRA_FLAGS", [])


def main():
    secret = load_or_create_token(TOKEN_PATH)
    state = AppState(secret)
    _load_chromium_config(state)
    _start_dbus_bridge(state)
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), make_handler(state))
    # Without this, server_close() joins every live worker thread before returning — so a single
    # stuck connection (the exact scenario this file's Handler.timeout comment describes) would
    # delay shutdown (systemctl stop, Ctrl+C) by however long that thread takes to time out, one
    # more place the same underlying problem could still bite even with threading in place.
    httpd.daemon_threads = True
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
