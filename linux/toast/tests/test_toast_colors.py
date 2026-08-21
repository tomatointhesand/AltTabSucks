#!/usr/bin/env python3
"""Tests for linux/toast/toast_colors.py. Deliberately doesn't import alttabsucks_toast.py itself
— that needs GTK4/gtk4-layer-shell/dbus-python installed, none of which this suite should require
to run (same reasoning as dbus_bridge.py being untested directly: it needs a live session)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from toast_colors import ROYGBIV, ToastState, next_color  # noqa: E402


class NextColorTestCase(unittest.TestCase):
    def test_not_visible_and_not_recent_uses_requested_color(self):
        state = ToastState()
        color = next_color(state, "#1A2A3A", now_ms=10_000, currently_visible=False)
        self.assertEqual(color, "#1A2A3A")

    def test_currently_visible_advances_to_rainbow_even_if_not_recent(self):
        state = ToastState()
        color = next_color(state, "#1A2A3A", now_ms=10_000, currently_visible=True)
        self.assertIn(color, ROYGBIV)
        self.assertNotEqual(color, "#1A2A3A")

    def test_fired_within_recency_window_advances_to_rainbow(self):
        state = ToastState()
        state.last_tick_ms = 1000
        color = next_color(state, "#1A2A3A", now_ms=1300, currently_visible=False)  # 300ms < 400ms window
        self.assertIn(color, ROYGBIV)

    def test_fired_outside_recency_window_resets_to_requested_color(self):
        state = ToastState()
        state.last_tick_ms = 1000
        color = next_color(state, "#1A2A3A", now_ms=1500, currently_visible=False)  # 500ms > 400ms window
        self.assertEqual(color, "#1A2A3A")
        self.assertEqual(state.color_idx, 0)

    def test_first_rainbow_step_is_red(self):
        # AHK arrays are 1-indexed: Mod(0, 13) + 1 = 1, and _toastROYGBIV[1] is the *first*
        # element — no off-by-one. Locking in the resulting color sequence's starting point.
        state = ToastState()
        color = next_color(state, "#1A2A3A", now_ms=1000, currently_visible=True)
        self.assertEqual(color, ROYGBIV[0])  # "red"

    def test_rainbow_cycles_through_full_sequence_and_wraps(self):
        state = ToastState()
        seen = [next_color(state, "#1A2A3A", now_ms=1000 + i, currently_visible=True)
                for i in range(len(ROYGBIV) + 2)]
        # Wraps back to the same color it started the cycle on after a full lap.
        self.assertEqual(seen[0], seen[len(ROYGBIV)])
        self.assertEqual(len(set(seen[:len(ROYGBIV)])), len(ROYGBIV))  # one full lap = every color once

    def test_rapid_burst_then_gap_then_new_burst_starts_fresh(self):
        state = ToastState()
        first = next_color(state, "#1A2A3A", now_ms=1000, currently_visible=True)
        # Long gap, not visible anymore — sequence should reset.
        after_gap = next_color(state, "#1A2A3A", now_ms=5000, currently_visible=False)
        self.assertEqual(after_gap, "#1A2A3A")
        # Next rapid press after the reset starts the rainbow over from the same first color.
        restarted = next_color(state, "#1A2A3A", now_ms=5100, currently_visible=True)
        self.assertEqual(restarted, first)


if __name__ == "__main__":
    unittest.main()
