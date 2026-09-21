#!/usr/bin/env python3
"""Tests for linux/server/launch_command_suggester.py."""

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from launch_command_suggester import (  # noqa: E402
    DesktopEntry,
    parse_desktop_entry,
    suggest_launch_command,
)


class ParseDesktopEntryTestCase(unittest.TestCase):
    def test_parses_name_exec_startup_wm_class(self):
        entry = parse_desktop_entry(
            "[Desktop Entry]\nName=Kate\nExec=kate -b %U\nStartupWMClass=kate\n"
        )
        self.assertEqual(entry.name, "Kate")
        self.assertEqual(entry.argv, ["kate", "-b"])
        self.assertEqual(entry.startup_wm_class, "kate")

    def test_strips_field_codes(self):
        entry = parse_desktop_entry("[Desktop Entry]\nName=X\nExec=discord --url -- %u\n")
        self.assertEqual(entry.argv, ["discord", "--url", "--"])

    def test_missing_startup_wm_class_is_empty_string(self):
        entry = parse_desktop_entry("[Desktop Entry]\nName=X\nExec=x\n")
        self.assertEqual(entry.startup_wm_class, "")

    def test_only_reads_the_main_desktop_entry_section(self):
        # steam.desktop's own real shape: several [Desktop Action ...] blocks, each with its own
        # Exec/Name for a specific action — only the main [Desktop Entry]'s fields should count.
        text = (
            "[Desktop Entry]\n"
            "Name=Steam\n"
            "Exec=/usr/bin/steam %U\n"
            "Actions=Store;\n"
            "\n"
            "[Desktop Action Store]\n"
            "Name=Store\n"
            "Exec=/usr/bin/steam steam://store\n"
        )
        entry = parse_desktop_entry(text)
        self.assertEqual(entry.name, "Steam")
        self.assertEqual(entry.argv, ["/usr/bin/steam"])

    def test_hidden_true_returns_none(self):
        self.assertIsNone(parse_desktop_entry("[Desktop Entry]\nName=X\nExec=x\nHidden=true\n"))

    def test_no_display_true_is_not_treated_as_hidden(self):
        # Deliberately different from Hidden=true — see the module's own docstring for why.
        entry = parse_desktop_entry("[Desktop Entry]\nName=X\nExec=x\nNoDisplay=true\n")
        self.assertIsNotNone(entry)
        self.assertTrue(entry.no_display)

    def test_no_display_defaults_false(self):
        entry = parse_desktop_entry("[Desktop Entry]\nName=X\nExec=x\n")
        self.assertFalse(entry.no_display)

    def test_missing_exec_returns_none(self):
        self.assertIsNone(parse_desktop_entry("[Desktop Entry]\nName=X\n"))

    def test_no_desktop_entry_section_returns_none(self):
        self.assertIsNone(parse_desktop_entry("[Desktop Action Foo]\nExec=x\n"))

    def test_ignores_comments_and_blank_lines(self):
        entry = parse_desktop_entry("[Desktop Entry]\n# a comment\n\nName=X\nExec=x\n")
        self.assertEqual(entry.name, "X")

    def test_malformed_quoting_returns_none_not_raises(self):
        self.assertIsNone(parse_desktop_entry('[Desktop Entry]\nName=X\nExec="unterminated\n'))

    def test_first_occurrence_of_each_key_wins(self):
        # A real-world file shouldn't repeat these within one [Desktop Entry] block, but staying
        # deterministic (not crashing, not silently taking the last one) is cheap insurance.
        entry = parse_desktop_entry("[Desktop Entry]\nName=First\nName=Second\nExec=x\n")
        self.assertEqual(entry.name, "First")


