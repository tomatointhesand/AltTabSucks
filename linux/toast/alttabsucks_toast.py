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
from gi.repository import Gdk, Gtk, Gtk4LayerShell, GLib  # noqa: E402

import dbus  # noqa: E402
import dbus.mainloop.glib  # noqa: E402
import dbus.service  # noqa: E402

BUS_NAME = "com.github.tomatointhesand.AltTabSucksToast"
OBJECT_PATH = "/com/github/tomatointhesand/AltTabSucksToast"
INTERFACE = "com.github.tomatointhesand.AltTabSucksToast"


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

        self.label = Gtk.Label()
        self.label.set_name("toast-label")
        self.win.set_child(self.label)

        self._css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self._css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self._hide_source_id = None

    def show(self, text, bg_hex, win_x, win_y, win_w, win_h, duration_ms):
        self.label.set_text(text.upper())
        self._css.load_from_data((
            "window { background-color: %s; border-radius: 14px; }\n"
            "#toast-label {\n"
            "  color: white; font-weight: 800; font-size: 24px; font-family: monospace;\n"
            "  text-shadow: 2px 3px 0 %s;\n"
            "  padding: 20px 32px;\n"
            "}\n" % (bg_hex, SHADOW_COLOR)
        ).encode("utf-8"))

        monitor = self._find_monitor(win_x, win_y)
        if monitor is not None:
            Gtk4LayerShell.set_monitor(self.win, monitor)
            mon_geo = monitor.get_geometry()
            mon_x, mon_y = mon_geo.x, mon_geo.y
        else:
            mon_x = mon_y = 0

        self.win.set_visible(True)  # needed before measure() has a display to lay out against
        _, natural_w, _, _ = self.label.measure(Gtk.Orientation.HORIZONTAL, -1)
        _, natural_h, _, _ = self.label.measure(Gtk.Orientation.VERTICAL, -1)
        est_w = natural_w + 64  # + the CSS padding above (32px * 2)
        est_h = natural_h + 40  # + the CSS padding above (20px * 2)

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
