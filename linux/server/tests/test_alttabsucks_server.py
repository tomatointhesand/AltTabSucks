#!/usr/bin/env python3
"""
Tests for linux/server/alttabsucks_server.py.

Stdlib-only (unittest + http.client), matching the server's own no-dependencies philosophy.
Each test spins up a real ThreadingHTTPServer (matching production — see alttabsucks_server.py's
module docstring for why it's threading now, not the plain HTTPServer it started as) on an
ephemeral port with a fresh AppState, so tests don't share state or fight over port 9876 with a
real running instance.

Run with:  python3 -m unittest discover -s linux/server/tests
"""

import json
import socket
import sys
import tempfile
import threading
import time
import unittest
import http.client
from pathlib import Path
from http.server import ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from alttabsucks_server import AppState, make_handler, load_or_create_token  # noqa: E402

TOKEN = "test-token"
EXT_ORIGIN = "chrome-extension://testextensionid"
PAGE_ORIGIN = "https://evil.example.com"


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.state = AppState(TOKEN)
        # Never let a test write the real repo's hotkeys.json/hotkeys.js — see
        # AppState.hotkeys_config_path/hotkeys_js_path's docstring for why these are
        # per-instance overridable rather than bare module constants.
        self._hotkeys_tmpdir = tempfile.TemporaryDirectory()
        self.state.hotkeys_config_path = Path(self._hotkeys_tmpdir.name) / "hotkeys.json"
        self.state.hotkeys_js_path = Path(self._hotkeys_tmpdir.name) / "hotkeys.js"
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.state))
        self.httpd.daemon_threads = True  # don't let tearDown block on a stuck test connection
        self.port = self.httpd.server_address[1]
        # poll_interval default (0.5s) makes shutdown() in tearDown cost 0.5s per test with
        # ThreadingHTTPServer (confirmed empirically — HTTPServer's shutdown() didn't have this
        # cost, only Threading's does) — 0.05s keeps ~60 tests fast without changing anything
        # about production behavior, which doesn't care how quickly shutdown() returns.
        self.thread = threading.Thread(target=lambda: self.httpd.serve_forever(poll_interval=0.05), daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)
        self._hotkeys_tmpdir.cleanup()

    def request(self, method, path, json_body=None, raw_body=None, token=TOKEN, origin=None, extra_headers=None):
        """Returns (status, headers_dict, raw_bytes). Sends the token header unless token=None;
        sends a JSON body if json_body is given, or raw_body verbatim (bytes/str) otherwise."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = dict(extra_headers or {})
        if token is not None:
            headers["X-AltTabSucks-Token"] = token
        if origin is not None:
            headers["Origin"] = origin
        data = None
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif raw_body is not None:
            data = raw_body.encode("utf-8") if isinstance(raw_body, str) else raw_body
        try:
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            raw = resp.read()
            return resp.status, dict(resp.getheaders()), raw
        finally:
            conn.close()

    # ---- auth ----------------------------------------------------------

    def test_missing_token_rejected(self):
        status, _, _ = self.request("GET", "/tabs", token=None)
        self.assertEqual(status, 403)

    def test_wrong_token_rejected(self):
        status, _, _ = self.request("GET", "/tabs", token="not-the-token")
        self.assertEqual(status, 403)

    def test_auth_enforced_on_post_and_delete_too(self):
        status, _, _ = self.request("POST", "/tabs", token=None, json_body={"profile": "x", "windows": []})
        self.assertEqual(status, 403)
        status, _, _ = self.request("DELETE", "/tabs?profile=x", token=None)
        self.assertEqual(status, 403)

    def test_unauthenticated_post_with_body_does_not_desync_the_connection(self):
        """A 403 for an unauthenticated POST must drain the (unread, since auth is checked
        before routing) body too — same keep-alive desync risk as the oversized-body case."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/tabs", body=json.dumps({"profile": "x", "windows": []}).encode("utf-8"),
                     headers={"Content-Type": "application/json"})  # no token header
        resp = conn.getresponse()
        self.assertEqual(resp.status, 403)
        resp.read()
        conn.request("GET", "/tabs", headers={"X-AltTabSucks-Token": TOKEN})
        resp2 = conn.getresponse()
        self.assertEqual(resp2.status, 200)
        conn.close()

    def test_options_preflight_bypasses_auth(self):
        status, _, _ = self.request("OPTIONS", "/tabs", token=None, origin=EXT_ORIGIN)
        self.assertEqual(status, 204)

    # ---- CORS ------------------------------------------------------------

    def test_cors_headers_present_for_extension_origin(self):
        status, headers, _ = self.request("OPTIONS", "/tabs", token=None, origin=EXT_ORIGIN)
        self.assertEqual(status, 204)
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), EXT_ORIGIN)
        self.assertIn("X-AltTabSucks-Token", headers.get("Access-Control-Allow-Headers", ""))

    def test_cors_headers_absent_for_page_origin(self):
        status, headers, _ = self.request("GET", "/tabs", origin=PAGE_ORIGIN)
        self.assertEqual(status, 200)  # request still succeeds (correct token) — just no CORS grant
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    # ---- /profiles ---------------------------------------------------

    def test_profiles_post_replaces_rather_than_accumulates(self):
        self.request("POST", "/profiles", json_body=["Default"])
        self.request("POST", "/profiles", json_body=["Default", "Work"])
        status, _, body = self.request("GET", "/profiles")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), ["Default", "Work"])  # not duplicated across the two POSTs

    def test_profiles_oversized_body_rejected(self):
        big = json.dumps(["x"] * 2000)  # > 4KB cap
        status, _, _ = self.request("POST", "/profiles", raw_body=big,
                                     extra_headers={"Content-Type": "application/json"})
        self.assertEqual(status, 413)

    def test_oversized_body_drains_without_desyncing_the_connection(self):
        """A 413 must not leave a keep-alive connection's stream desynced by an unread body —
        the extension polls /switchtab every 50ms and plausibly reuses connections. Prove the
        connection is still usable for a normal request afterwards, on the same socket."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        big = json.dumps(["x"] * 2000)  # > 4KB cap, well under DRAIN_CAP
        conn.request("POST", "/profiles", body=big.encode("utf-8"),
                     headers={"X-AltTabSucks-Token": TOKEN, "Content-Type": "application/json"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 413)
        resp.read()
        # same connection, next request — must be parsed cleanly, not as leftover body garbage
        conn.request("GET", "/tabs", headers={"X-AltTabSucks-Token": TOKEN})
        resp2 = conn.getresponse()
        self.assertEqual(resp2.status, 200)
        self.assertEqual(json.loads(resp2.read()), {})
        conn.close()

    def test_profiles_invalid_json_rejected(self):
        status, _, _ = self.request("POST", "/profiles", raw_body="not json",
                                     extra_headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400)

    # ---- /tabs -------------------------------------------------------

    def _seed_default_profile(self):
        windows = [{
            "id": 1, "focused": True,
            "tabs": [
                {"id": 11, "index": 0, "title": "Gmail", "url": "https://mail.google.com/mail",
                 "active": True, "audible": False, "micActive": False},
                {"id": 12, "index": 1, "title": "Meet call", "url": "https://meet.google.com/xyz",
                 "active": False, "audible": False, "micActive": True},
                {"id": 13, "index": 2, "title": "Music", "url": "https://music.google.com/y",
                 "active": False, "audible": True, "micActive": False},
            ],
        }]
        status, _, _ = self.request("POST", "/tabs", json_body={"profile": "Default", "windows": windows})
        self.assertEqual(status, 204)
        return windows

    def test_tabs_post_get_roundtrip(self):
        windows = self._seed_default_profile()
        status, _, body = self.request("GET", "/tabs")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"Default": windows})

    def test_tabs_oversized_body_rejected(self):
        big = json.dumps({"profile": "x", "windows": ["y"] * 400000})  # > 1MB cap
        status, _, _ = self.request("POST", "/tabs", raw_body=big,
                                     extra_headers={"Content-Type": "application/json"})
        self.assertEqual(status, 413)

    def test_tabs_delete_removes_profile(self):
        self._seed_default_profile()
        status, _, _ = self.request("DELETE", "/tabs?profile=Default")
        self.assertEqual(status, 204)
        status, _, body = self.request("GET", "/tabs")
        self.assertEqual(json.loads(body), {})

    def test_tabs_delete_unknown_profile_is_a_noop_204(self):
        status, _, _ = self.request("DELETE", "/tabs?profile=NoSuchProfile")
        self.assertEqual(status, 204)

    # ---- /activetitles -------------------------------------------------

    def test_activetitles_returns_only_active_tab_per_window(self):
        self._seed_default_profile()
        status, _, body = self.request("GET", "/activetitles?profile=Default")
        self.assertEqual(status, 200)
        self.assertEqual(body.decode("utf-8"), "Gmail")

    def test_activetitles_unknown_profile_is_empty(self):
        status, _, body = self.request("GET", "/activetitles?profile=Nope")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")

    # ---- /findtab ------------------------------------------------------

    def test_findtab_substring_match(self):
        self._seed_default_profile()
        status, _, body = self.request("GET", "/findtab?profile=Default&url=google.com")
        self.assertEqual(status, 200)
        lines = body.decode("utf-8").split("\n")
        self.assertEqual(set(lines), {"1|11", "1|12", "1|13"})

    def test_findtab_sort_order_mic_then_audible_then_index(self):
        self._seed_default_profile()
        status, _, body = self.request("GET", "/findtab?profile=Default&url=google.com")
        lines = body.decode("utf-8").split("\n")
        # tab 12 has micActive, tab 13 has audible, tab 11 has neither -> 12, 13, 11
        self.assertEqual(lines, ["1|12", "1|13", "1|11"])

    def test_findtab_no_match_is_empty(self):
        self._seed_default_profile()
        status, _, body = self.request("GET", "/findtab?profile=Default&url=nowhere.example")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")

    # ---- /switchtab ------------------------------------------------------

    def test_switchtab_windowid_tabid_variant(self):
        self.request("POST", "/switchtab", json_body={"profile": "Default", "windowId": 1, "tabId": 12})
        status, _, body = self.request("GET", "/switchtab?profile=Default", origin=EXT_ORIGIN)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"windowId": 1, "tabId": 12})

    def test_switchtab_split_merge_openurl_variants(self):
        for payload, expected in [
            ({"profile": "Default", "splitTab": True}, {"splitTab": True}),
            ({"profile": "Default", "mergeTabs": True}, {"mergeTabs": True}),
            ({"profile": "Default", "openUrl": "https://x.example"}, {"openUrl": "https://x.example"}),
        ]:
            self.request("POST", "/switchtab", json_body=payload)
            status, _, body = self.request("GET", "/switchtab?profile=Default", origin=EXT_ORIGIN)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), expected)

    def test_switchtab_get_drains_queue_exactly_once(self):
        self.request("POST", "/switchtab", json_body={"profile": "Default", "windowId": 1, "tabId": 1})
        status1, _, _ = self.request("GET", "/switchtab?profile=Default", origin=EXT_ORIGIN)
        status2, _, body2 = self.request("GET", "/switchtab?profile=Default", origin=EXT_ORIGIN)
        self.assertEqual(status1, 200)
        self.assertEqual(status2, 204)
        self.assertEqual(body2, b"")

    def test_switchtab_get_empty_queue_204(self):
        status, _, body = self.request("GET", "/switchtab?profile=NeverQueued", origin=EXT_ORIGIN)
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")

    def test_switchtab_get_rejects_page_origin_without_draining(self):
        """A webpage GETing /switchtab with a real (non-extension) Origin must not be able to
        drain a command meant for the extension — this is the queue-drain-attack guard."""
        self.request("POST", "/switchtab", json_body={"profile": "Default", "windowId": 1, "tabId": 1})
        status, _, _ = self.request("GET", "/switchtab?profile=Default", origin=PAGE_ORIGIN)
        self.assertEqual(status, 204)  # rejected, not the queued command
        # command must still be there for the real extension
        status2, _, body2 = self.request("GET", "/switchtab?profile=Default", origin=EXT_ORIGIN)
        self.assertEqual(status2, 200)
        self.assertEqual(json.loads(body2), {"windowId": 1, "tabId": 1})

    def test_switchtab_get_with_no_origin_header_still_drains(self):
        """AHK's WinHttp / the future KWin script send no Origin header at all — must not be
        treated as a page-origin GET and blocked."""
        self.request("POST", "/switchtab", json_body={"profile": "Default", "windowId": 1, "tabId": 1})
        status, _, body = self.request("GET", "/switchtab?profile=Default", origin=None)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"windowId": 1, "tabId": 1})

    # ---- /debugtabs ------------------------------------------------------

    def test_debugtabs_formatting(self):
        self._seed_default_profile()
        status, _, body = self.request("GET", "/debugtabs")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        self.assertIn("=== Default ===", text)
        self.assertIn("Window 1 (focused)", text)
        self.assertIn("[0] Gmail [active]", text)
        self.assertIn("[1] Meet call [MIC]", text)
        self.assertIn("[2] Music [audible]", text)

    # ---- misc ----------------------------------------------------------

    def test_unknown_path_404(self):
        status, _, _ = self.request("GET", "/nope")
        self.assertEqual(status, 404)

    # ---- /hotkeys-config -------------------------------------------------

    def test_hotkeys_config_get_defaults_to_empty_bindings_when_no_file_yet(self):
        status, _, body = self.request("GET", "/hotkeys-config")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"bindings": []})

    def test_hotkeys_config_post_writes_config_and_generates_js(self):
        config = {"bindings": [
            {"type": "windowToggle", "title": "Toggle File Manager", "key": "Ctrl+Alt+Shift+E",
             "resourceClass": "org.kde.dolphin", "launchArgv": ["dolphin"]},
        ]}
        status, _, body = self.request("POST", "/hotkeys-config", json_body=config)
        self.assertEqual(status, 200)
        result = json.loads(body)
        self.assertTrue(result["ok"])
        self.assertEqual(result["bindingCount"], 1)

        self.assertEqual(json.loads(self.state.hotkeys_config_path.read_text()), config)
        js = self.state.hotkeys_js_path.read_text()
        self.assertIn('manageAppWindows("org.kde.dolphin", "toggle", ["dolphin"]);', js)

    def test_hotkeys_config_get_after_post_returns_what_was_saved(self):
        config = {"bindings": [
            {"type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P",
             "resourceClass": "brave-browser", "profileName": "Work"},
        ]}
        self.request("POST", "/hotkeys-config", json_body=config)
        status, _, body = self.request("GET", "/hotkeys-config")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), config)

    def test_hotkeys_config_post_invalid_binding_rejected_without_writing_anything(self):
        config = {"bindings": [{"type": "tabFocus", "title": "Broken"}]}  # missing required fields
        status, _, body = self.request("POST", "/hotkeys-config", json_body=config)
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(body))
        self.assertFalse(self.state.hotkeys_config_path.exists())
        self.assertFalse(self.state.hotkeys_js_path.exists())

    def test_hotkeys_config_post_invalid_json_rejected(self):
        status, _, body = self.request("POST", "/hotkeys-config", raw_body="not json",
                                        extra_headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(body))

    def test_hotkeys_config_requires_auth(self):
        status, _, _ = self.request("GET", "/hotkeys-config", token=None)
        self.assertEqual(status, 403)
        status, _, _ = self.request("POST", "/hotkeys-config", token=None, json_body={"bindings": []})
        self.assertEqual(status, 403)

    # ---- /hotkeys-ui -------------------------------------------------------

    def test_hotkeys_ui_served_without_auth(self):
        status, headers, body = self.request("GET", "/hotkeys-ui", token=None)
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers.get("Content-Type", ""))
        self.assertIn(b"<", body)  # something HTML-shaped came back, not an empty/error page

    # ---- timeout / hang recovery -----------------------------------------------------------

    def test_stalled_client_does_not_wedge_the_server_for_other_clients(self):
        """Regression test for a real production hang: a client that opens a connection,
        declares a Content-Length via headers, and then never sends the body. Originally found
        when this server was still single-threaded (no socket timeout configured at the time
        either, making it worse) — a real, persistently-running deployment under real extension
        traffic wedged completely, every client blocked forever behind whichever connection it
        was stuck on, including a real browser tab. Now ThreadingHTTPServer, so this proves a
        much stronger guarantee than "eventually, within the timeout": a concurrent client must
        be served *fast*, not just before some generous ceiling — timing-based but with a wide
        enough margin (comparing against the stall's own multi-second timeout) not to be flaky."""
        handler_cls = make_handler(self.state)
        handler_cls.timeout = 5  # only the stalled connection should ever wait this long
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
        httpd.daemon_threads = True  # don't let this test's own cleanup wait out the stall
        port = httpd.server_address[1]
        thread = threading.Thread(target=lambda: httpd.serve_forever(poll_interval=0.05), daemon=True)
        thread.start()
        try:
            stalled = socket.create_connection(("127.0.0.1", port), timeout=10)
            stalled.sendall(
                f"POST /tabs HTTP/1.1\r\nHost: x\r\nX-AltTabSucks-Token: {TOKEN}\r\n"
                "Content-Type: application/json\r\nContent-Length: 100\r\n\r\n".encode()
            )
            # Deliberately never send the promised 100-byte body.

            # A second, independent client must be served concurrently — fast, not just
            # eventually — proving the stall above doesn't block other clients at all, not
            # merely that it stops blocking them once its own timeout expires.
            start = time.monotonic()
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.request("GET", "/tabs", headers={"X-AltTabSucks-Token": TOKEN})
            resp = conn.getresponse()
            elapsed = time.monotonic() - start
            self.assertEqual(resp.status, 200)
            self.assertLess(elapsed, 2, "a concurrent client should be served in well under the stalled connection's own timeout")
            conn.close()
        finally:
            stalled.close()
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=2)


class TokenFileTestCase(unittest.TestCase):
    def test_generates_and_persists_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            token_path = Path(tmp) / "Server" / "token.txt"
            self.assertFalse(token_path.exists())
            first = load_or_create_token(token_path)
            self.assertTrue(token_path.exists())
            self.assertEqual(token_path.read_text(encoding="utf-8").strip(), first)

    def test_reuses_existing_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            token_path = Path(tmp) / "Server" / "token.txt"
            first = load_or_create_token(token_path)
            second = load_or_create_token(token_path)
            self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
