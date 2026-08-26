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

import re
import subprocess
import threading

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "com.github.tomatointhesand.AltTabSucks"
OBJECT_PATH = "/com/github/tomatointhesand/AltTabSucks"
INTERFACE = "com.github.tomatointhesand.AltTabSucks"


def _strip_scheme_and_www(s):
    s = re.sub(r"^https?://", "", s or "")
    s = re.sub(r"^www\.", "", s)
    return s


def url_matches_pattern(url, pattern):
    """Domain-boundary-aware match used by FindTab below — deliberately stricter than the plain
    substring/wildcard containment GET /findtab and the Windows PS1 server still use (both left
    untouched: this is Linux-only D-Bus glue with no Windows counterpart to keep parity with, see
    the module docstring). Plain `pattern in url` treats "youtube.com" as present inside
    "https://music.youtube.com/watch", wrongly grouping YouTube Music tabs into a plain-YouTube
    binding (and vice versa, since main.js's cleanPatterns lets a binding target
    "music.youtube.com" specifically — see hotkeys.js).

    Instead this matches at the *start* of the (scheme-stripped) URL, tolerating a "www." prefix
    on the URL side only (the one subdomain variation common enough to treat as "the same site"
    without the user having to list it explicitly — every other subdomain, "music.", "mail.",
    etc., is a deliberately different match, consistent with how urlPatterns already lets callers
    OR multiple exact variants together, e.g. ["calendar.google.com", "mail.google.com"]). It also
    requires a boundary right after the pattern — end of string, or one of "/:?#" — so
    "youtube.com" doesn't also match an unrelated "youtube.company.com"."""
    u = _strip_scheme_and_www(url)
    p = _strip_scheme_and_www(str(pattern))
    if not u.startswith(p):
        return False
    return len(u) == len(p) or u[len(p)] in "/:?#"


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
        # Mirrors GET /findtab (micActive -> audible -> leftmost sort) with two deliberate
        # differences. First: each line also carries the tab's title (windowId|tabId|title,
        # title last and unsplit so an embedded "|" in a page title can't be mistaken for a field
        # separator). GET /findtab itself is untouched — Windows AHK has no use for it there.
        #
        # This is *not* the same title use that caused a real bug two commits ago (matching
        # window caption against the *matched* tab's title to decide which window to raise —
        # wrong, because the matched tab isn't necessarily the one currently showing). Here
        # main.js compares this title against workspace.activeWindow.caption *as it already is
        # right now*, synchronously, before anything is switched — a check of present state
        # ("is one of the matches already what's on screen"), not a prediction of future state.
        # It's what makes repeated focusTab presses stay put on an already-showing match instead
        # of always advancing a stale cycle counter regardless of what's actually on screen.
        #
        # Second: matching goes through url_matches_pattern (domain-boundary-aware) instead of
        # plain substring containment — see its docstring for why (music.youtube.com vs
        # youtube.com). GET /findtab and the Windows PS1 server both still do plain substring
        # matching; left that way deliberately, see url_matches_pattern's docstring.
        windows = self._state.store.get(str(profile), [])
        found = []
        for w in windows:
            for tab in w.get("tabs", []):
                if url_matches_pattern(tab.get("url"), url_pattern):
                    found.append({
                        "line": f"{w.get('id')}|{tab.get('id')}|{tab.get('title') or ''}",
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

    @dbus.service.method(INTERFACE, in_signature="si", out_signature="s")
    def GetWindowActiveTitle(self, profile, window_id):
        # What main.js's activateWindowForTab actually needs to find a KWin Window by caption
        # match: a *specific* window's *currently* active tab's title — not the title of the tab
        # FindTab matched (a first attempt at this used that instead, and it was wrong: the
        # matched tab isn't necessarily the one currently showing in its window — that's the
        # whole point of switching to it — so matching against its own title only worked by
        # coincidence when it already happened to be the active tab. Confirmed exactly this way:
        # worked for Gmail, silently fell back to "any window" for YouTube, because the YouTube
        # tab wasn't the one its window was currently displaying). A window's *current* active
        # tab's title is what its caption actually reads right now, before QueueSwitchTab changes
        # anything — reliable regardless of which tab within it FindTab happened to match.
        windows = self._state.store.get(str(profile), [])
        for w in windows:
            if w.get("id") == int(window_id):
                active = next((t for t in w.get("tabs", []) if t.get("active")), None)
                return active.get("title", "") if active else ""
        return ""

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

    @dbus.service.method(INTERFACE, in_signature="s")
    def QueueSplitTab(self, profile):
        # Mirrors POST /switchtab's {splitTab} variant (lib/chromium.ahk's SplitFocusedTab) — the
        # extension dequeues this exactly like any other switch_queue entry and detaches the
        # active tab into its own new window (chrome.windows.create({tabId})); main.js's
        # splitFocusedTab then finds that new window and places it beside the original.
        self._state.switch_queue[str(profile)] = {"splitTab": True}

    @dbus.service.method(INTERFACE, in_signature="s")
    def QueueMergeTabs(self, profile):
        # Mirrors POST /switchtab's {mergeTabs} variant (lib/chromium.ahk's MergeFocusedWindow) —
        # the extension moves every tab from the currently-focused window into the profile's
        # other window and activates/maximizes it; nothing further needed on this side.
        self._state.switch_queue[str(profile)] = {"mergeTabs": True}

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

    @dbus.service.method(INTERFACE, in_signature="as", out_signature="s")
    def RunCommandWithOutput(self, argv):
        # For runCommand hotkey bindings specifically — deliberately not LaunchCommand's
        # detached/output-discarding style, which is right for the GUI apps manageAppWindows
        # launches (never exit, nobody's waiting to read anything from them) but wrong here: a
        # runCommand binding's whole point is a short CLI-style command (installer.sh
        # reload-hotkeys is the motivating case) where the user needs to know whether it actually
        # worked. "I can't tell if the reload hotkeys command is actually working" was the literal
        # report this exists to fix — main.js's runCommandWithToast() shows the result (and any
        # output) in a toast once this returns.
        #
        # Synchronous, blocking the GLib mainloop thread (shared with every other bridge call —
        # FindTab, QueueSwitchTab, ...) for however long the command takes, capped by the 15s
        # timeout below. Not the original design: an earlier version used dbus-python's
        # async_callbacks to reply later from a worker thread instead, specifically to avoid this
        # block. That reply demonstrably reached the D-Bus wire correctly (confirmed independently
        # over dbus-monitor and via a direct qdbus6 call), but KWin's callDBus never delivered it
        # to the waiting JS callback — confirmed by a debug marker as the very first statement of
        # the callback never firing, across multiple real hotkey presses. Root cause inside KWin's
        # own callDBus implementation, not this file; not going to debug that further when a
        # runCommand press is rare enough (manual, not polled) that a plain synchronous reply — the
        # same pattern every other bridge method already uses successfully — is a non-issue in
        # practice (observed total round trip ~34ms for installer.sh reload-hotkeys).
        #
        # Return value is "exitCode\noutput" (exit code on its own first line, everything after
        # the first newline is stdout+stderr) rather than two separate out-args — nothing else in
        # this codebase has exercised callDBus with a multi-value D-Bus return yet, so this sticks
        # to the already-proven single-string-parsed-by-the-caller pattern (see parseTabLine in
        # main.js) rather than being the first thing to assume that works.
        try:
            result = subprocess.run(
                [str(a) for a in argv], capture_output=True, text=True, timeout=15,
            )
            output = ((result.stdout or "") + (result.stderr or "")).strip()
            return f"{result.returncode}\n{output[:4000]}"
        except subprocess.TimeoutExpired:
            return "-1\n(timed out after 15s)"
        except OSError as e:
            return f"-1\n{e}"

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
