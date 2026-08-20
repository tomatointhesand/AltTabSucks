#!/usr/bin/env python3
"""
D-Bus bridge for the AltTabSucks server — lets the KWin script (which has no XMLHttpRequest, no
process spawning, and no file reads in its scripting sandbox — see the porting checklist's "KDE/
KWin Specifics" section) reach the bridge server's tab state, and spawn processes on its behalf,
via `callDBus`, the one thing that sandbox *does* expose. This is the chosen alternative over
splitting hotkeys across two registration mechanisms: everything stays reachable from inside the
one KWin script.

Requires dbus-python + PyGObject (`python-dbus` and `python-gobject` on Arch) for the D-Bus
object + GLib mainloop. Both were already present on this KDE Plasma install (pulled in
transitively by Plasma itself) — alttabsucks_server.py still checks explicitly at startup and
fails with a clear message rather than a bare ImportError, since that won't hold on every distro.

No token/auth check here (unlike the HTTP API): the D-Bus session bus is already scoped to
processes running as this user's session, which is a stronger boundary than the HTTP token — that
token exists specifically because a malicious webpage can make cross-origin HTTP requests to
localhost with no way for us to stop the request from being *sent* (only from reading the
response). Browsers have no D-Bus access at all, so that attack surface doesn't apply here.

Runs its own GLib mainloop on a dedicated daemon thread, alongside the HTTP server's
serve_forever() loop in the main thread, sharing the same AppState instance directly (no HTTP
round-trip). See the concurrency note above QueueSwitchTab/QueueSwitchOpenUrl below for why this
doesn't need a lock despite the two loops touching the same dicts from different threads.
"""

import subprocess
import threading

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "com.github.tomatointhesand.AltTabSucks"
OBJECT_PATH = "/com/github/tomatointhesand/AltTabSucks"
INTERFACE = "com.github.tomatointhesand.AltTabSucks"


def _spawn_detached(argv):
    """Popen + a background reaper thread. Without ever calling wait()/poll() on a Popen, the
    child becomes a zombie once it exits (its intermediate launcher process, if any, exits well
    before the real app does) and stays one until this long-running server process itself exits
    — confirmed empirically while testing the launch escape hatch. The reaper thread just blocks
    on wait() so the kernel can clean up the process table entry; doesn't touch the D-Bus call
    itself, which already returned by the time this runs."""
    proc = subprocess.Popen(argv, start_new_session=True)
    threading.Thread(target=proc.wait, daemon=True).start()
    return proc


