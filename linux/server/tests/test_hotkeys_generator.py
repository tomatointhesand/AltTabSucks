#!/usr/bin/env python3
"""Tests for linux/server/hotkeys_generator.py."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hotkeys_generator import (  # noqa: E402
    DISABLED_MARKER, HEADER, LEGACY_HEADER, fold_legacy_hotkeys_json, generate_binding_js,
    parse_hotkeys_js, rewrite_hotkeys_js,
)


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
        # No resourceClass on the binding at all — profileCycle/tabFocus/splitTab/mergeTabs source
        # it from the browser_resource_class parameter instead (see the module docstring for why).
        # No launchProfileName either — defaults to profileName itself (see the "all profiles"
        # tests below for when it's actually required to differ).
        js = generate_binding_js({
            "type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P",
            "profileName": "Work",
        }, browser_resource_class="brave-browser")
        self.assertIn('cycleChromiumProfile("brave-browser", "Work", "Work");', js)

    def test_profile_cycle_all_profiles(self):
        js = generate_binding_js({
            "type": "profileCycle", "title": "Cycle Any", "key": "Ctrl+Alt+Shift+P",
            "profileName": "__all__", "launchProfileName": "Personal",
        }, browser_resource_class="brave-browser")
        self.assertIn('cycleChromiumProfile("brave-browser", "__all__", "Personal");', js)

    def test_profile_cycle_all_profiles_missing_launch_profile_raises(self):
        # "__all__" alone doesn't say which profile to launch if nothing's open at all — unlike
        # a normal single profile, there's no sensible default to fall back to.
        with self.assertRaises(ValueError) as cm:
            generate_binding_js({
                "type": "profileCycle", "title": "Cycle Any", "key": "Ctrl+Alt+Shift+P",
                "profileName": "__all__",
            }, browser_resource_class="brave-browser")
        self.assertIn("launch profile", str(cm.exception))

    def test_profile_cycle_explicit_launch_profile_overrides_default(self):
        # A launchProfileName that genuinely differs from profileName (deliberately set while
        # profileName was "__all__", say, then profileName changed back) is honored as-is, not
        # silently forced to match profileName.
        js = generate_binding_js({
            "type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P",
            "profileName": "Work", "launchProfileName": "Personal",
        }, browser_resource_class="brave-browser")
        self.assertIn('cycleChromiumProfile("brave-browser", "Work", "Personal");', js)

    def test_split_tab(self):
        js = generate_binding_js({
            "type": "splitTab", "title": "Split Tab", "key": "Alt+X", "profileName": "Personal",
        }, browser_resource_class="brave-browser")
        self.assertIn('splitFocusedTab("brave-browser", "Personal");', js)

    def test_merge_tabs(self):
        js = generate_binding_js({
            "type": "mergeTabs", "title": "Merge Windows", "key": "Alt+Z", "profileName": "Personal",
        }, browser_resource_class="brave-browser")
        self.assertIn('mergeFocusedWindow("brave-browser", "Personal");', js)

    def test_split_tab_missing_profile_name_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({
                "type": "splitTab", "title": "X", "key": "Alt+X",
            }, browser_resource_class="brave-browser")

    def test_merge_tabs_missing_browser_resource_class_raises(self):
        with self.assertRaises(ValueError) as cm:
            generate_binding_js({
                "type": "mergeTabs", "title": "X", "key": "Alt+Z", "profileName": "Personal",
            })  # no browser_resource_class passed — defaults to ""
        self.assertIn("./installer.sh configure", str(cm.exception))

    def test_browser_scoped_binding_ignores_its_own_leftover_resourceclass_field(self):
        # A binding saved before this refactor may still carry a stale resourceClass key —
        # harmless dead data now, never read for these four types. browser_resource_class always
        # wins, confirming it's not silently falling back to the binding's own (wrong) value.
        js = generate_binding_js({
            "type": "profileCycle", "title": "Cycle Work", "key": "Ctrl+Alt+Shift+P",
            "profileName": "Work", "resourceClass": "some-stale-value",
        }, browser_resource_class="brave-browser")
        self.assertIn('cycleChromiumProfile("brave-browser", "Work", "Work");', js)
        self.assertNotIn("some-stale-value", js)

    def test_tab_focus_multiple_patterns(self):
        js = generate_binding_js({
            "type": "tabFocus", "title": "Focus Gmail", "key": "Ctrl+Alt+Shift+G",
            "profileName": "Personal",
            "urlPatterns": ["mail.google.com", "inbox.google.com"], "openUrl": "https://mail.google.com",
        }, browser_resource_class="brave-browser")
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
        # browser_resource_class passed so this actually exercises the profileName check, not the
        # (also-ValueError) "no browser configured" one above it.
        with self.assertRaises(ValueError):
            generate_binding_js({
                "type": "profileCycle", "title": "X", "key": "Ctrl+Alt+Shift+B",
            }, browser_resource_class="brave-browser")

    def test_tab_focus_missing_fields_raise(self):
        base = {"type": "tabFocus", "title": "X", "key": "Ctrl+Alt+Shift+B"}
        with self.assertRaises(ValueError):
            generate_binding_js(dict(base), browser_resource_class="brave-browser")
        with self.assertRaises(ValueError):
            generate_binding_js(dict(base, profileName="P"), browser_resource_class="brave-browser")
        with self.assertRaises(ValueError):
            generate_binding_js(dict(base, profileName="P", urlPatterns=["a.com"]), browser_resource_class="brave-browser")

    def test_tab_focus_missing_browser_resource_class_raises(self):
        with self.assertRaises(ValueError) as cm:
            generate_binding_js({
                "type": "tabFocus", "title": "X", "key": "Ctrl+Alt+Shift+B", "profileName": "P",
                "urlPatterns": ["a.com"], "openUrl": "https://a.com",
            })  # no browser_resource_class passed
        self.assertIn("./installer.sh configure", str(cm.exception))

    def test_unknown_type_raises(self):
        with self.assertRaises(ValueError):
            generate_binding_js({
                "type": "somethingElse", "title": "X", "key": "Ctrl+Alt+Shift+B", "resourceClass": "x",
            })


def _stmt(title, key, call):
    return (f'registerShortcut("{title}", "AltTabSucks: {title}",\n'
            f'    "{key}", function () {{ {call} }});')


SAMPLE = "\n".join([
    HEADER,
    "// my own helper, not a hotkey",
    "function hello() { print('hi'); }",
    "",
    _stmt("gmail", "Ctrl+Alt+Shift+G", 'focusTab("brave-browser", "Personal", ["mail.google.com"], "https://mail.google.com");'),
    "",
    _stmt("Kate", "Ctrl+Alt+Shift+N", 'manageAppWindows("org.kde.kate", "cycle", ["kate"]);'),
    "",
    _stmt("Hello", "Ctrl+Alt+Shift+H", "hello();"),
    "",
    _stmt("youtube", "Ctrl+Alt+Shift+Y", 'focusTab("brave-browser", "Personal", ["youtube.com"], "https://youtube.com");'),
    "",
    _stmt("Gone", "Ctrl+Alt+Shift+Q", 'focusTab("brave-browser", "Personal", [], "https://x.com");'),
    "",
])


def _by_title(bindings):
    return {b["title"]: b for b in bindings}


class ParseHotkeysJsTestCase(unittest.TestCase):
    def test_recognized_statements_become_bindings(self):
        parsed = parse_hotkeys_js(SAMPLE)
        self.assertEqual([b["title"] for b in parsed["bindings"]], ["gmail", "Kate", "youtube"])
        gmail = _by_title(parsed["bindings"])["gmail"]
        self.assertEqual(gmail["type"], "tabFocus")
        self.assertEqual(gmail["profileName"], "Personal")
        self.assertEqual(gmail["urlPatterns"], ["mail.google.com"])
        self.assertTrue(gmail["enabled"])
        self.assertEqual(_by_title(parsed["bindings"])["Kate"]["launchArgv"], ["kate"])

    def test_calls_to_other_functions_are_left_alone(self):
        self.assertNotIn("Hello", _by_title(parse_hotkeys_js(SAMPLE)["bindings"]))

    def test_recognized_but_invalid_statement_is_reported_with_its_line(self):
        invalid = parse_hotkeys_js(SAMPLE)["invalid"]
        self.assertEqual([i["title"] for i in invalid], ["Gone"])
        self.assertIn("urlPatterns", invalid[0]["reason"])
        self.assertEqual(SAMPLE.split("\n")[invalid[0]["line"] - 1].strip(), invalid[0]["text"])

    def test_arrow_functions_and_single_quotes(self):
        js = "registerShortcut('A', 'AltTabSucks: A', 'Alt+A', () => manageAppWindows('x', 'toggle'));\n"
        (b,) = parse_hotkeys_js(js)["bindings"]
        self.assertEqual((b["type"], b["resourceClass"], b["key"]), ("windowToggle", "x", "Alt+A"))

    def test_disabled_statement(self):
        js = "\n".join(DISABLED_MARKER + l for l in _stmt("K", "Alt+K", 'manageAppWindows("k", "cycle");').split("\n"))
        (b,) = parse_hotkeys_js(js)["bindings"]
        self.assertFalse(b["enabled"])

    def test_real_generated_file_round_trips(self):
        legacy = LEGACY_HEADER + SAMPLE[len(HEADER):]
        parsed = parse_hotkeys_js(legacy)
        out = rewrite_hotkeys_js(legacy, parsed["bindings"], "brave-browser")["text"]
        self.assertTrue(out.startswith(HEADER), "the legacy 'generated from hotkeys.json' header is replaced")
        self.assertEqual(out[len(HEADER):], rewrite_hotkeys_js(SAMPLE, parse_hotkeys_js(SAMPLE)["bindings"], "brave-browser")["text"][len(HEADER):])


class RewriteHotkeysJsTestCase(unittest.TestCase):
    def setUp(self):
        self.bindings = parse_hotkeys_js(SAMPLE)["bindings"]

    def rewrite(self, bindings, browser="brave-browser"):
        return rewrite_hotkeys_js(SAMPLE, bindings, browser)

    def test_unchanged_save_only_removes_invalid_statements(self):
        r = self.rewrite(self.bindings)
        self.assertEqual(r["text"], SAMPLE.replace(
            "\n" + _stmt("Gone", "Ctrl+Alt+Shift+Q", 'focusTab("brave-browser", "Personal", [], "https://x.com");') + "\n", ""))
        self.assertEqual([d["title"] for d in r["dropped"]], ["Gone"])
        self.assertEqual(r["saved"], 3)

    def test_hand_written_text_is_kept(self):
        text = self.rewrite([])["text"]
        self.assertIn("function hello()", text)
        self.assertIn('"Hello"', text)
        self.assertNotIn("gmail", text)

    def test_edit_replaces_the_statement_in_place(self):
        self.bindings[0]["openUrl"] = "https://gmail.com"
        lines = self.rewrite(self.bindings)["text"].split("\n")
        self.assertIn('"gmail"', lines[7])
        self.assertIn("https://gmail.com", lines[8])

    def test_reorder_within_a_section_swaps_statements(self):
        gmail, kate, yt = self.bindings
        text = self.rewrite([yt, kate, gmail])["text"]
        self.assertLess(text.index('"youtube"'), text.index('"Kate"'))
        self.assertLess(text.index('"Kate"'), text.index('"gmail"'))

    def test_new_binding_goes_after_the_last_of_its_section(self):
        new = {"type": "tabFocus", "title": "maps", "key": "Ctrl+Alt+Shift+M", "profileName": "Personal",
               "urlPatterns": ["google.com/maps"], "openUrl": "https://google.com/maps"}
        text = self.rewrite(self.bindings + [new])["text"]
        self.assertLess(text.index('"youtube"'), text.index('"maps"'))
        self.assertIn('\n\nregisterShortcut("maps"', text)

    def test_new_binding_of_a_new_section_goes_at_the_end(self):
        new = {"type": "runCommand", "title": "Reload", "key": "Ctrl+Alt+Shift+'", "argv": ["./installer.sh"]}
        text = self.rewrite(self.bindings + [new])["text"]
        self.assertTrue(text.endswith('runCommandWithToast("Reload", ["./installer.sh"]); });\n'))

    def test_duplicated_row_does_not_steal_its_originals_statement(self):
        copy = dict(self.bindings[1], title="Kate 2", key="Ctrl+Alt+Shift+J")  # same slot
        text = self.rewrite(self.bindings + [copy])["text"]
        self.assertIn('"Kate"', text)
        self.assertIn('"Kate 2"', text)

    def test_invalid_posted_binding_is_dropped_and_reported(self):
        r = self.rewrite(self.bindings + [{"type": "tabFocus", "title": "Broken", "key": "Alt+B"}])
        self.assertNotIn("Broken", r["text"])
        self.assertIn("Broken", [d["title"] for d in r["dropped"]])

    def test_unknown_type_is_dropped(self):
        r = self.rewrite(self.bindings + [{"type": "openFolder", "title": "Dl", "key": "Alt+D"}])
        self.assertIn("unknown type", [d for d in r["dropped"] if d["title"] == "Dl"][0]["reason"])

    def test_duplicate_title_or_key_is_dropped(self):
        same_title = dict(self.bindings[1], key="Alt+1"); same_title.pop("slot")
        same_key = {"type": "windowCycle", "title": "Other", "key": "Ctrl+Shift+Alt+N", "resourceClass": "o"}
        clash_hand_written = {"type": "windowCycle", "title": "H", "key": "Ctrl+Alt+Shift+H", "resourceClass": "h"}
        r = self.rewrite(self.bindings + [same_title, same_key, clash_hand_written])
        self.assertEqual([d["title"] for d in r["dropped"]], ["Kate", "Other", "H", "Gone"])

    def test_disabled_binding_is_written_commented_out_and_exempt_from_duplicates(self):
        copy = dict(self.bindings[1], enabled=False); copy.pop("slot")
        r = self.rewrite(self.bindings + [copy])
        self.assertIn(DISABLED_MARKER + 'registerShortcut("Kate"', r["text"])
        self.assertEqual(len(parse_hotkeys_js(r["text"])["bindings"]), 4)

    def test_browser_scoped_bindings_use_the_configured_browser(self):
        self.assertIn('focusTab("google-chrome"', self.rewrite(self.bindings, "google-chrome")["text"])

    def test_no_browser_configured_keeps_the_one_the_file_names(self):
        self.assertIn('focusTab("brave-browser"', self.rewrite(self.bindings, "")["text"])

    def test_empty_file_gets_the_header(self):
        new = {"type": "windowCycle", "title": "A", "key": "Alt+A", "resourceClass": "a"}
        text = rewrite_hotkeys_js("", [new])["text"]
        self.assertTrue(text.startswith(HEADER))
        self.assertEqual(len(parse_hotkeys_js(text)["bindings"]), 1)


class FoldLegacyHotkeysJsonTestCase(unittest.TestCase):
    def test_json_bindings_replace_the_generated_statements_in_order(self):
        legacy = LEGACY_HEADER + "\n" + _stmt("Kate", "Alt+K", 'manageAppWindows("kate", "cycle");') + "\n"
        json_bindings = [
            {"type": "windowCycle", "title": "Kate", "key": "Alt+K", "resourceClass": "kate"},
            {"type": "windowCycle", "title": "Off", "key": "Alt+O", "resourceClass": "o", "enabled": False},
            {"type": "tabFocus", "title": "Draft", "enabled": False},
        ]
        r = fold_legacy_hotkeys_json(legacy, json_bindings)
        self.assertTrue(r["text"].startswith(HEADER))
        self.assertEqual([(b["title"], b["enabled"]) for b in parse_hotkeys_js(r["text"])["bindings"]],
                         [("Kate", True), ("Off", False)])
        self.assertEqual([d["title"] for d in r["dropped"]], ["Draft"])


if __name__ == "__main__":
    unittest.main()
