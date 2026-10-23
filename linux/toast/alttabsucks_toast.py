#!/usr/bin/env python3
"""
Toast overlay daemon — Linux port of lib/toast.ahk's ShowProfileToast (SampleTitlebarColor and
the setup/choice-dialog toasts are NOT ported here; see the porting checklist for what's in vs.
out of scope). A colored, borderless, momentary text overlay centered on the window a hotkey just
activated — window/profile cycling, tab focus, etc. Also hosts the tab search popup
(TabSearchWindow, shown by tabSearch hotkeys), for the same reason: a warm GTK process opens it
without a cold-start delay.

Why a separate persistent daemon instead of spawning a process per toast (the same LaunchCommand
escape hatch manageAppWindows/cycleChromiumProfile use to launch apps): the AHK version's rainbow-
cycling-on-rapid-fire behavior (toast_colors.next_color) needs memory of the previous toast's color
and timing, and cold-starting GTK4 per call would add visible latency to what's meant to be instant
feedback. A daemon that stays warm and holds that state across calls is the only way to get both.

Why GTK4 + gtk4-layer-shell instead of anything Qt-based, even though this is otherwise a very
Qt/KDE-flavored codebase (kglobalaccel, KWin scripting, layer-shell-qt is already installed as a
Plasma dependency): there's no Python Qt binding installed here (PySide6/PyQt6), and layer-shell-qt
has no scriptable D-Bus surface of its own (LayerShellQt::Window is a QML-attached C++ type, not
something a bare-QML `qml6` invocation can expose as a service) — building that in Qt would mean
either adding a large new Python dependency or writing and compiling a small C++ binary as part of
install. GTK4 needs exactly one new package (gtk4-layer-shell) and reuses PyGObject (`gi`), already
a hard dependency of dbus_bridge.py.

Known linking quirk (see https://github.com/wmww/gtk4-layer-shell/blob/main/linking.md): PyGObject
loads libwayland-client before gtk4-layer-shell gets a chance to intercept its symbols, so every
invocation needs LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so (or wherever it's installed — resolved
by installer.sh at install time, not hardcoded into the systemd unit file that's tracked in git).
Without it, layer-shell calls below silently fail (the window renders as an ordinary floating
window instead of an overlay) rather than raising — confirmed empirically.

No titlebar-color sampling (AHK's SampleTitlebarColor DllCall(GetPixel...)): reading arbitrary
screen pixels isn't available to an unprivileged Wayland client without an xdg-desktop-portal
screenshot permission grant, which means an interactive prompt — a non-starter for something meant
to fire silently on every hotkey press. Toasts use a single fixed base color (DEFAULT_BG, the same
navy already used by ShowSetupToast/ShowChoiceDialog elsewhere in this project) instead; the
rainbow-cycling behavior on rapid repeated presses is preserved in full, since that only ever
needed *a* previous color to advance from, not a sampled one.
"""

import json
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from toast_colors import DEFAULT_BG, DEFAULT_DURATION_MS, SHADOW_COLOR, ToastState, next_color  # noqa: E402

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, Gtk, Gtk4LayerShell, GLib, Pango  # noqa: E402

import dbus  # noqa: E402
import dbus.mainloop.glib  # noqa: E402
import dbus.service  # noqa: E402

BUS_NAME = "com.github.tomatointhesand.AltTabSucksToast"
OBJECT_PATH = "/com/github/tomatointhesand/AltTabSucksToast"
INTERFACE = "com.github.tomatointhesand.AltTabSucksToast"

# Command results have to be read, not just glanced at like a profile/window toast — 500ms
# (DEFAULT_DURATION_MS) would be gone before anyone could react to it.
COMMAND_RESULT_DEFAULT_DURATION_MS = 4000


