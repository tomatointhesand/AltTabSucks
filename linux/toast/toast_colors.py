#!/usr/bin/env python3
"""
Pure rainbow-cycling logic for the toast daemon (alttabsucks_toast.py), split out into its own
zero-dependency module so it's testable without GTK4/gtk4-layer-shell/dbus-python installed — same
reasoning as hotkeys_generator.py being separate from alttabsucks_server.py: the parts that need a
live session (D-Bus there, a Wayland display + compositor here) aren't unit-tested at all (see
dbus_bridge.py's module docstring), so keeping the parts that *can* be tested free of those imports
means the test suite doesn't need any of that installed to run.
"""

DEFAULT_BG = "#1A2A3A"       # same navy as ShowSetupToast/ShowChoiceDialog in lib/toast.ahk
SHADOW_COLOR = "#471313"     # matches ShowProfileToast's drop-shadow text layer color
DEFAULT_DURATION_MS = 500    # matches ShowProfileToast's SetTimer(..., -500)

# Transcribed directly from lib/toast.ahk's _toastROYGBIV (same 13 colors, same order).
ROYGBIV = [
    "#CC0000", "#E53300", "#FF6600", "#FF9900", "#FFCC00", "#80B300", "#009900",
    "#006F66", "#0044CC", "#2622A7", "#4B0082", "#6B00C1", "#8B00FF",
]

# Mirrors ShowProfileToast's recency check: without it, the rainbow would reset to the base color
# whenever a toast happens to expire (500ms) in the gap between two rapid-fire presses.
RAINBOW_CONTINUE_WINDOW_MS = 400


class ToastState:
    def __init__(self):
        self.color_idx = 0       # 1-based on purpose — see next_color()'s docstring
        self.last_tick_ms = 0


def next_color(state, requested_hex, now_ms, currently_visible):
    """Pure port of ShowProfileToast's rainbow logic. AHK: `_toastColorIdx := Mod(_toastColorIdx,
    Length) + 1` starting from a 0 global, then `_toastROYGBIV[_toastColorIdx]` — AHK arrays are
    1-indexed, so the first rainbow step (Mod(0,13)+1 = 1) correctly lands on the *first* color
    (red), no off-by-one. Reproduced here with the same 1-based color_idx and a `- 1` at the
    Python (0-indexed) list access, rather than rewriting the arithmetic to be 0-based
    throughout, for a closer line-by-line match to the AHK original."""
    color = requested_hex
    if currently_visible or (now_ms - state.last_tick_ms < RAINBOW_CONTINUE_WINDOW_MS):
        state.color_idx = (state.color_idx % len(ROYGBIV)) + 1
        color = ROYGBIV[state.color_idx - 1]
    else:
        state.color_idx = 0  # gap in sequence — next rapid burst starts fresh
    state.last_tick_ms = now_ms
    return color
