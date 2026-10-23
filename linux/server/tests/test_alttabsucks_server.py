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

import base64
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
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from alttabsucks_server import AppState, make_handler, load_or_create_token  # noqa: E402
import launch_command_suggester  # noqa: E402

TOKEN = "test-token"
EXT_ORIGIN = "chrome-extension://testextensionid"
PAGE_ORIGIN = "https://evil.example.com"


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.state = AppState(TOKEN)
        # Never let a test write the real repo's hotkeys.js/hotkeys.json — see
        # AppState.legacy_hotkeys_json_path/hotkeys_js_path's comment for why these are
        # per-instance overridable rather than bare module constants.
        self._hotkeys_tmpdir = tempfile.TemporaryDirectory()
        self.state.legacy_hotkeys_json_path = Path(self._hotkeys_tmpdir.name) / "hotkeys.json"
        self.state.hotkeys_js_path = Path(self._hotkeys_tmpdir.name) / "hotkeys.js"
        self.state.tab_search.path = Path(self._hotkeys_tmpdir.name) / "browser-data.json"
        self.state.favicons.dir = Path(self._hotkeys_tmpdir.name) / "favicons"
        # Never let a test invoke the real installer.sh (which would touch the real KWin script
        # installation) — see AppState.deploy_command's docstring. "true" is a real subprocess
        # (exit 0, no output) so POST /hotkeys-config's subprocess.run()-and-report-the-result
        # code path is still genuinely exercised, just against a harmless command.
        self.state.deploy_command = ["true"]
        # The single configured browser's window resourceClass (config.py's
        # CHROMIUM_RESOURCE_CLASS) — see hotkeys_generator's module docstring. Defaulted here so
        # every existing profileCycle/tabFocus/splitTab/mergeTabs test binding below (written
        # before that field moved off the binding dict) still generates successfully without
        # individually setting this; tests that care about it being unset override it explicitly.
        self.state.chromium_resource_class = "brave-browser"
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

    # ---- /running-resource-classes -------------------------------------
    # No POST route — this is set only via dbus_bridge's PushRunningResourceClasses (the KWin
    # script calling in), never over HTTP, so these set state directly rather than POSTing.

    def test_running_resource_classes_defaults_empty(self):
        status, _, body = self.request("GET", "/running-resource-classes")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), [])

    def test_running_resource_classes_reflects_pushed_state(self):
        self.state.running_resource_classes = ["brave-browser", "kate"]
        self.state.running_resource_class_names = {"brave-browser": "brave", "kate": ""}
        status, _, body = self.request("GET", "/running-resource-classes")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), [
            {"resourceClass": "brave-browser", "resourceName": "brave"},
            {"resourceClass": "kate", "resourceName": ""},
        ])

    def test_running_resource_classes_missing_name_defaults_empty_string(self):
        # A resourceClass with no matching entry in running_resource_class_names at all (not just
        # an empty one) — e.g. pushed before main.js started sending names — shouldn't KeyError.
        self.state.running_resource_classes = ["kate"]
        status, _, body = self.request("GET", "/running-resource-classes")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), [{"resourceClass": "kate", "resourceName": ""}])

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

    def get_config(self):
        status, _, body = self.request("GET", "/hotkeys-config")
        self.assertEqual(status, 200)
        return json.loads(body)

    def save(self, bindings, file_hash=None):
        """POSTs bindings the way the page does: with the fileHash from a fresh GET."""
        if file_hash is None:
            file_hash = self.get_config()["fileHash"]
        status, _, body = self.request("POST", "/hotkeys-config", json_body={"bindings": bindings, "fileHash": file_hash})
        return status, json.loads(body)

    def test_hotkeys_config_get_defaults_to_empty_bindings_when_no_file_yet(self):
        config = self.get_config()
        self.assertEqual(config["bindings"], [])
        self.assertEqual(config["invalid"], [])
        self.assertEqual(config["browserResourceClass"], "brave-browser")
        self.assertEqual(config["sourceFile"], "hotkeys.js")

    def test_hotkeys_config_get_reflects_configured_browser_resource_class(self):
        # Informational only (see the handler's own comment) — reflects whatever config.py
        # currently says, not anything read from hotkeys.js itself.
        self.state.chromium_resource_class = "google-chrome"
        self.assertEqual(self.get_config()["browserResourceClass"], "google-chrome")

    def test_hotkeys_config_get_parses_hand_written_hotkeys_js(self):
        self.state.hotkeys_js_path.write_text(
            "// mine\n"
            'registerShortcut("Kate", "AltTabSucks: Kate", "Alt+K", function () { manageAppWindows("org.kde.kate", "cycle"); });\n'
            'registerShortcut("Bad", "AltTabSucks: Bad", "Alt+B", function () { focusTab("b", "P", [], "u"); });\n')
        config = self.get_config()
        self.assertEqual([b["title"] for b in config["bindings"]], ["Kate"])
        self.assertEqual([(i["title"], i["line"]) for i in config["invalid"]], [("Bad", 3)])

    def test_hotkeys_config_post_generates_js(self):
        status, result = self.save([
            {"type": "windowToggle", "title": "Toggle File Manager", "key": "Ctrl+Alt+Shift+E",
             "resourceClass": "org.kde.dolphin", "launchArgv": ["dolphin"]},
        ])
        self.assertEqual(status, 200)
        self.assertTrue(result["ok"])
        self.assertEqual(result["bindingCount"], 1)
        self.assertEqual(result["dropped"], [])
        js = self.state.hotkeys_js_path.read_text()
        self.assertIn('manageAppWindows("org.kde.dolphin", "toggle", ["dolphin"]);', js)

    def test_hotkeys_config_get_after_post_returns_what_was_saved(self):
        binding = {"type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P", "profileName": "Work"}
        self.save([binding])
        (saved,) = self.get_config()["bindings"]
        self.assertEqual({k: saved[k] for k in binding}, binding)

    def test_hotkeys_config_post_keeps_hand_written_text(self):
        self.state.hotkeys_js_path.write_text("function mine() {}\n")
        self.save([{"type": "windowCycle", "title": "Kate", "key": "Alt+K", "resourceClass": "kate"}])
        js = self.state.hotkeys_js_path.read_text()
        self.assertTrue(js.startswith("function mine() {}\n"))
        self.assertEqual(self.state.hotkeys_js_path.with_name("hotkeys.js.bak").read_text(), "function mine() {}\n")

    def test_hotkeys_config_post_stale_file_hash_is_409_and_writes_nothing(self):
        stale = self.get_config()["fileHash"]
        self.state.hotkeys_js_path.write_text("// edited by hand meanwhile\n")
        status, result = self.save([], file_hash=stale)
        self.assertEqual(status, 409)
        self.assertIn("changed", result["error"])
        self.assertEqual(self.state.hotkeys_js_path.read_text(), "// edited by hand meanwhile\n")

    def test_hotkeys_config_post_profile_cycle_uses_configured_browser_not_a_binding_field(self):
        self.state.chromium_resource_class = "google-chrome"
        status, _ = self.save([{"type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P", "profileName": "Work"}])
        self.assertEqual(status, 200)
        self.assertIn('cycleChromiumProfile("google-chrome", "Work", "Work");', self.state.hotkeys_js_path.read_text())

    def test_hotkeys_config_post_browser_scoped_binding_dropped_when_no_browser_configured(self):
        self.state.chromium_resource_class = ""
        status, result = self.save([
            {"type": "tabFocus", "title": "Gmail", "key": "Ctrl+Alt+Shift+G", "profileName": "Personal",
             "urlPatterns": ["mail.google.com"], "openUrl": "https://mail.google.com"},
        ])
        self.assertEqual(status, 200)
        self.assertEqual(result["bindingCount"], 0)
        self.assertIn("run ./installer.sh configure", result["dropped"][0]["reason"])

    def test_hotkeys_config_post_window_cycle_unaffected_by_missing_browser_config(self):
        # windowCycle/windowToggle still take their own resourceClass field — genuinely unrelated
        # to whether a browser is configured at all.
        self.state.chromium_resource_class = ""
        status, result = self.save([{"type": "windowCycle", "title": "Kate", "key": "Ctrl+Alt+Shift+N", "resourceClass": "org.kde.kate"}])
        self.assertEqual((status, result["dropped"]), (200, []))

    def test_hotkeys_config_post_invalid_binding_dropped_and_reported(self):
        status, result = self.save([
            {"type": "tabFocus", "title": "Broken"},  # missing required fields
            {"type": "windowCycle", "title": "Kate", "key": "Alt+K", "resourceClass": "kate"},
        ])
        self.assertEqual(status, 200)
        self.assertEqual([d["title"] for d in result["dropped"]], ["Broken"])
        self.assertEqual([b["title"] for b in self.get_config()["bindings"]], ["Kate"])

    def test_hotkeys_config_post_invalid_json_rejected(self):
        status, _, body = self.request("POST", "/hotkeys-config", raw_body="not json",
                                        extra_headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(body))

    def test_hotkeys_config_post_deploys_on_change(self):
        # self.state.deploy_command is ["true"] (see setUp) — a real subprocess, exit 0.
        status, result = self.save([{"type": "windowCycle", "title": "X", "key": "Alt+X", "resourceClass": "y"}])
        self.assertEqual(status, 200)
        self.assertTrue(result["deployed"])
        self.assertIn("Deployed", result["note"])

    def test_hotkeys_config_post_without_changes_skips_the_deploy(self):
        self.state.deploy_command = ["false"]
        self.save([{"type": "windowCycle", "title": "X", "key": "Alt+X", "resourceClass": "y"}])
        status, result = self.save(self.get_config()["bindings"])
        self.assertEqual(status, 200)
        self.assertEqual(result["note"], "Nothing changed.")

    def test_hotkeys_config_post_reports_deploy_failure_without_losing_the_save(self):
        self.state.deploy_command = ["false"]  # real subprocess, exit 1, no output
        status, result = self.save([{"type": "windowCycle", "title": "X", "key": "Ctrl+Alt+Shift+X", "resourceClass": "y"}])
        self.assertEqual(status, 200)  # the save itself still succeeded
        self.assertFalse(result["deployed"])
        self.assertIn("deploy failed", result["note"])
        # hotkeys.js was still written — a deploy failure doesn't roll it back.
        self.assertIn('"X"', self.state.hotkeys_js_path.read_text())

    def test_hotkeys_config_post_reports_deploy_command_not_found(self):
        self.state.deploy_command = ["/no/such/binary-xyz"]
        status, result = self.save([{"type": "windowCycle", "title": "X", "key": "Alt+X", "resourceClass": "y"}])
        self.assertEqual(status, 200)
        self.assertFalse(result["deployed"])
        self.assertIn("deploy failed", result["note"])

    def test_legacy_hotkeys_json_is_folded_into_hotkeys_js_once(self):
        from alttabsucks_server import fold_legacy_hotkeys_json
        self.state.legacy_hotkeys_json_path.write_text(json.dumps({"bindings": [
            {"type": "windowCycle", "title": "Kate", "key": "Alt+K", "resourceClass": "kate"},
            {"type": "windowCycle", "title": "Off", "key": "Alt+O", "resourceClass": "o", "enabled": False},
        ]}))
        fold_legacy_hotkeys_json(self.state)
        self.assertEqual([(b["title"], b["enabled"]) for b in self.get_config()["bindings"]], [("Kate", True), ("Off", False)])
        self.assertFalse(self.state.legacy_hotkeys_json_path.exists())
        self.assertEqual(len(list(Path(self._hotkeys_tmpdir.name).glob("hotkeys.json.folded-*"))), 1)
        self.assertIsNone(fold_legacy_hotkeys_json(self.state))

    # ---- tab search ----------------------------------------------------------

    def post(self, path, body):
        status, _, raw = self.request("POST", path, json_body=body)
        return status, raw

    def poll_as_extension(self, profile="Personal"):
        """One GET /switchtab, as the extension does every 50ms while its browser runs. Returns
        the dequeued command, if any."""
        status, _, raw = self.request("GET", "/switchtab?profile=" + profile.replace(" ", "%20"))
        return json.loads(raw) if status == 200 else None

    def search(self, q=""):
        """{category: [items]} for GET /tab-search."""
        status, _, raw = self.request("GET", "/tab-search?q=" + q.replace(" ", "+"))
        self.assertEqual(status, 200)
        return {sec["category"]: sec["items"] for sec in json.loads(raw)["sections"]}

    def push_tabs(self):
        self.post("/tabs", {"profile": "Personal", "windows": [{"id": 1, "focused": True, "tabs": [
            {"id": 11, "title": "Inbox - Gmail", "url": "https://mail.google.com/mail",
             "fullUrl": "https://mail.google.com/mail/u/0/#inbox", "active": True, "lastAccessed": 2},
            {"id": 12, "title": "Sailing forecast", "url": "https://windy.com/sailing",
             "fullUrl": "https://windy.com/sailing", "active": False, "lastAccessed": 1}]}]})

    def test_tab_search_shows_open_tabs_only_while_the_browser_is_running(self):
        self.push_tabs()
        self.assertEqual(self.search("sail"), {}, "no extension polling yet: browser closed")
        self.poll_as_extension()
        self.assertEqual([i["tabId"] for i in self.search("sail")["tabs"]], [12])

    def test_recently_closed_is_saved_to_disk_and_shown_when_nothing_is_open(self):
        status, _ = self.post("/recently-closed", {"profile": "Personal", "items": [
            {"sessionId": "s1", "title": "Old article", "url": "https://news.example/a", "closedAt": 5}]})
        self.assertEqual(status, 204)
        saved = json.loads(self.state.tab_search.path.read_text())
        self.assertEqual(saved["recent"]["Personal"][0]["sessionId"], "s1")
        self.assertEqual(self.search("article")["recent"][0]["live"], False)

    def test_saved_data_is_loaded_back(self):
        self.post("/bookmarks", {"profile": "Personal", "items": [{"id": "b1", "title": "Pasta", "url": "https://food.example/"}]})
        from tab_search_state import TabSearchState
        again = TabSearchState(self.state.tab_search.path)
        again.load()
        self.assertEqual(again.bookmarks["Personal"][0]["id"], "b1")

    def test_bookmarks_come_from_the_snapshot_while_the_browser_is_closed(self):
        self.post("/bookmarks", {"profile": "Personal", "items": [
            {"id": "b1", "title": "Pasta recipes", "url": "https://food.example/"},
            {"id": "b2", "title": "Boat parts", "url": "https://boats.example/"}]})
        self.assertEqual([i["id"] for i in self.search("pasta")["bookmarks"]], ["b1"])

    def test_bookmarks_are_searched_in_the_running_browser(self):
        self.post("/bookmarks", {"profile": "Personal", "items": [{"id": "old", "title": "Pasta (stale snapshot)", "url": "https://old.example/"}]})
        self.poll_as_extension()
        seen = []

        def extension():  # answers the searchBookmarks command like background.js does
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                cmd = self.poll_as_extension()
                if cmd and "searchBookmarks" in cmd:
                    seen.append(cmd["searchBookmarks"])
                    self.post("/bookmark-results", {"requestId": cmd["requestId"], "items": [
                        {"id": "live", "title": "Pasta recipes", "url": "https://food.example/"}]})
                    return
                time.sleep(0.02)
        t = threading.Thread(target=extension); t.start()
        r = self.search("pasta")
        t.join()
        self.assertEqual(seen, ["pasta"])
        self.assertEqual([i["id"] for i in r["bookmarks"]], ["live"])

    def test_a_running_browser_that_doesnt_answer_falls_back_to_the_snapshot(self):
        self.post("/bookmarks", {"profile": "Personal", "items": [{"id": "b1", "title": "Pasta", "url": "https://food.example/"}]})
        self.poll_as_extension()  # live, but nothing answers the search
        start = time.monotonic()
        r = self.search("pasta")
        self.assertEqual([i["id"] for i in r["bookmarks"]], ["b1"])
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertIsNone(self.state.switch_queue.get("Personal"), "the unanswered search isn't left queued")

    def test_choosing_an_open_tab_switches_to_it_and_tells_kwin(self):
        self.state.tab_search.begin()
        self.assertEqual(self.state.tab_search.take(), "", "popup still open")
        self.poll_as_extension()
        status, _ = self.post("/tab-search/action", {"kind": "tab", "profile": "Personal", "windowId": 1, "tabId": 12})
        self.assertEqual(status, 204)
        self.assertEqual(self.poll_as_extension(), {"windowId": 1, "tabId": 12})
        self.assertEqual(json.loads(self.state.tab_search.take()), {"kind": "tab", "profile": "Personal", "windowId": 1})
        self.assertEqual(self.state.tab_search.take(), "", "only once")

    def test_closing_a_tab_keeps_the_popup_open(self):
        self.state.tab_search.begin()
        self.post("/tab-search/action", {"kind": "close", "profile": "Personal", "tabId": 12})
        self.assertEqual(self.poll_as_extension(), {"closeTabs": [12]})
        self.assertEqual(self.state.tab_search.take(), "")

    def test_quick_closes_and_a_following_switch_are_all_delivered(self):
        # Before: one command slot per profile, so these overwrote each other within the
        # extension's 50ms poll - the tab vanished from the popup but stayed open.
        self.state.tab_search.begin()
        self.post("/tab-search/action", {"kind": "close", "profile": "Personal", "tabId": 12})
        self.post("/tab-search/action", {"kind": "close", "profile": "Personal", "tabId": 13})
        self.post("/tab-search/action", {"kind": "tab", "profile": "Personal", "windowId": 1, "tabId": 14})
        self.assertEqual(self.poll_as_extension(), {"closeTabs": [12, 13]})
        self.assertEqual(self.poll_as_extension(), {"windowId": 1, "tabId": 14})
        self.assertIsNone(self.poll_as_extension())

    def test_recently_closed_is_restored_in_a_running_browser(self):
        self.state.tab_search.begin()
        self.poll_as_extension()
        self.post("/tab-search/action", {"kind": "recent", "profile": "Personal", "sessionId": "s1", "url": "https://news.example/a"})
        self.assertEqual(self.poll_as_extension(), {"restoreSession": "s1"})
        self.assertEqual(json.loads(self.state.tab_search.take())["kind"], "open")

    def test_with_the_browser_closed_it_launches_and_queues_the_url(self):
        self.state.tab_search.begin()
        self.post("/tab-search/action", {"kind": "bookmark", "profile": "Personal", "url": "https://food.example/"})
        self.assertEqual(self.state.switch_queue["Personal"], {"newTabUrl": "https://food.example/"})
        self.assertEqual(json.loads(self.state.tab_search.take()), {"kind": "launch", "profile": "Personal", "url": "https://food.example/"})

    def test_only_web_urls_can_be_opened(self):
        status, _ = self.post("/tab-search/action", {"kind": "bookmark", "profile": "Personal", "url": "javascript:alert(1)"})
        self.assertEqual(status, 400)

    def test_the_tab_youre_on_is_left_out_using_kwins_front_window(self):
        self.push_tabs()  # "Inbox - Gmail" is the active tab of the focused window
        self.poll_as_extension()
        self.assertNotIn(11, [i["tabId"] for i in self.search("")["tabs"]])
        self.state.tab_search.begin("Sailing forecast - Brave")  # KWin: something else is in front
        self.assertEqual([i["tabId"] for i in self.search("")["tabs"]], [11, 12])
        self.state.tab_search.begin("Inbox - Gmail - Brave")
        self.assertEqual([i["tabId"] for i in self.search("")["tabs"]], [12])

    def test_cancel(self):
        self.state.tab_search.begin()
        self.post("/tab-search/closed", {})
        self.assertEqual(json.loads(self.state.tab_search.take()), {"kind": "cancel"})

    # 1x1 transparent PNG
    PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")

    def test_favicons_upload_only_whats_missing_and_serve_by_key(self):
        urls = ["https://docs.google.com/document/d/1", "https://docs.google.com/document/d/2", "https://example.com/x"]
        status, raw = self.post("/favicons/missing", {"pageUrls": urls})
        self.assertEqual(json.loads(raw)["missing"], [urls[0], urls[2]], "one page per icon key")
        status, raw = self.post("/favicons", {"items": [{"pageUrl": urls[0], "data": base64.b64encode(self.PNG).decode()}]})
        self.assertEqual(json.loads(raw), {"stored": 1})
        status, raw = self.post("/favicons/missing", {"pageUrls": urls})
        self.assertEqual(json.loads(raw)["missing"], [urls[2]])
        status, headers, body = self.request("GET", "/favicon?key=docs.google.com%2Fdocument")
        self.assertEqual((status, headers.get("Content-Type"), body), (200, "image/png", self.PNG))
        self.assertEqual(self.request("GET", "/favicon?key=example.com%2Fx")[0], 404)

    def test_favicons_only_accept_small_pngs(self):
        status, raw = self.post("/favicons", {"items": [
            {"pageUrl": "https://a.example/", "data": base64.b64encode(b"<svg/>").decode()},
            {"pageUrl": "https://b.example/", "data": base64.b64encode(self.PNG + b"x" * 70000).decode()},
            {"pageUrl": "chrome://settings", "data": base64.b64encode(self.PNG).decode()}]})
        self.assertEqual(json.loads(raw), {"stored": 0})

    def test_favicons_survive_a_restart(self):
        self.post("/favicons", {"items": [{"pageUrl": "https://example.com/", "data": base64.b64encode(self.PNG).decode()}]})
        from favicon_store import FaviconStore
        self.assertEqual(FaviconStore(self.state.favicons.dir).get("example.com"), self.PNG)

    def test_search_results_carry_their_icon_key(self):
        self.push_tabs()
        self.poll_as_extension()
        self.assertEqual(self.search("sail")["tabs"][0]["iconKey"], "windy.com/sailing")

    def test_manage_extension_link_asks_the_focused_browser(self):
        self.post("/tabs", {"profile": "Work", "windows": [{"id": 5, "focused": False, "tabs": []}]})
        self.push_tabs()  # Personal, focused
        self.poll_as_extension("Work"); self.poll_as_extension("Personal")
        status, raw = self.post("/open-extension-page", {})
        self.assertEqual((status, json.loads(raw)), (200, {"profile": "Personal"}))
        self.assertEqual(self.poll_as_extension("Personal"), {"openExtensionsPage": True})
        self.assertIsNone(self.poll_as_extension("Work"))

    def test_manage_extension_link_without_a_connected_browser(self):
        status, raw = self.post("/open-extension-page", {})
        self.assertEqual(status, 409)
        self.assertIn("extension", json.loads(raw)["error"])

    def test_hotkeys_page_icon_is_served_without_a_token(self):
        status, headers, body = self.request("GET", "/icons/icon-48.png", token=None)
        self.assertEqual((status, headers.get("Content-Type")), (200, "image/png"))
        self.assertTrue(body.startswith(b"\x89PNG"))

    def test_only_the_extension_icons_are_served(self):
        for path in ("/icons/manifest.json", "/icons/../manifest.json", "/icons/", "/icons/%2e%2e/manifest.json"):
            self.assertEqual(self.request("GET", path, token=None)[0], 404, path)

    def test_tab_search_requires_auth(self):
        status, _, _ = self.request("GET", "/tab-search?q=x", token=None)
        self.assertEqual(status, 403)

    def test_hotkeys_config_requires_auth(self):
        status, _, _ = self.request("GET", "/hotkeys-config", token=None)
        self.assertEqual(status, 403)
        status, _, _ = self.request("POST", "/hotkeys-config", token=None, json_body={"bindings": [], "fileHash": ""})
        self.assertEqual(status, 403)

    # ---- /suggest-launch-command ---------------------------------------------
    # Patches launch_command_suggester.load_desktop_entries rather than touching this machine's
    # real installed apps — same reasoning as AppState.deploy_command/hotkeys_js_path's own
    # per-test overrides: deterministic, and never dependent on what happens to be on disk here.

    def test_suggest_launch_command_returns_match(self):
        entries = [launch_command_suggester.DesktopEntry("Kate", ["kate", "-b"], "kate")]
        with patch.object(launch_command_suggester, "load_desktop_entries", return_value=entries):
            status, _, body = self.request("GET", "/suggest-launch-command?resourceClass=org.kde.kate")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"argv": ["kate", "-b"]})

    def test_suggest_launch_command_no_match_returns_null_argv(self):
        with patch.object(launch_command_suggester, "load_desktop_entries", return_value=[]):
            status, _, body = self.request("GET", "/suggest-launch-command?resourceClass=nothing-like-this")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"argv": None})

    def test_suggest_launch_command_missing_resource_class_param(self):
        with patch.object(launch_command_suggester, "load_desktop_entries", return_value=[]):
            status, _, body = self.request("GET", "/suggest-launch-command")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"argv": None})

    def test_suggest_launch_command_requires_auth(self):
        status, _, _ = self.request("GET", "/suggest-launch-command?resourceClass=kate", token=None)
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