class ToastWindow:
    """Owns the one persistent layer-shell surface, restyled/repositioned/shown in place on every
    ShowToast call rather than created fresh each time — keeps the daemon's GTK machinery warm
    (see module docstring) and gives next_color()'s rainbow-continuation check something live to
    read (self.win.get_visible())."""

    def __init__(self):
        self.win = Gtk.Window()
        self.win.set_decorated(False)
        Gtk4LayerShell.init_for_window(self.win)
        Gtk4LayerShell.set_layer(self.win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_keyboard_mode(self.win, Gtk4LayerShell.KeyboardMode.NONE)
        Gtk4LayerShell.set_exclusive_zone(self.win, -1)  # never reserves screen space
        Gtk4LayerShell.set_anchor(self.win, Gtk4LayerShell.Edge.TOP, True)
        Gtk4LayerShell.set_anchor(self.win, Gtk4LayerShell.Edge.LEFT, True)
        Gtk4LayerShell.set_namespace(self.win, "alttabsucks-toast")

        # One box holding both labels rather than two separate windows — show()/show_command_
        # result() just toggle which widgets are populated/visible, keeping this the single
        # persistent surface the module docstring explains the whole daemon exists for.
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.box.set_name("toast-box")
        self.win.set_child(self.box)

        self.title_label = Gtk.Label()
        self.title_label.set_name("toast-title")
        self.box.append(self.title_label)

        # Only populated/shown by show_command_result() — a plain profile/window toast never
        # touches this. Left-aligned, wrapped, real casing (not uppercased) and monospace, since
        # unlike the title this text needs to actually be *read*, not just glanced at.
        self.output_label = Gtk.Label()
        self.output_label.set_name("toast-output")
        self.output_label.set_wrap(True)
        self.output_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR)  # force-break long unbroken runs (paths, flags)
        self.output_label.set_xalign(0)
        self.output_label.set_max_width_chars(64)
        self.output_label.set_visible(False)
        self.box.append(self.output_label)

        self._css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self._css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self._hide_source_id = None

    def show(self, text, bg_hex, win_x, win_y, win_w, win_h, duration_ms):
        self.output_label.set_visible(False)
        self.title_label.set_text(text.upper())
        self._css.load_from_data((
            # The *toplevel* window's own CSS node has to be fully transparent, not just
            # the color the toast actually looks like — GTK4 composites a layer-shell
            # surface's alpha from the window node itself, and painting a solid color +
            # border-radius directly on it only rounds how that node's *own* background is
            # drawn, it doesn't punch real alpha=0 holes in the surface outside the radius.
            # Confirmed live: doing that left the corners outside the rounded rect opaque
            # black instead of see-through. The actual visible rounded box is #toast-box, a
            # *child* widget — children are always composited as textures over whatever the
            # window node underneath already is, so a transparent window + an opaque rounded
            # child is what actually gets a clean rounded shape with transparent corners.
            # box-shadow: none is required too — CSS cascade is per-property, not per-rule, so
            # overriding background-color above does NOT clear the active GTK theme's own
            # default box-shadow on `window` (Adwaita-style themes ship one with a downward
            # offset). Left in place, that shadow still gets rasterized into the transparent
            # window's alpha, showing up as a few dark/purplish pixels right at the rounded
            # corners — confirmed live: visible at both bottom corners, absent at the top
            # corners, exactly matching a downward-offset shadow.
            "window { background-color: transparent; box-shadow: none; }\n"
            "#toast-box { background-color: %s; border-radius: 14px; }\n"
            "#toast-title {\n"
            "  color: white; font-weight: 800; font-size: 24px; font-family: monospace;\n"
            "  text-shadow: 2px 3px 0 %s;\n"
            "  padding: 20px 32px;\n"
            "}\n" % (bg_hex, SHADOW_COLOR)
        ).encode("utf-8"))
        # measure() doesn't include a label's own CSS padding (confirmed empirically) — 32px/20px
        # here match the padding declared just above.
        self._position_and_show(win_x, win_y, win_w, win_h, duration_ms, pad_w=64, pad_h=40)

    def show_command_result(self, title, ok, output, win_x, win_y, win_w, win_h, duration_ms):
        # Deliberately its own color scheme, not next_color()'s rainbow — a command either
        # succeeded or it didn't, and green/red says that at a glance the way no ROYGBIV position
        # would. Not run through next_color() at all: rapid-fire color cycling is a "you're
        # flipping through windows/tabs fast" signal, meaningless for a one-off command result.
        bg = "#123822" if ok else "#3a1515"
        accent = "#4cd97b" if ok else "#ff5b5b"
        self.title_label.set_text(title + ("  ✓" if ok else "  ✗"))
        output = output.strip()
        if output:
            self.output_label.set_text(output)
            self.output_label.set_visible(True)
        else:
            self.output_label.set_visible(False)
        self._css.load_from_data((
            # See show()'s comment on why the window node itself has to be fully transparent,
            # box-shadow included, and the actual visible rounded box has to be the #toast-box
            # child instead.
            "window { background-color: transparent; box-shadow: none; }\n"
            "#toast-box { background-color: %s; border-radius: 14px; border: 1px solid %s; }\n"
            "#toast-title {\n"
            "  color: white; font-weight: 800; font-size: 18px; font-family: monospace;\n"
            "  padding: 16px 24px 4px 24px;\n"
            "}\n"
            "#toast-output {\n"
            "  color: #cfd6e4; font-weight: 400; font-size: 12px; font-family: monospace;\n"
            "  padding: 4px 24px 16px 24px;\n"
            "}\n" % (bg, accent)
        ).encode("utf-8"))
        # Combined vertical CSS padding of both labels (16+4 title, 4+16 output) when output is
        # visible; a bit generous when it's hidden (a hidden child contributes nothing, so the
        # true pad is just the title's own 16+4=20 then) — a few px off just nudges the toast
        # slightly off dead-center, not a real problem, so this doesn't bother branching on it.
        self._position_and_show(win_x, win_y, win_w, win_h, duration_ms, pad_w=48, pad_h=40)

    def _position_and_show(self, win_x, win_y, win_w, win_h, duration_ms, pad_w, pad_h):
        if win_w <= 0 or win_h <= 0:
            # No window to center on (e.g. installer.sh restart's own result): the first monitor.
            monitors = Gdk.Display.get_default().get_monitors()
            if monitors.get_n_items():
                geo = monitors.get_item(0).get_geometry()
                win_x, win_y, win_w, win_h = geo.x, geo.y, geo.width, geo.height
        monitor = self._find_monitor(win_x, win_y)
        if monitor is not None:
            Gtk4LayerShell.set_monitor(self.win, monitor)
            mon_geo = monitor.get_geometry()
            mon_x, mon_y = mon_geo.x, mon_geo.y
        else:
            mon_x = mon_y = 0

        self.win.set_visible(True)  # needed before measure() has a display to lay out against
        _, natural_w, _, _ = self.box.measure(Gtk.Orientation.HORIZONTAL, -1)
        _, natural_h, _, _ = self.box.measure(Gtk.Orientation.VERTICAL, -1)
        est_w = natural_w + pad_w
        est_h = natural_h + pad_h

        Gtk4LayerShell.set_margin(
            self.win, Gtk4LayerShell.Edge.LEFT, max(0, win_x - mon_x + (win_w - est_w) // 2)
        )
        Gtk4LayerShell.set_margin(
            self.win, Gtk4LayerShell.Edge.TOP, max(0, win_y - mon_y + (win_h - est_h) // 2)
        )

        if self._hide_source_id is not None:
            GLib.source_remove(self._hide_source_id)
        self._hide_source_id = GLib.timeout_add(duration_ms, self._hide)

    def _hide(self):
        self.win.set_visible(False)
        self._hide_source_id = None
        return False  # one-shot

    def _find_monitor(self, x, y):
        """Which physical output the target window is actually on — layer-shell margins are
        monitor-relative, not global-screen-relative, so getting this wrong means the toast
        appears on the wrong monitor entirely in a multi-monitor setup rather than just being
        slightly mispositioned."""
        display = Gdk.Display.get_default()
        monitors = display.get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            geo = m.get_geometry()
            if geo.x <= x < geo.x + geo.width and geo.y <= y < geo.y + geo.height:
                return m
        return monitors.get_item(0) if monitors.get_n_items() else None


SERVER = "http://127.0.0.1:9876"
TOKEN_PATH = Path(__file__).resolve().parents[2] / "Server" / "token.txt"
SECTION_LABELS = {"tabs": "Open tabs", "recent": "Recently closed", "bookmarks": "Bookmarks"}


class TabSearchWindow:
    """The tab search popup (tabSearch hotkeys -> main.js showTabSearch -> ShowTabSearch below).

    Results come from the server's GET /tab-search on every keystroke (see
    linux/server/tab_search.py: open tabs, else recently closed, else bookmarks); picking one,
    or closing a tab with Ctrl+W, goes to POST /tab-search/action. Requests run on a worker
    thread so typing never waits on the network, and only the latest query's results are drawn.
    The selection resets to the top result whenever new results arrive.

    A keyboard-exclusive layer-shell surface with no anchors, which the compositor centers on the
    chosen monitor. Its CSS is scoped to its own widget names: CSS providers are display-wide, and
    the toast's rules (bare `window` selectors) apply to every window in this process."""

    def __init__(self):
        self.win = Gtk.Window()
        self.win.set_name("ts-window")
        self.win.set_decorated(False)
        Gtk4LayerShell.init_for_window(self.win)
        Gtk4LayerShell.set_layer(self.win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_keyboard_mode(self.win, Gtk4LayerShell.KeyboardMode.EXCLUSIVE)
        Gtk4LayerShell.set_namespace(self.win, "alttabsucks-tab-search")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_name("ts-box")
        self.win.set_child(box)
        self.entry = Gtk.Entry()
        self.entry.set_name("ts-entry")
        self.entry.set_placeholder_text("Search tabs, recently closed, bookmarks")
        self.entry.connect("changed", lambda e: self._request(e.get_text()))
        box.append(self.entry)
        self.header = Gtk.Label(xalign=0)
        self.header.set_name("ts-header")
        box.append(self.header)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_min_content_height(440)
        scroller.set_min_content_width(760)
        self.list = Gtk.ListBox()
        self.list.set_name("ts-list")
        self.list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.list.connect("row-activated", lambda _l, row: self._choose(row))
        scroller.set_child(self.list)
        self.scroller = scroller
        box.append(scroller)
        hint = Gtk.Label(label="↑↓ select   Enter open   Ctrl+W close tab   Esc cancel", xalign=0)
        hint.set_name("ts-hint")
        box.append(hint)

        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)  # before the entry sees them
        keys.connect("key-pressed", self._on_key)
        self.win.add_controller(keys)
        self.win.connect("notify::is-active", self._on_active_changed)

        css = Gtk.CssProvider()
        css.load_from_data((
            "#ts-window { background-color: transparent; box-shadow: none; }\n"
            "#ts-box { background-color: #1A2A3A; border-radius: 14px; border: 1px solid #2f4a63; padding: 14px; }\n"
            "#ts-entry { font-size: 17px; padding: 8px 10px; background: #0f1b27; color: white; border-radius: 8px; }\n"
            "#ts-header { color: #8fb3d9; font-size: 12px; font-weight: 700; margin: 2px 4px 0 4px; }\n"
            ".ts-section { color: #8fb3d9; font-size: 11px; font-weight: 700; margin: 8px 0 2px 0; }\n"
            "#ts-list, #ts-list > row { background: transparent; }\n"
            "#ts-list > row { padding: 6px 8px; border-radius: 8px; }\n"
            "#ts-list > row:selected { background: #2e5a88; }\n"
            ".ts-title { color: white; font-size: 14px; }\n"
            ".ts-url { color: #8a9bb0; font-size: 11px; }\n"
            ".ts-profile { color: #1A2A3A; background: #8fb3d9; border-radius: 6px; padding: 0 6px; font-size: 11px; font-weight: 700; }\n"
            "#ts-hint { color: #6f8399; font-size: 11px; margin: 0 4px; }\n"
        ).encode("utf-8"))
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self._item_of = {}  # Gtk.ListBoxRow -> its result; section header rows aren't in here
        self._seq = 0
        self._token = ""
        self._shown_at = 0.0
        # Favicons by iconKey (see linux/server/favicon_store.py): a Gdk.Texture, or None when the
        # server doesn't have one yet (retried on the next show). _icon_waiting: images to fill in
        # once an in-flight fetch lands.
        self._icons = {}
        self._icon_waiting = {}

    # ---- showing / hiding --------------------------------------------------------------------

    def show(self, win_x, win_y, win_w, win_h):
        try:
            self._token = TOKEN_PATH.read_text(encoding="utf-8").strip()
        except OSError:
            self._token = ""
        monitor = _monitor_at(win_x + win_w // 2, win_y + win_h // 2)
        if monitor is not None:
            Gtk4LayerShell.set_monitor(self.win, monitor)
        self._icons = {k: v for k, v in self._icons.items() if v is not None}  # retry missing ones
        self.entry.set_text("")
        self._request("")
        self._shown_at = time.monotonic()
        self.win.set_visible(True)
        self.win.present()
        self.entry.grab_focus()

    def _hide(self):
        self.win.set_visible(False)

    def _cancel(self):
        if self.win.get_visible():
            self._hide()
            self._post("/tab-search/closed", {})

    def _on_active_changed(self, *_):
        # Clicking another window: treat like Esc (ignoring the activation churn right after show).
        if self.win.get_visible() and not self.win.is_active() and time.monotonic() - self._shown_at > 0.3:
            self._cancel()

    # ---- keys --------------------------------------------------------------------------------

    def _on_key(self, _ctl, keyval, _keycode, state):
        name = Gdk.keyval_name(keyval) or ""
        ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
        if name == "Escape":
            self._cancel()
        elif name in ("Down", "Up"):
            self._move(1 if name == "Down" else -1)
        elif name in ("Return", "KP_Enter"):
            self._choose(self.list.get_selected_row())
        elif ctrl and name.lower() == "w":
            self._close_selected_tab()
        else:
            return False  # typing: let the entry have it
        return True

    def _result_rows(self):
        """The selectable rows, top to bottom (section headers left out)."""
        rows, row = [], self.list.get_first_child()
        while row is not None:
            if row in self._item_of:
                rows.append(row)
            row = row.get_next_sibling()
        return rows

    def _move(self, step):
        rows = self._result_rows()
        if not rows:
            return
        current = self.list.get_selected_row()
        i = rows.index(current) + step if current in rows else 0
        self._select(rows[max(0, min(len(rows) - 1, i))])

    def _select(self, row):
        self.list.select_row(row)
        # Keep it in view; focus stays in the entry so typing continues to work.
        adj = self.scroller.get_vadjustment()
        ok, rect = row.compute_bounds(self.list)
        if ok:
            if rect.origin.y < adj.get_value():
                adj.set_value(rect.origin.y)
            elif rect.origin.y + rect.size.height > adj.get_value() + adj.get_page_size():
                adj.set_value(rect.origin.y + rect.size.height - adj.get_page_size())

    # ---- results -----------------------------------------------------------------------------

    def _request(self, query):
        self._seq += 1
        seq = self._seq

        def work():
            try:
                req = urllib.request.Request(SERVER + "/tab-search?q=" + urllib.parse.quote(query),
                                             headers={"X-AltTabSucks-Token": self._token})
                with urllib.request.urlopen(req, timeout=3) as r:
                    data = json.loads(r.read())
            except Exception as e:  # server down, bad token: say so instead of an empty list
                data = {"sections": [], "error": str(e)}
            GLib.idle_add(self._apply, seq, data)

        threading.Thread(target=work, daemon=True).start()

    def _apply(self, seq, data):
        if seq != self._seq:
            return False  # a newer query is already on its way
        sections = data.get("sections") or []
        self.header.set_text(("Server unavailable: " + data["error"]) if data.get("error")
                             else "" if sections else "No matches")
        self.header.set_visible(bool(self.header.get_text()))
        self.list.remove_all()
        self._item_of = {}
        for section in sections:
            label = Gtk.Label(label=SECTION_LABELS.get(section.get("category"), ""), xalign=0)
            label.add_css_class("ts-section")
            header = Gtk.ListBoxRow(selectable=False, activatable=False)
            header.set_child(label)
            self.list.append(header)
            for item in section.get("items") or []:
                row = Gtk.ListBoxRow()
                row.set_child(self._row(item, data.get("showProfile")))
                self.list.append(row)
                self._item_of[row] = item
        self.scroller.get_vadjustment().set_value(0)  # first section's header in view
        rows = self._result_rows()
        if rows:
            self._select(rows[0])
        return False

    def _row(self, item, show_profile):
        title = Gtk.Label(label=item.get("title") or item.get("url") or "", xalign=0)
        title.add_css_class("ts-title")
        title.set_ellipsize(Pango.EllipsizeMode.END)
        title.set_hexpand(True)
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        top.append(self._icon(item.get("iconKey")))
        if show_profile:
            prof = Gtk.Label(label=item.get("profile") or "")
            prof.add_css_class("ts-profile")
            top.append(prof)
        top.append(title)
        url = Gtk.Label(label=item.get("url") or "", xalign=0)
        url.add_css_class("ts-url")
        url.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        box.append(top)
        box.append(url)
        return box

    def _icon(self, key):
        """A 16px favicon: from the cache, or blank until the background fetch lands (blank space
        rather than nothing, so titles don't shift when it does)."""
        image = Gtk.Image()
        image.set_pixel_size(16)
        image.set_size_request(16, 16)
        image.set_valign(Gtk.Align.CENTER)
        if not key:
            return image
        if key in self._icons:
            if self._icons[key] is not None:
                image.set_from_paintable(self._icons[key])
            return image
        waiting = self._icon_waiting.setdefault(key, [])
        waiting.append(image)
        if len(waiting) == 1:
            self._fetch_icon(key)
        return image

    def _fetch_icon(self, key):
        token = self._token

        def work():
            png = None
            try:
                req = urllib.request.Request(SERVER + "/favicon?key=" + urllib.parse.quote(key, safe=""),
                                             headers={"X-AltTabSucks-Token": token})
                with urllib.request.urlopen(req, timeout=3) as r:
                    png = r.read()
            except Exception:
                pass  # 404 (not uploaded yet) or server down: stays blank
            GLib.idle_add(self._icon_loaded, key, png)

        threading.Thread(target=work, daemon=True).start()

    def _icon_loaded(self, key, png):
        texture = None
        if png:
            try:
                texture = Gdk.Texture.new_from_bytes(GLib.Bytes.new(png))
            except GLib.Error:
                texture = None
        self._icons[key] = texture
        for image in self._icon_waiting.pop(key, []):
            if texture is not None:
                image.set_from_paintable(texture)
        return False

    # ---- actions -----------------------------------------------------------------------------

    def _choose(self, row):
        item = self._item_of.get(row)
        if item is not None:
            self._hide()
            self._post("/tab-search/action", item)

    def _close_selected_tab(self):
        row = self.list.get_selected_row()
        if row is None:
            return
        item = self._item_of.get(row)
        if item is None or item.get("kind") != "tab":
            return  # only open tabs can be closed
        self._post("/tab-search/action", {"kind": "close", "profile": item["profile"], "tabId": item["tabId"]})
        # Drop it here right away; the extension's own update arrives a moment later. The next row
        # gets the selection (or the previous one, at the end); an emptied section loses its header.
        rows = self._result_rows()
        i = rows.index(row)
        prev, nxt = row.get_prev_sibling(), row.get_next_sibling()
        del self._item_of[row]
        self.list.remove(row)
        if prev is not None and prev not in self._item_of and (nxt is None or nxt not in self._item_of):
            self.list.remove(prev)
        rows = self._result_rows()
        if rows:
            self._select(rows[min(i, len(rows) - 1)])

    def _post(self, path, body):
        token = self._token

        def work():
            try:
                req = urllib.request.Request(SERVER + path, data=json.dumps(body).encode("utf-8"), method="POST",
                                             headers={"Content-Type": "application/json", "X-AltTabSucks-Token": token})
                urllib.request.urlopen(req, timeout=3).close()
            except Exception as e:
                print(f"alttabsucks-toast: POST {path} failed: {e}", file=sys.stderr)

        threading.Thread(target=work, daemon=True).start()


def _monitor_at(x, y):
    display = Gdk.Display.get_default()
    monitors = display.get_monitors()
    for i in range(monitors.get_n_items()):
        m = monitors.get_item(i)
        geo = m.get_geometry()
        if geo.x <= x < geo.x + geo.width and geo.y <= y < geo.y + geo.height:
            return m
    return monitors.get_item(0) if monitors.get_n_items() else None


class ToastService(dbus.service.Object):
    def __init__(self, bus_name, toast, tab_search):
        super().__init__(bus_name, OBJECT_PATH)
        self._toast = toast
        self._tab_search = tab_search
        self._state = ToastState()

    @dbus.service.method(INTERFACE, in_signature="iiii")
    def ShowTabSearch(self, win_x, win_y, win_w, win_h):
        # From main.js's showTabSearch; the geometry (active window, or screen) picks the monitor.
        self._tab_search.show(int(win_x), int(win_y), int(win_w), int(win_h))

    @dbus.service.method(INTERFACE, in_signature="ssiiiii")
    def ShowToast(self, label, bg_hex, win_x, win_y, win_w, win_h, duration_ms):
        now_ms = int(time.monotonic() * 1000)
        color = next_color(
            self._state, str(bg_hex) or DEFAULT_BG, now_ms, self._toast.win.get_visible()
        )
        self._toast.show(
            str(label), color, int(win_x), int(win_y), int(win_w), int(win_h),
            int(duration_ms) or DEFAULT_DURATION_MS,
        )

    @dbus.service.method(INTERFACE, in_signature="sisiiiii")
    def ShowCommandResult(self, title, ok, output, win_x, win_y, win_w, win_h, duration_ms):
        # For runCommand hotkey bindings (main.js's runCommandWithToast) — deliberately a
        # different shape from ShowToast: this has something to actually *read* (a command's
        # output), not just glance at, so it defaults to a much longer duration
        # (COMMAND_RESULT_DEFAULT_DURATION_MS) unless the caller asks for something else.
        # ok is an int (0/1), not a D-Bus boolean — every other bridge argument in this codebase
        # is a string/int/array, never a bool; sticking to what's already proven to marshal
        # correctly through callDBus rather than being the first thing to assume a bool does too.
        self._toast.show_command_result(
            str(title), bool(int(ok)), str(output), int(win_x), int(win_y), int(win_w), int(win_h),
            int(duration_ms) or COMMAND_RESULT_DEFAULT_DURATION_MS,
        )


def main():
    if not Gtk4LayerShell.is_supported():
        sys.exit(
            "alttabsucks-toast: the compositor doesn't support the wlr-layer-shell protocol "
            "(or LD_PRELOAD=libgtk4-layer-shell.so wasn't set — see this file's module "
            "docstring). Toasts won't work; nothing else in AltTabSucks depends on this."
        )

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    bus_name = dbus.service.BusName(BUS_NAME, bus)

    app = Gtk.Application(application_id="com.github.tomatointhesand.AltTabSucksToastApp")

    def on_activate(_app):
        toast = ToastWindow()
        ToastService(bus_name, toast, TabSearchWindow())
        app.hold()  # no "main window" of its own — stay running as a background service

    app.connect("activate", on_activate)
    app.run(None)


if __name__ == "__main__":
    main()