class SuggestLaunchCommandTestCase(unittest.TestCase):
    def test_empty_resource_class_returns_none(self):
        self.assertIsNone(suggest_launch_command("", [DesktopEntry("X", ["x"], "x")]))

    def test_no_entries_returns_none(self):
        self.assertIsNone(suggest_launch_command("kate", []))

    def test_exact_startup_wm_class_match(self):
        entries = [DesktopEntry("Kate", ["kate", "-b"], "kate")]
        self.assertEqual(suggest_launch_command("kate", entries), ["kate", "-b"])

    def test_startup_wm_class_match_is_case_insensitive(self):
        entries = [DesktopEntry("Discord", ["discord"], "Discord")]
        self.assertEqual(suggest_launch_command("discord", entries), ["discord"])

    def test_reversed_domain_resource_class_matches_binary_name_last_segment(self):
        # The reported real-world case: org.kde.kate's own .desktop declares
        # StartupWMClass=kate, not StartupWMClass=org.kde.kate — the exact-match pass above can't
        # find it, but the last-dot-segment pass does.
        entries = [DesktopEntry("Kate", ["kate", "-b"], "kate")]
        self.assertEqual(suggest_launch_command("org.kde.kate", entries), ["kate", "-b"])

    def test_binary_name_prefix_match_both_directions(self):
        # "Bitwarden" -> "bitwarden" is a prefix of the real Exec binary "bitwarden-desktop".
        entries = [DesktopEntry("Bitwarden", ["bitwarden-desktop"], "")]
        self.assertEqual(suggest_launch_command("Bitwarden", entries), ["bitwarden-desktop"])
        # "com.shellyorg.shelly" -> "shelly" is a prefix of "shelly-ui".
        entries = [DesktopEntry("Shelly", ["shelly-ui"], "")]
        self.assertEqual(suggest_launch_command("com.shellyorg.shelly", entries), ["shelly-ui"])

    def test_short_segment_does_not_loosely_prefix_match(self):
        # A 2-character last segment shouldn't fuzzy-match an unrelated binary just because one
        # happens to start with the other — only the (still attempted) exact-equality check does.
        entries = [DesktopEntry("Something Else", ["xyz-something-unrelated"], "")]
        self.assertIsNone(suggest_launch_command("com.example.xy", entries))

    def test_exact_binary_name_match_ignores_short_segment_guard(self):
        # The length guard is only for the *prefix* half of the check — an exact match should
        # still work even for a short resourceClass.
        entries = [DesktopEntry("X", ["xy"], "")]
        self.assertEqual(suggest_launch_command("com.example.xy", entries), ["xy"])

    def test_binary_path_is_stripped_before_comparing(self):
        entries = [DesktopEntry("Steam", ["/usr/bin/steam"], "")]
        self.assertEqual(suggest_launch_command("steam", entries), ["/usr/bin/steam"])

    def test_startup_wm_class_pass_wins_over_binary_name_pass(self):
        # Two candidates; only the first (StartupWMClass match) should be returned even though
        # both would satisfy the fallback pass too.
        entries = [
            DesktopEntry("Wrong binary-name-only match", ["kate-other"], ""),
            DesktopEntry("Right StartupWMClass match", ["kate"], "org.kde.kate"),
        ]
        self.assertEqual(suggest_launch_command("org.kde.kate", entries), ["kate"])

    def test_no_match_returns_none(self):
        entries = [DesktopEntry("Unrelated", ["totally-different-app"], "totally-different-app")]
        self.assertIsNone(suggest_launch_command("com.shellyorg.shelly", entries))

    def test_first_matching_entry_wins_on_ties(self):
        entries = [
            DesktopEntry("First", ["kate-first"], "kate"),
            DesktopEntry("Second", ["kate-second"], "kate"),
        ]
        self.assertEqual(suggest_launch_command("kate", entries), ["kate-first"])

    def test_binary_name_pass_prefers_fewest_argv_tokens(self):
        # The reported real case: Steam auto-generates one .desktop shortcut per installed game,
        # each sharing the exact same binary name as the real steam.desktop entry — a plain
        # first-match-wins over the fuzzy pass previously landed on a specific game shortcut
        # (Half-Life.desktop's Exec=steam steam://rungameid/70) instead of the actual "launch
        # Steam" entry, purely because it happened to sort first. No StartupWMClass involved on
        # either side, so this exercises the binary-name pass specifically, not pass 1.
        game_shortcut = DesktopEntry("Half-Life", ["steam", "steam://rungameid/70"], "")
        real_launcher = DesktopEntry("Steam", ["/usr/bin/steam"], "")
        self.assertEqual(
            suggest_launch_command("steam", [game_shortcut, real_launcher]), ["/usr/bin/steam"]
        )
        # Order in the input list shouldn't matter — ranking, not first-match-wins.
        self.assertEqual(
            suggest_launch_command("steam", [real_launcher, game_shortcut]), ["/usr/bin/steam"]
        )

    def test_binary_name_pass_prefers_no_display_false_on_argv_length_tie(self):
        # The other reported real case: Shelly's real app (shelly-ui) and its separate background
        # notifications helper (shelly-notifications) both resolve to a bare one-token argv —
        # tied on argv length, so this is what actually has to break the tie. No StartupWMClass on
        # either side here either.
        helper = DesktopEntry("Shelly Notifications", ["shelly-notifications"], "", no_display=True)
        real_app = DesktopEntry("Shelly", ["shelly-ui"], "", no_display=False)
        self.assertEqual(
            suggest_launch_command("com.shellyorg.shelly", [helper, real_app]), ["shelly-ui"]
        )
        self.assertEqual(
            suggest_launch_command("com.shellyorg.shelly", [real_app, helper]), ["shelly-ui"]
        )

    def test_binary_name_pass_falls_back_to_scan_order_on_full_tie(self):
        # Same argv length, same no_display — nothing left to rank on but scan order.
        entries = [
            DesktopEntry("First", ["kate-first"], ""),
            DesktopEntry("Second", ["kate-second"], ""),
        ]
        self.assertEqual(suggest_launch_command("kate", entries), ["kate-first"])


if __name__ == "__main__":
    unittest.main()
