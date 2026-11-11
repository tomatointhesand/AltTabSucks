#!/usr/bin/env python3
"""
The Linux startup manager — the port of StartupManager.ahk / lib/startup-manager.ahk. Launches the
items in startup.json one after another, with their delays, in place of the desktop's own
autostart (whose entries autostart_items.py switched off at install). Its window shows each item's
countdown and status, lets you edit the list (changes save as you make them), and shows the
history: every run appends one row to startup-history.jsonl with each item's launch, process and
first-window times. Same file formats and rules as Windows.

  startup_manager.py --logon   the alttabsucks-startup.service at logon: launch, then close itself
  startup_manager.py --run     the same, for testing (recorded as "manual")
  startup_manager.py           just the editor (the app menu's "AltTabSucks Startup")

How it sees things on Wayland:
  processes   /proc: an item's process is running when a process's name (comm, executable or
              argv[0]) is the item's "process"
  windows     KWin: kwin-window-watch.js, loaded into KWin while this runs, reports every normal
              window (pid, class) over D-Bus. An app's window is one whose process is the
              launched one or a child of it, has the item's process name, or whose class is the
              item's windowClass (or process name)
  AltTabSucks the built-in item starts the server and toast services (already started by systemd
              at logon, so normally "already up") and is ready once the server answers and the
              AltTabSucks KWin script is loaded

The decisions are in startup_logic.py and startup_runner.py, tested on their own.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import autostart_items as A  # noqa: E402
import startup_logic as L  # noqa: E402
from startup_runner import Probes, Runner  # noqa: E402

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

APP_ID = "org.alttabsucks.Startup"
TITLE = "AltTabSucks Startup"
WATCH_PATH = "/org/alttabsucks/Startup/Watch"
WATCH_XML = ("<node><interface name='org.alttabsucks.StartupWatch'><method name='Window'>"
             "<arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/>"
             "</method></interface></node>")
KWIN_PLUGIN = "alttabsucks-startup-watch"
SERVER_URL = "http://127.0.0.1:9876/hotkeys-ui"
SERVICES = ["alttabsucks-server.service", "alttabsucks-toast.service"]

CSS = b"""
.summary { font-weight: bold; font-size: 115%; }
.colhead { font-weight: bold; opacity: 0.8; }
.ok { color: #2fa84f; }
.warn { color: #d4880f; }
.error { color: #e0443e; }
.notice { color: #d4880f; }
"""


def log_error(text: str):
    try:
        p = A.errors_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {text}\n")
    except OSError:
        pass


def _excepthook(kind, value, tb):
    # At logon nobody may be looking at a terminal: keep a log too.
    log_error("".join(traceback.format_exception(kind, value, tb)).rstrip())
    sys.__excepthook__(kind, value, tb)


def scoped_argv(argv):
    """argv in its own transient systemd scope under app.slice (like an app started from the
    menu), so it doesn't live in, or die with, this manager's service. Same as dbus_bridge.py's."""
    path = shutil.which("systemd-run")
    if not path:
        return list(argv)
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", os.path.basename(str(argv[0])))[:40] or "app"
    unit = f"app-alttabsucks-startup-{name}-{uuid.uuid4().hex[:8]}"
    return [path, "--user", "--scope", "--quiet", "--collect", "--slice=app.slice", f"--unit={unit}", "--"] + list(argv)


def session_ages():
    """(ms since boot, ms since this graphical session began), either None if unknown."""
    boot = logon = None
    try:
        boot = int(float(Path("/proc/uptime").read_text().split()[0]) * 1000)
    except (OSError, ValueError, IndexError):
        pass
    try:
        sid = subprocess.run(["loginctl", "show-user", str(os.getuid()), "-p", "Display", "--value"],
                             capture_output=True, text=True, timeout=3).stdout.strip()
        if sid:
            usec = subprocess.run(["loginctl", "show-session", sid, "-p", "TimestampMonotonic", "--value"],
                                  capture_output=True, text=True, timeout=3).stdout.strip()
            if usec.isdigit() and int(usec):
                logon = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000 - int(usec) / 1000)
    except (OSError, subprocess.SubprocessError):
        pass
    return boot, logon


class SystemProbes(Probes):
    """The real system: /proc for processes, KWin's reports for windows, the server for
    AltTabSucks."""

    def __init__(self):
        self.windows = []        # [(pid, class)] from kwin-window-watch.js
        self.children = []       # Popen objects, reaped on each scan
        self._procs = {}
        self._scanned = 0.0
        self._builtin_ok = False
        threading.Thread(target=self._watch_builtin, daemon=True).start()

    # ---- processes ----
    def _scan(self):
        if time.monotonic() - self._scanned < 0.2:
            return self._procs
        procs = {}
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            pid = int(d)
            try:
                stat = Path(f"/proc/{d}/stat").read_text()
                comm = stat[stat.index("(") + 1:stat.rindex(")")]
                ppid = int(stat[stat.rindex(")") + 2:].split()[1])
                names = {comm}
                cmd = Path(f"/proc/{d}/cmdline").read_bytes().split(b"\0")
                if cmd and cmd[0]:
                    names.add(os.path.basename(cmd[0].decode(errors="replace")))
                try:
                    names.add(os.path.basename(os.readlink(f"/proc/{d}/exe")).removesuffix(" (deleted)"))
                except OSError:
                    pass
                procs[pid] = (names, ppid)
            except (OSError, ValueError, IndexError):
                continue
        self._procs, self._scanned = procs, time.monotonic()
        self.children = [c for c in self.children if c.poll() is None]
        return procs

    @staticmethod
    def _name_matches(names, process):
        return process in names or process[:15] in names  # comm is cut to 15 characters

    def _running(self, process):
        return any(self._name_matches(n, process) for n, _ in self._scan().values())

    def _descends_from(self, pid, ancestor):
        procs = self._scan()
        for _ in range(64):
            if pid == ancestor:
                return True
            if pid not in procs or pid <= 1:
                return False
            pid = procs[pid][1]
        return False

    def _class_window(self, item):
        classes = {c.lower() for c in (item.get("windowClass", ""), item.get("process", "")) if c}
        return any(cls.lower() in classes for _, cls in self.windows)

    # ---- Probes ----
    def already_running(self, item):
        process = item.get("process", "")
        if process:
            return self._running(process)
        return bool(item.get("windowClass")) and self._class_window(item)

    def launch(self, item):
        if item.get("builtin"):
            proc = subprocess.Popen(["systemctl", "--user", "start", *SERVICES], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.children.append(proc)
            return proc.pid
        argv = A.argv_of(os.path.expanduser(item.get("command", "")))
        if not argv:
            raise ValueError("no command")
        exe = argv[0]
        if not (shutil.which(exe) or (os.sep in exe and os.access(exe, os.X_OK))):
            raise OSError(f"{exe} not found")
        cwd = os.path.expanduser(item.get("workingDir") or "~")
        proc = subprocess.Popen(scoped_argv(argv), cwd=cwd if os.path.isdir(cwd) else str(Path.home()),
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        self.children.append(proc)
        return proc.pid  # systemd-run --scope execs the command itself: this is the app's pid

    def process_seen(self, item, handle):
        process = item.get("process", "")
        if process:
            return self._running(process)
        return (handle in self._scan()) or self._class_window(item)

    def window_seen(self, item, handle):
        process = item.get("process", "")
        procs = self._scan()
        for pid, _ in [(p, c) for p, c in self.windows]:
            if handle and self._descends_from(pid, handle):
                return True
            if process and pid in procs and self._name_matches(procs[pid][0], process):
                return True
        return self._class_window(item)

    def builtin_ready(self):
        return self._builtin_ok

    def _watch_builtin(self):
        bus = None
        while True:
            ok = False
            try:
                urllib.request.urlopen(SERVER_URL, timeout=1).close()
                bus = bus or Gio.bus_get_sync(Gio.BusType.SESSION, None)
                r = bus.call_sync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "isScriptLoaded",
                                  GLib.Variant("(s)", ("alttabsucks",)), GLib.VariantType("(b)"), 0, 1000, None)
                ok = bool(r.unpack()[0])
            except (OSError, GLib.Error):
                pass
            self._builtin_ok = ok
            time.sleep(0.3)


class KWinWatch:
    """Loads kwin-window-watch.js into KWin for as long as the manager runs."""

    def __init__(self, conn):
        self.conn = conn
        self.loaded = False

    def _call(self, path, iface, method, args, sig, reply=None):
        return self.conn.call_sync("org.kde.KWin", path, iface, method, GLib.Variant(sig, args) if sig else None,
                                   GLib.VariantType(reply) if reply else None, 0, 3000, None)

    def start(self, place_self: bool):
        try:
            src = (HERE / "kwin-window-watch.js").read_text(encoding="utf-8")
            if place_self:
                src = src.replace("var PLACE_SELF = false;", "var PLACE_SELF = true;", 1)
            runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
            path = runtime / f"alttabsucks-startup-watch-{os.getpid()}.js"
            self._unload()  # one left over from a manager that didn't get to unload it
            path.write_text(src, encoding="utf-8")
            sid = self._call("/Scripting", "org.kde.kwin.Scripting", "loadScript", (str(path), KWIN_PLUGIN), "(ss)", "(i)").unpack()[0]
            self._call(f"/Scripting/Script{sid}", "org.kde.kwin.Script", "run", None, None)
            self.loaded = True
        except (OSError, GLib.Error) as e:
            log_error(f"couldn't load the KWin window watcher ({e}); windows won't be seen")

    def _unload(self):
        try:
            self._call("/Scripting", "org.kde.kwin.Scripting", "unloadScript", (KWIN_PLUGIN,), "(s)", "(b)")
        except GLib.Error:
            pass

    def stop(self):
        self._unload()
        for p in Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp").glob(f"alttabsucks-startup-watch-{os.getpid()}.js"):
            p.unlink(missing_ok=True)


def label(text="", css=None, width=None, xalign=0.0, ellipsize=True, hexpand=False):
    w = Gtk.Label(label=text, xalign=xalign, hexpand=hexpand)
    if ellipsize:
        from gi.repository import Pango
        w.set_ellipsize(Pango.EllipsizeMode.END)
    if width:
        w.set_size_request(width, -1)
    if css:
        w.add_css_class(css)
    return w


COLS = [("Name", 230), ("Delay", 120), ("Status", None), ("Ready at", 80), ("Took", 80)]
READY_CHOICES = ["its first window appears", "its process is running", "AltTabSucks answers"]


class ManagerWindow(Gtk.ApplicationWindow):
    def __init__(self, app, mode):
        super().__init__(application=app, title=TITLE)
        self.app, self.mode = app, mode
        self.config_error = ""
        # A run (the manager is on) switches back off what it took over and an app switched back on.
        # Not the editor: it also opens while the manager is off, when those entries are given back.
        if mode != "edit":
            try:  # before loading: it updates the saved items' "previous"
                A.retake_known(log=log_error)
            except OSError as e:
                log_error(f"couldn't check the taken-over autostart entries: {e}")
        self.config = self._load_config()
        self.items = self.config["items"]
        self.probes = SystemProbes()
        self.start_mono = time.monotonic()
        self.runner = Runner(self.items, self.config, self.probes, self.now)
        self.trigger = ""
        self.boot_ms = self.logon_ms = None
        self.keep_open = mode == "edit" or bool(self.config.get("stayOpen"))
        self.close_at = None
        self.hidden = False
        self.history_written = False
        self.sel = -1
        self.filling = False
        self.save_pending = False
        self.new_entries = []
        self.view = "items"
        self.rows = []

        self._build()
        if mode != "edit":
            self.boot_ms, self.logon_ms = session_ages() if mode == "logon" else (None, None)
            self.start_run("logon" if mode == "logon" else "manual")
        self.fill_list()
        self.select(0 if self.items else -1)
        self.set_default_size(800, self._default_height())
        if mode == "edit" or self.config.get("takeOver", True):
            self.scan_autostart()
        GLib.timeout_add(100, self.tick)

    # ---- config ----
    def _load_config(self):
        path = A.config_path()
        config = None
        if path.exists():
            try:
                config = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as e:
                self.config_error = f"startup.json can't be read ({e}), so only AltTabSucks starts and nothing is saved."
        if not isinstance(config, dict) or not isinstance(config.get("items"), list):
            config = A.default_config()
        if not any(isinstance(i, dict) and i.get("builtin") == "alttabsucks" for i in config["items"]):
            config["items"].insert(0, A.builtin_item())
        config["items"] = [i for i in config["items"] if isinstance(i, dict)]
        return config

    def save_soon(self):
        if not self.save_pending:
            self.save_pending = True
            GLib.timeout_add(500, self._save)

    def _save(self):
        self.save_pending = False
        if self.config_error:
            return False
        try:
            A.save_config(self.config)
        except OSError as e:
            self.footer.set_text(f"Couldn't save startup.json: {e}")
        return False

    # ---- window ----
    def _build(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_top=10, margin_bottom=10,
                       margin_start=12, margin_end=12)
        self.set_child(root)
        self.summary = label(css="summary")
        root.append(self.summary)

        # Items view: header + list.
        self.items_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, vexpand=True)
        head = Gtk.Box(spacing=8, margin_start=34)
        for name, width in COLS:
            head.append(label(name, css="colhead", width=width, hexpand=width is None))
        self.items_box.append(head)
        self.listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.listbox.connect("row-selected", self.on_row_selected)
        scroll = Gtk.ScrolledWindow(vexpand=True, min_content_height=120)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_child(self.listbox)
        self.list_scroll = scroll
        self.items_box.append(scroll)

        # History view.
        self.hist_grid = Gtk.Grid(column_spacing=16, row_spacing=4)
        self.hist_scroll = Gtk.ScrolledWindow(vexpand=True, visible=False)
        self.hist_scroll.set_child(self.hist_grid)

        root.append(self.items_box)
        root.append(self.hist_scroll)

        # List buttons.
        bar = Gtk.Box(spacing=6)
        self.edit_widgets = []
        for text, fn in [("Add", self.on_add), ("Remove", self.on_remove), ("Up", lambda *_: self.move(-1)),
                         ("Down", lambda *_: self.move(1))]:
            b = Gtk.Button(label=text)
            b.connect("clicked", fn)
            bar.append(b)
            self.edit_widgets.append(b)
        bar.append(Gtk.Box(hexpand=True))
        self.view_btn = Gtk.Button(label="History")
        self.view_btn.connect("clicked", self.toggle_view)
        bar.append(self.view_btn)
        root.append(bar)

        # Edit fields.
        g = Gtk.Grid(column_spacing=8, row_spacing=6)
        self.f_name, self.f_process, self.f_command, self.f_delay = (Gtk.Entry(hexpand=True), Gtk.Entry(hexpand=True),
                                                                     Gtk.Entry(hexpand=True), Gtk.Entry(width_chars=6))
        self.f_browse = Gtk.Button(label="Browse")
        self.f_browse.connect("clicked", self.on_browse)
        self.f_after = Gtk.CheckButton(label="Count it from when the previous item is ready, not launched")
        self.f_ready = Gtk.DropDown.new_from_strings(READY_CHOICES)
        g.attach(label("Name"), 0, 0, 1, 1)
        g.attach(self.f_name, 1, 0, 1, 1)
        g.attach(label("Process"), 2, 0, 1, 1)
        g.attach(self.f_process, 3, 0, 2, 1)
        g.attach(label("Command"), 0, 1, 1, 1)
        g.attach(self.f_command, 1, 1, 3, 1)
        g.attach(self.f_browse, 4, 1, 1, 1)
        g.attach(label("Delay (s)"), 0, 2, 1, 1)
        delay_row = Gtk.Box(spacing=12)
        delay_row.append(self.f_delay)
        delay_row.append(self.f_after)
        g.attach(delay_row, 1, 2, 4, 1)
        g.attach(label("Ready when"), 0, 3, 1, 1)
        ready_row = Gtk.Box()
        ready_row.append(self.f_ready)
        g.attach(ready_row, 1, 3, 4, 1)
        self.edit_grid = g
        root.append(g)
        for f in (self.f_name, self.f_process, self.f_command, self.f_delay):
            f.connect("changed", self.on_edit)
        self.f_after.connect("toggled", self.on_edit)
        self.f_ready.connect("notify::selected", self.on_edit)

        # "Not in this list yet" notice.
        nb = Gtk.Box(spacing=8)
        self.notice = label(css="notice", ellipsize=False, hexpand=True)
        self.notice.set_wrap(True)
        self.take_over_btn = Gtk.Button(label="Take over", valign=Gtk.Align.CENTER)
        self.take_over_btn.connect("clicked", self.on_take_over)
        self.decline_btn = Gtk.Button(label="Leave them to Plasma", valign=Gtk.Align.CENTER)
        self.decline_btn.connect("clicked", self.on_decline)
        nb.append(self.notice)
        nb.append(self.decline_btn)
        nb.append(self.take_over_btn)
        self.notice_box = nb
        nb.set_visible(False)
        root.append(nb)

        # Bottom row.
        bottom = Gtk.Box(spacing=8)
        self.stay_open = Gtk.CheckButton(label="Keep this window open after startup",
                                         active=bool(self.config.get("stayOpen")))
        self.stay_open.connect("toggled", self.on_stay_open)
        self.footer = label(hexpand=True)
        self.launch_all = Gtk.Button(label="Launch the rest now")
        self.launch_all.connect("clicked", lambda *_: (self.keep(), setattr(self.runner, "skip_delays", True)))
        self.run_now = Gtk.Button(label="Run startup now")
        self.run_now.connect("clicked", lambda *_: (self.keep(), self.start_run("manual")))
        close = Gtk.Button(label="Close")
        close.connect("clicked", lambda *_: self.close())
        for w in (self.stay_open, self.footer, self.launch_all, self.run_now, close):
            bottom.append(w)
        root.append(bottom)

        self.connect("close-request", self.on_close_request)
        # Real input on the window keeps it open (not just focus: at logon it may get that by itself).
        click = Gtk.GestureClick()
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        click.connect("pressed", lambda *_: self.keep())
        self.add_controller(click)
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)

    def _default_height(self):
        """Tall enough for every item without a scrollbar, but no taller than the screen."""
        rows = max(len(self.items), 4)
        want = 330 + 36 * rows
        try:
            monitors = Gdk.Display.get_default().get_monitors()
            screen = min(monitors.get_item(i).get_geometry().height for i in range(monitors.get_n_items()))
            return min(want, screen - 90)
        except (AttributeError, TypeError, ValueError):
            return min(want, 900)

    def on_key(self, _ctrl, keyval, _code, _state):
        self.keep()
        if keyval == Gdk.KEY_Escape:
            self.close()
            return True
        return False

    def keep(self):
        self.keep_open, self.close_at = True, None

    def on_stay_open(self, btn):
        # The saved preference. Ticking it keeps this window open now too; unticking it applies from
        # the next startup (you're using the window right now).
        self.keep()
        self.config["stayOpen"] = 1 if btn.get_active() else 0
        self.save_soon()

    def on_close_request(self, *_):
        if self.runner.running:  # keep launching the rest in the background, then exit
            self.hidden = True
            self.set_visible(False)
            return True
        self.app.quit()
        return False

    # ---- running ----
    def now(self):
        return int((time.monotonic() - self.start_mono) * 1000)

    def start_run(self, trigger):
        self.trigger = trigger
        self.start_mono = time.monotonic()
        self.history_written = False
        self.close_at = None
        self.runner.start()
        self.runner.tick()  # launch whatever is due at 0 s right away

    def tick(self):
        # A GLib timeout whose callback raises is removed: one error would freeze the window (no
        # more launches, statuses or auto-close). Log it and keep ticking.
        try:
            return self._tick()
        except Exception:
            log_error("tick failed:\n" + traceback.format_exc().rstrip())
            return True

    def _tick(self):
        if self.runner.tick():
            self.run_finished()
        # The countdown starts once everything is up, even if that's after the run finished (an
        # item that timed out showed up late). Not while something is still missing.
        if (not self.runner.running and self.history_written and self.close_at is None and not self.keep_open
                and not self.hidden and L.all_up(self.items, self.runner.states)):
            self.close_at = time.monotonic() + (L.num(self.config, "autoCloseSeconds") or 5)
        if self.close_at is not None and not self.keep_open and not self.new_entries and time.monotonic() >= self.close_at:
            self.app.quit()
            return False
        if self.get_visible():
            self.update_ui()
        return True

    def run_finished(self):
        if self.history_written:
            return
        self.history_written = True
        row = L.history_row(self.items, self.runner.states, self.trigger, datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
                            self.boot_ms if self.boot_ms is not None else "",
                            self.logon_ms if self.logon_ms is not None else "")
        try:
            p = A.history_path()
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open("a", encoding="utf-8") as f:
                f.write(json.dumps(row) + "\n")
        except OSError as e:
            log_error(f"couldn't write the history: {e}")
        if self.hidden:  # closed while starting up: nothing left to show
            self.app.quit()
        elif self.view == "history":
            self.show_history()

    # ---- list ----
    def fill_list(self):
        while (row := self.listbox.get_row_at_index(0)) is not None:
            self.listbox.remove(row)
        self.rows = []
        for i, item in enumerate(self.items):
            box = Gtk.Box(spacing=8, margin_top=3, margin_bottom=3)
            check = Gtk.CheckButton(active=bool(item.get("enabled", 1)))
            check.connect("toggled", self.on_check, i)
            box.append(check)
            cells = [label(width=w, hexpand=w is None) for _, w in COLS]
            for c in cells:
                box.append(c)
            self.listbox.append(box)
            self.rows.append({"cells": cells, "texts": [None] * len(COLS), "css": None})
        self.update_ui()

    def update_ui(self):
        now = self.now()
        states = self.runner.states
        total = up = ready = 0
        last_up = 0
        for i, item in enumerate(self.items):
            st = states[i] if i < len(states) else {"status": "off"}
            outcome = L.outcome(item, st)
            if st["status"] != "off":
                total += 1
                ready += L.is_done(st["status"])
                if outcome == "ok":
                    up += 1
                    last_up = max(last_up, st.get("readyMs", st.get("doneMs", 0)))
            d = f"{L.num(item, 'delay'):.1f}".removesuffix(".0")
            ready_at = st.get("readyMs", st.get("processMs") if st["status"] == "nowindow" else None)
            texts = [item.get("name", ""), f"{d} s" + (" after ready" if item.get("afterReady") else ""),
                     L.status_text(self.items, i, st, self.runner.plan.get(i), now),
                     L.format_seconds(ready_at),
                     L.format_seconds(ready_at - st["launchMs"]) if ready_at is not None and "launchMs" in st else ""]
            row = self.rows[i] if i < len(self.rows) else None
            if row is None:
                continue
            for c, text in enumerate(texts):
                if row["texts"][c] != text:
                    row["cells"][c].set_text(text)
                    row["texts"][c] = text
            if row["css"] != outcome:
                status = row["cells"][2]
                for cls in ("ok", "warn", "error"):
                    status.remove_css_class(cls)
                if outcome:
                    status.add_css_class(outcome)
                row["css"] = outcome
        if self.config_error:
            summary = self.config_error
        elif self.runner.running:
            summary = f"Starting up: {ready} of {total} ready, {L.format_seconds(now)}"
        elif self.history_written and up == total:
            summary = f"Startup done: everything up after {L.format_seconds(last_up)}"
        elif self.history_written:
            summary = f"Startup: {up} of {total} up, still watching for the rest"
        else:
            summary = f"{len(self.items)} startup items, launched in this order at logon. Changes save as you make them."
        if self.summary.get_text() != summary:
            self.summary.set_text(summary)
        if self.close_at is not None and not self.keep_open and not self.new_entries:
            footer = f"Closing in {max(0, int(self.close_at - time.monotonic() + 0.999))} s (click here to keep it open)"
        elif self.history_written and not self.runner.running and not self.keep_open and up < total:
            footer = "Staying open until everything is up"
        elif self.close_at is not None and not self.keep_open and self.new_entries:
            footer = "Staying open for the autostart apps above: take them over or leave them to Plasma"
        else:
            footer = ""
        if self.footer.get_text() != footer and not self.footer.get_text().startswith("Couldn't save"):
            self.footer.set_text(footer)
        items_view = self.view == "items"
        self.launch_all.set_visible(items_view and self.runner.running)
        self.run_now.set_visible(items_view and not self.runner.running)

    def on_row_selected(self, _lb, row):
        if row is not None and row.get_index() != self.sel:
            self.select(row.get_index())

    def select(self, i):
        self.sel = i
        item = self.items[i] if 0 <= i < len(self.items) else None
        builtin = bool(item and item.get("builtin"))
        self.filling = True
        self.f_name.set_text(item.get("name", "") if item else "")
        self.f_command.set_text("(starts the AltTabSucks services)" if builtin else item.get("command", "") if item else "")
        self.f_process.set_text(item.get("process", "") if item else "")
        self.f_delay.set_text(f"{L.num(item, 'delay'):.1f}".removesuffix(".0") if item else "")
        self.f_after.set_active(bool(item and item.get("afterReady")))
        self.f_ready.set_selected(2 if builtin else 1 if item and item.get("ready") == "process" else 0)
        self.filling = False
        for f in (self.f_name, self.f_delay, self.f_after):
            f.set_sensitive(item is not None)
        for f in (self.f_command, self.f_process, self.f_browse, self.f_ready):
            f.set_sensitive(item is not None and not builtin)
        row = self.listbox.get_row_at_index(i) if i >= 0 else None
        if row is not None and self.listbox.get_selected_row() is not row:
            self.listbox.select_row(row)

    def on_check(self, btn, i):
        if i >= len(self.items):
            return
        self.keep()
        self.items[i]["enabled"] = 1 if btn.get_active() else 0
        self.runner.set_enabled(i, btn.get_active())
        self.save_soon()

    def on_edit(self, widget, *_):
        if self.filling or not (0 <= self.sel < len(self.items)):
            return
        self.keep()
        item = self.items[self.sel]
        if widget is self.f_name:
            item["name"] = widget.get_text()
        elif widget is self.f_command:
            # The process follows the command while it's the one the command implies.
            old = item.get("process", "")
            if not old or old == A.process_name(item.get("command", "")):
                item["process"] = A.process_name(widget.get_text())
                self.filling = True
                self.f_process.set_text(item["process"])
                self.filling = False
            item["command"] = widget.get_text()
        elif widget is self.f_process:
            item["process"] = widget.get_text().strip()
        elif widget is self.f_delay:
            try:
                v = float(widget.get_text())
            except ValueError:
                return
            if v < 0:
                return
            item["delay"] = int(v) if v == int(v) else v
        elif widget is self.f_after:
            item["afterReady"] = 1 if widget.get_active() else 0
        elif widget is self.f_ready:
            if widget.get_selected() == 2:  # AltTabSucks' own (that item can't be edited here)
                widget.set_selected(0)
            item["ready"] = "process" if widget.get_selected() == 1 else "window"
        self.save_soon()

    def on_add(self, *_):
        self.keep()
        self.items.append({"name": "New item", "command": "", "workingDir": "", "process": "", "delay": 1,
                           "afterReady": 0, "ready": "window", "enabled": 1})
        self.runner.insert(len(self.items) - 1)  # not launched in a startup that's already running
        self.fill_list()
        self.select(len(self.items) - 1)
        self.f_name.grab_focus()
        self.save_soon()

    def on_remove(self, *_):
        self.keep()
        if not (0 <= self.sel < len(self.items)):
            return
        item = self.items[self.sel]
        if item.get("builtin"):
            self.alert("AltTabSucks itself can't be removed, only unticked.")
            return
        if item.get("autostart"):
            dialog = Gtk.AlertDialog(message=f"Remove {item.get('name', '')}?",
                                     detail="It came from Plasma's autostart, which will start it again at logon.",
                                     buttons=["Cancel", "Remove"], cancel_button=0, default_button=1)
            dialog.choose(self, None, self._remove_answered, self.sel)
            return
        self._remove(self.sel)

    def _remove_answered(self, dialog, result, i):
        try:
            if dialog.choose_finish(result) != 1:
                return
        except GLib.Error:
            return
        a = self.items[i].get("autostart") or {}
        try:
            p = Path(a.get("file", ""))
            p.write_text(A.set_hidden(p.read_text(encoding="utf-8"), a.get("previous")), encoding="utf-8")
        except OSError as e:
            self.alert(f"Couldn't give it back to Plasma's autostart: {e}")
        self._remove(i)
        self.scan_autostart()

    def _remove(self, i):
        del self.items[i]
        self.runner.remove(i)
        self.fill_list()
        self.select(min(i, len(self.items) - 1))
        self.save_soon()

    def move(self, d):
        self.keep()
        i, j = self.sel, self.sel + d
        if not (0 <= i < len(self.items)) or not (0 <= j < len(self.items)):
            return
        self.items[i], self.items[j] = self.items[j], self.items[i]
        self.runner.swap(i, j)
        self.fill_list()
        self.select(j)
        self.save_soon()

    def on_browse(self, *_):
        self.keep()
        Gtk.FileDialog(title="Choose the program to start").open(self, None, self._browsed)

    def _browsed(self, dialog, result):
        try:
            f = dialog.open_finish(result)
        except GLib.Error:
            return
        path = f.get_path() if f else ""
        if path:
            self.f_command.set_text(f'"{path}"' if " " in path else path)

    def alert(self, text):
        Gtk.AlertDialog(message=text).show(self)

    # ---- the autostart entries not taken over yet ----
    def scan_autostart(self):
        try:
            self.new_entries = A.new_entries()
        except OSError:
            self.new_entries = []
        n = len(self.new_entries)
        if n:
            names = ", ".join(e["name"] for e in self.new_entries)
            it = "it" if n == 1 else "them"
            self.notice.set_text(f"{n} autostart app{'' if n == 1 else 's'} not in this list yet: {names}. "
                                 f"Take {it} over, or remove {it} in System Settings → Autostart.")
        self.notice_box.set_visible(n > 0 and self.view == "items")

    def on_take_over(self, *_):
        self.keep()
        names = {(i.get("name"), i.get("command")) for i in self.items}
        old = {(i.get("name"), i.get("command")): s for i, s in zip(self.items, self.runner.states)}
        try:
            A.import_items(True, log=lambda *_: None)
        except OSError as e:
            self.alert(f"Couldn't take them over: {e}")
            return
        fresh = self._load_config()
        # The new items aren't launched this time; the others keep their status.
        for item in fresh["items"]:
            key = (item.get("name"), item.get("command"))
            if key not in names:
                self.items.append(item)
                self.runner.insert(len(self.items) - 1)
        self.config["takeOver"] = True
        for i, item in enumerate(self.items):
            key = (item.get("name"), item.get("command"))
            if key in old:
                self.runner.states[i] = old[key]
        self.save_soon()
        self.fill_list()
        self.scan_autostart()

    def on_decline(self, *_):
        # Remembered: the logon run stops bringing it up (the editor still shows it).
        self.keep()
        self.config["takeOver"] = False
        self.save_soon()
        self.new_entries = []
        self.notice_box.set_visible(False)

    # ---- history ----
    def toggle_view(self, *_):
        self.keep()
        self.view = "history" if self.view == "items" else "items"
        hist = self.view == "history"
        self.items_box.set_visible(not hist)
        self.edit_grid.set_visible(not hist)
        self.hist_scroll.set_visible(hist)
        for w in self.edit_widgets:
            w.set_visible(not hist)
        self.notice_box.set_visible(not hist and bool(self.new_entries))
        self.view_btn.set_label("Items" if hist else "History")
        if hist:
            self.show_history()
        self.update_ui()

    def show_history(self):
        while (child := self.hist_grid.get_first_child()) is not None:
            self.hist_grid.remove(child)
        rows = []
        try:
            for line in A.history_path().read_text(encoding="utf-8").splitlines():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
        except OSError:
            pass
        t = L.history_table(rows[-200:], [i.get("name", "") for i in self.items])
        for c, h in enumerate(t["header"]):
            self.hist_grid.attach(label(h, css="colhead", ellipsize=False), c, 0, 1, 1)
        for r, line in enumerate(t["rows"]):
            for c, text in enumerate(line):
                self.hist_grid.attach(label(text, ellipsize=False), c, r + 1, 1, 1)
        if not t["rows"]:
            self.hist_grid.attach(label("No startup runs recorded yet."), 0, 1, 4, 1)


class App(Gtk.Application):
    def __init__(self, mode):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.mode = mode
        self.window = None
        self.watch = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        conn = self.get_dbus_connection()
        if conn is not None:
            node = Gio.DBusNodeInfo.new_for_xml(WATCH_XML)
            conn.register_object(WATCH_PATH, node.interfaces[0], self._on_watch_call, None, None)
            self.watch = KWinWatch(conn)

    def _on_watch_call(self, _conn, _sender, _path, _iface, method, params, invocation):
        if method == "Window" and self.window is not None:
            pid, cls, _name = params.unpack()
            self.window.probes.windows.append((int(pid), str(cls)))
        invocation.return_value(None)

    def do_activate(self):
        if self.window is None:  # a second start (the menu entry again) just brings it forward
            self.window = ManagerWindow(self, self.mode)
            if self.watch:
                self.watch.start(place_self=self.mode != "edit")
        self.window.present()

    def do_shutdown(self):
        if self.watch:
            self.watch.stop()
        if self.window is not None and self.window.save_pending:
            self.window._save()
        Gtk.Application.do_shutdown(self)


def main(argv) -> int:
    sys.excepthook = _excepthook
    mode = "logon" if "--logon" in argv else "manual" if "--run" in argv else "edit"
    return App(mode).run([argv[0]])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
