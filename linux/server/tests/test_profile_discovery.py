#!/usr/bin/env python3
"""Tests for linux/server/profile_discovery.py."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from profile_discovery import discover_chromium_profiles  # noqa: E402


class ProfileDiscoveryTestCase(unittest.TestCase):
    def test_empty_user_data_dir_returns_nothing(self):
        self.assertEqual(discover_chromium_profiles(""), {})

    def test_nonexistent_dir_returns_nothing(self):
        self.assertEqual(discover_chromium_profiles("/no/such/path"), {})

    def test_parses_info_cache_from_local_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            local_state = {
                "profile": {
                    "info_cache": {
                        "Default": {"name": "Personal"},
                        "Profile 1": {"name": "Work"},
                    }
                }
            }
            (Path(tmp) / "Local State").write_text(json.dumps(local_state), encoding="utf-8")
            result = discover_chromium_profiles(tmp)
            self.assertEqual(result, {"Personal": "Default", "Work": "Profile 1"})

    def test_info_cache_entries_without_a_name_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            local_state = {"profile": {"info_cache": {"Default": {}, "Profile 1": {"name": "Work"}}}}
            (Path(tmp) / "Local State").write_text(json.dumps(local_state), encoding="utf-8")
            result = discover_chromium_profiles(tmp)
            self.assertEqual(result, {"Work": "Profile 1"})

    def test_malformed_json_falls_through_to_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Local State").write_text("not json", encoding="utf-8")
            self.assertEqual(discover_chromium_profiles(tmp), {})

    def test_missing_local_state_falls_through_to_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(discover_chromium_profiles(tmp), {})

    def test_fallback_scans_default_and_profile_n_dirs_when_info_cache_empty(self):
        # e.g. a browser with no info_cache section at all (Opera, per the AHK version's comment)
        with tempfile.TemporaryDirectory() as tmp:
            local_state = {"profile": {}}
            (Path(tmp) / "Local State").write_text(json.dumps(local_state), encoding="utf-8")
            (Path(tmp) / "Default").mkdir()
            (Path(tmp) / "Profile 1").mkdir()
            (Path(tmp) / "Not A Profile Dir").mkdir()  # must not match
            result = discover_chromium_profiles(tmp)
            self.assertEqual(result, {"Default": "Default", "Profile 1": "Profile 1"})

    def test_fallback_to_bare_default_when_no_local_state_but_default_dir_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Default").mkdir()
            result = discover_chromium_profiles(tmp)
            self.assertEqual(result, {"Default": "Default"})


if __name__ == "__main__":
    unittest.main()
