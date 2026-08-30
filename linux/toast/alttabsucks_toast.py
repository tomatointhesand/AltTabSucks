#!/usr/bin/env python3
"""
Toast overlay daemon — Linux port of lib/toast.ahk's ShowProfileToast (SampleTitlebarColor and
the setup/choice-dialog toasts are NOT ported here; see the porting checklist for what's in vs.
out of scope). A colored, borderless, momentary text overlay centered on the window a hotkey just
activated — window/profile cycling, tab focus, etc.

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

import sys
import time
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
            "window { background-color: transparent; }\n"
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
            # See show()'s comment on why the window node itself has to be fully transparent
            # and the actual visible rounded box has to be the #toast-box child instead.
            "window { background-color: transparent; }\n"
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


class ToastService(dbus.service.Object):
    def __init__(self, bus_name, toast):
        super().__init__(bus_name, OBJECT_PATH)
        self._toast = toast
        self._state = ToastState()

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
        ToastService(bus_name, toast)
        app.hold()  # no "main window" of its own — stay running as a background service

    app.connect("activate", on_activate)
    app.run(None)


if __name__ == "__main__":
    main()
