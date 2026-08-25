#!/usr/bin/env python3
"""Tests for linux/server/hotkeys_generator.py."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hotkeys_generator import generate_binding_js, generate_hotkeys_js  # noqa: E402


class GenerateBindingJsTestCase(unittest.TestCase):
    def test_window_cycle_without_launch_argv(self):
        js = generate_binding_js({
            "type": "windowCycle", "title": "Cycle Browser", "key": "Ctrl+Alt+Shift+B",
            "resourceClass": "brave-browser",
        })
        self.assertIn('registerShortcut("Cycle Browser", "AltTabSucks: Cycle Browser"', js)
        self.assertIn('"Ctrl+Alt+Shift+B"', js)
        self.assertIn('manageAppWindows("brave-browser", "cycle");', js)

    def test_window_toggle_with_launch_argv(self):
        js = generate_binding_js({
            "type": "windowToggle", "title": "Toggle File Manager", "key": "Ctrl+Alt+Shift+E",
            "resourceClass": "org.kde.dolphin", "launchArgv": ["dolphin"],
        })
        self.assertIn('manageAppWindows("org.kde.dolphin", "toggle", ["dolphin"]);', js)

    def test_profile_cycle(self):
        js = generate_binding_js({
            "type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P",
            "resourceClass": "brave-browser", "profileName": "Work",
        })
        self.assertIn('cycleChromiumProfile("brave-browser", "Work");', js)

    def test_tab_focus_multiple_patterns(self):
        js = generate_binding_js({
            "type": "tabFocus", "title": "Focus Gmail", "key": "Ctrl+Alt+Shift+G",
            "resourceClass": "brave-browser", "profileName": "Personal",
            "urlPatterns": ["mail.google.com", "inbox.google.com"], "openUrl": "https://mail.google.com",
        })
        self.assertIn(
            'focusTab("brave-browser", "Personal", ["mail.google.com", "inbox.google.com"], "https://mail.google.com");',
            js,
        )

    def test_run_command(self):
        js = generate_binding_js({
            "type": "runCommand", "title": "Reload Hotkeys", "key": "Ctrl+Alt+Shift+'",
            "argv": ["/home/dab/git/alttabsucks/installer.sh", "reload-hotkeys"],
        })
        self.assertIn(
            'runCommandWithToast("Reload Hotkeys", ["/home/dab/git/alttabsucks/installer.sh", "reload-hotkeys"]);',
            js,
        )

    def test_run_command_missing_argv_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({"type": "runCommand", "title": "X", "key": "Ctrl+Alt+Shift+B"})

    def test_run_command_does_not_require_resource_class(self):
        # Unlike every other type, runCommand has no window/tab/profile to match against.
        js = generate_binding_js({
            "type": "runCommand", "title": "X", "key": "Ctrl+Alt+Shift+B", "argv": ["dolphin"],
        })
        self.assertIn('runCommandWithToast("X", ["dolphin"]);', js)

    def test_strings_with_quotes_and_backslashes_escape_safely(self):
        # Also proves generated output is at least well-formed enough that a naive brace/paren
        # balance check passes — a real JS parser isn't available in this test environment (see
        # the KWin script tests' own notes on that), so this is deliberately adversarial input
        # rather than a full syntax check.
        js = generate_binding_js({
            "type": "windowCycle", "title": 'Weird "Title" \\ here', "key": "Ctrl+Alt+Shift+B",
            "resourceClass": "brave-browser",
        })
        self.assertIn('\\"Title\\"', js)
        self.assertIn("\\\\", js)
        self.assertEqual(js.count("{"), js.count("}"))
        self.assertEqual(js.count("("), js.count(")"))

    def test_missing_title_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({"type": "windowCycle", "key": "Ctrl+Alt+Shift+B", "resourceClass": "x"})

    def test_missing_key_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({"type": "windowCycle", "title": "X", "resourceClass": "x"})

    def test_missing_resource_class_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({"type": "windowCycle", "title": "X", "key": "Ctrl+Alt+Shift+B"})

    def test_profile_cycle_missing_profile_name_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({
                "type": "profileCycle", "title": "X", "key": "Ctrl+Alt+Shift+B", "resourceClass": "x",
            })

    def test_tab_focus_missing_fields_raise(self):
        base = {"type": "tabFocus", "title": "X", "key": "Ctrl+Alt+Shift+B", "resourceClass": "x"}
        with self.assertRaises(ValueError):
            generate_binding_js(dict(base))
        with self.assertRaises(ValueError):
            generate_binding_js(dict(base, profileName="P"))
        with self.assertRaises(ValueError):
            generate_binding_js(dict(base, profileName="P", urlPatterns=["a.com"]))

    def test_unknown_type_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({
                "type": "somethingElse", "title": "X", "key": "Ctrl+Alt+Shift+B", "resourceClass": "x",
            })


class GenerateHotkeysJsTestCase(unittest.TestCase):
    def test_empty_bindings_produces_just_the_header(self):
        js = generate_hotkeys_js({"bindings": []})
        self.assertIn("Generated by the AltTabSucks hotkeys UI", js)
        self.assertNotIn("registerShortcut", js)

    def test_missing_bindings_key_treated_as_empty(self):
        js = generate_hotkeys_js({})
        self.assertNotIn("registerShortcut", js)

    def test_multiple_bindings_all_present(self):
        js = generate_hotkeys_js({"bindings": [
            {"type": "windowCycle", "title": "A", "key": "Ctrl+Alt+Shift+A", "resourceClass": "x"},
            {"type": "windowToggle", "title": "B", "key": "Ctrl+Alt+Shift+B", "resourceClass": "y"},
        ]})
        self.assertEqual(js.count("registerShortcut"), 2)
        self.assertIn('"A"', js)
        self.assertIn('"B"', js)

    def test_disabled_binding_produces_no_registershortcut(self):
        js = generate_hotkeys_js({"bindings": [
            {"type": "windowCycle", "title": "A", "key": "Ctrl+Alt+Shift+A", "resourceClass": "x", "enabled": False},
        ]})
        self.assertNotIn("registerShortcut", js)

    def test_disabled_binding_can_be_incomplete_without_raising(self):
        # A disabled binding is a draft, not something that will ever run — missing fields that
        # would otherwise raise (see GenerateBindingJsTestCase above) shouldn't block saving it.
        js = generate_hotkeys_js({"bindings": [
            {"type": "tabFocus", "title": "Draft", "enabled": False},
        ]})
        self.assertNotIn("registerShortcut", js)

    def test_disabled_binding_exempt_from_duplicate_title_check(self):
        # Only bindings that actually get emitted can collide in kglobalaccel — a disabled
        # binding sharing a title with an enabled (or another disabled) one is not a real
        # collision, since at most one of them ever calls registerShortcut.
        js = generate_hotkeys_js({"bindings": [
            {"type": "windowCycle", "title": "A", "key": "Ctrl+Alt+Shift+A", "resourceClass": "x"},
            {"type": "windowCycle", "title": "A", "key": "Ctrl+Alt+Shift+B", "resourceClass": "y", "enabled": False},
        ]})
        self.assertEqual(js.count("registerShortcut"), 1)

    def test_missing_or_true_enabled_is_treated_as_enabled(self):
        js = generate_hotkeys_js({"bindings": [
            {"type": "windowCycle", "title": "A", "key": "Ctrl+Alt+Shift+A", "resourceClass": "x"},
            {"type": "windowCycle", "title": "B", "key": "Ctrl+Alt+Shift+B", "resourceClass": "y", "enabled": True},
        ]})
        self.assertEqual(js.count("registerShortcut"), 2)

    def test_duplicate_title_raises(self):
        # registerShortcut's title is the kglobalaccel action ID — two bindings sharing one
        # silently collide in KWin (confirmed live: only one action ever gets registered, and
        # only one binding's key ends up doing anything). Catch it at generation time instead.
        with self.assertRaises(ValueError):
            generate_hotkeys_js({"bindings": [
                {"type": "windowCycle", "title": "A", "key": "Ctrl+Alt+Shift+A", "resourceClass": "x"},
                {"type": "windowToggle", "title": "A", "key": "Ctrl+Alt+Shift+B", "resourceClass": "y"},
            ]})


if __name__ == "__main__":
    unittest.main()