class Bridge(dbus.service.Object):
    """Exposes the subset of the HTTP API the hotkey-handling side (the KWin script) needs to
    read tab state and queue a switch — the same operations lib/chromium.ahk's FocusTab /
    CycleChromiumProfile make over HTTP today. Talks straight to the shared AppState rather than
    looping back through the HTTP server, since it's the same process."""

    def __init__(self, state, bus_name):
        super().__init__(bus_name, OBJECT_PATH)
        self._state = state

    @dbus.service.method(INTERFACE, in_signature="ss", out_signature="s")
    def FindTab(self, profile, url_pattern):
        # Mirrors GET /findtab: substring match, micActive -> audible -> leftmost sort.
        windows = self._state.store.get(str(profile), [])
        found = []
        for w in windows:
            for tab in w.get("tabs", []):
                if str(url_pattern) in (tab.get("url") or ""):
                    found.append({
                        "line": f"{w.get('id')}|{tab.get('id')}",
                        "micActive": bool(tab.get("micActive")),
                        "audible": bool(tab.get("audible")),
                        "index": int(tab.get("index", 0)),
                    })
        found.sort(key=lambda f: (not f["micActive"], not f["audible"], f["index"]))
        return "\n".join(f["line"] for f in found)

    @dbus.service.method(INTERFACE, in_signature="s", out_signature="s")
    def GetActiveTitles(self, profile):
        # Mirrors GET /activetitles, used to build CycleChromiumProfile's HWND-cache key.
        windows = self._state.store.get(str(profile), [])
        titles = []
        for w in windows:
            active = next((t for t in w.get("tabs", []) if t.get("active")), None)
            if active:
                titles.append(active.get("title", ""))
        return "\n".join(titles)

    @dbus.service.method(INTERFACE, in_signature="", out_signature="as")
    def GetProfiles(self):
        # Mirrors GET /profiles.
        return list(self._state.profile_list)

    # Concurrency note: these two are plain single-key dict writes on switch_queue, individually
    # atomic under the GIL. The only read-modify-write sequence on switch_queue is GET
    # /switchtab's dequeue (check-then-clear) on the HTTP thread, and nothing here performs that
    # same sequence concurrently — there's no interleaving that can corrupt or double-deliver a
    # queued command, so no lock is needed. (Contrast with a hypothetical second dequeuer, which
    # would need one.)

    @dbus.service.method(INTERFACE, in_signature="sii")
    def QueueSwitchTab(self, profile, window_id, tab_id):
        # Mirrors POST /switchtab's {windowId, tabId} variant.
        self._state.switch_queue[str(profile)] = {"windowId": int(window_id), "tabId": int(tab_id)}

    @dbus.service.method(INTERFACE, in_signature="ss")
    def QueueSwitchOpenUrl(self, profile, url):
        # Mirrors POST /switchtab's {openUrl} variant.
        self._state.switch_queue[str(profile)] = {"openUrl": str(url)}

    # ---- process spawning ---------------------------------------------------------------
    # The one thing the KWin sandbox categorically cannot do itself (see module docstring) —
    # this is the "launch when nothing's open" escape hatch for manageAppWindows,
    # cycleChromiumProfile, and focusTab's full-launch tier. subprocess.Popen with an argv list
    # (never shell=True) — nothing here is attacker-controlled (hotkeys.js/config.py are local,
    # user-authored files), argv just avoids quoting bugs with paths containing spaces.

    @dbus.service.method(INTERFACE, in_signature="as")
    def LaunchCommand(self, argv):
        # General-purpose launch for manageAppWindows — argv is e.g. ["dolphin"] or
        # ["code", "--new-window"]. Detached: Popen returns immediately, no waiting on the child.
        try:
            _spawn_detached([str(a) for a in argv])
        except OSError as e:
            print(f"AltTabSucks D-Bus bridge: LaunchCommand{list(argv)} failed: {e}")

    @dbus.service.method(INTERFACE, in_signature="s", out_signature="b")
    def LaunchChromiumProfile(self, profile):
        # Mirrors RunChromiumProfile/the launch branches of CycleChromiumProfile & FocusTab:
        # resolves profile -> profile *directory* (from the self-discovery in
        # profile_discovery.py — see AppState.chromium_profile_dirs), clears stale server-side
        # tab state for it first (same as AHK's DELETE /tabs before Run(), so a subsequent
        # FindTab/GetActiveTitles poll only ever sees freshly-posted windows from *this* launch,
        # not leftover data from a previous session), then spawns
        # `$CHROMIUM_EXE --profile-directory=<dir> $CHROMIUM_EXTRA_FLAGS`. Returns False (and
        # spawns nothing) if the profile or CHROMIUM_EXE aren't configured/known.
        profile = str(profile)
        profile_dir = self._state.chromium_profile_dirs.get(profile)
        if not profile_dir or not self._state.chromium_exe:
            return False
        self._state.store.pop(profile, None)
        argv = [self._state.chromium_exe, f"--profile-directory={profile_dir}"]
        argv.extend(self._state.chromium_extra_flags)
        try:
            _spawn_detached(argv)
        except OSError as e:
            print(f"AltTabSucks D-Bus bridge: LaunchChromiumProfile({profile!r}) failed: {e}")
            return False
        return True


def start(state):
    """Starts the D-Bus service on a dedicated GLib mainloop thread and returns it (daemon
    thread — dies with the process; nothing to join). Call once per process, from main() only —
    never at import time, so tests that construct AppState directly never need a session bus."""
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    bus_name = dbus.service.BusName(BUS_NAME, bus)
    Bridge(state, bus_name)
    loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run, daemon=True, name="alttabsucks-dbus")
    thread.start()
    return thread
