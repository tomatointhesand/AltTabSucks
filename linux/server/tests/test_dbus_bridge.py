"""Unit tests for the pure matching helper in dbus_bridge.py. Only url_matches_pattern is tested
here — the Bridge class itself needs a live D-Bus session bus (dbus.service.Object.__init__
requires a real bus_name) so it's exercised live rather than under this suite; see the porting
checklist."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dbus_bridge import url_matches_pattern


class TestUrlMatchesPattern(unittest.TestCase):
    # ---- the reported bug: subdomain must not be swallowed --------------------------------
    def test_bare_domain_does_not_match_subdomain(self):
        self.assertFalse(url_matches_pattern("https://music.youtube.com/watch", "youtube.com"))

    def test_subdomain_pattern_matches_its_own_subdomain(self):
        self.assertTrue(url_matches_pattern("https://music.youtube.com/watch", "music.youtube.com"))

    def test_subdomain_pattern_does_not_match_bare_domain(self):
        self.assertFalse(url_matches_pattern("https://youtube.com/watch", "music.youtube.com"))

    # ---- www. tolerance ---------------------------------------------------------------------
    def test_www_prefix_is_tolerated(self):
        self.assertTrue(url_matches_pattern("https://www.youtube.com/watch", "youtube.com"))

    def test_bare_domain_matches_bare_domain(self):
        self.assertTrue(url_matches_pattern("https://youtube.com/watch", "youtube.com"))

    # ---- boundary after the pattern --------------------------------------------------------
    def test_unrelated_domain_with_pattern_as_prefix_does_not_match(self):
        self.assertFalse(url_matches_pattern("https://youtube.company.com/x", "youtube.com"))

    def test_exact_match_with_no_path(self):
        self.assertTrue(url_matches_pattern("https://youtube.com", "youtube.com"))

    def test_port_boundary_matches(self):
        self.assertTrue(url_matches_pattern("http://localhost:9876/hotkeys-ui", "localhost:9876/hotkeys-ui"))

    def test_query_boundary_matches(self):
        self.assertTrue(url_matches_pattern("https://youtube.com?v=1", "youtube.com"))

    # ---- path-scoped patterns, mirroring hotkeys.js's "google.com/maps" -------------------
    def test_path_scoped_pattern_matches(self):
        self.assertTrue(url_matches_pattern("https://www.google.com/maps/@1,2,3z", "google.com/maps"))

    def test_path_scoped_pattern_does_not_match_other_path(self):
        self.assertFalse(url_matches_pattern("https://www.google.com/search?q=x", "google.com/maps"))

    # ---- misc -------------------------------------------------------------------------------
    def test_missing_url_does_not_match(self):
        self.assertFalse(url_matches_pattern(None, "youtube.com"))

    def test_pattern_with_scheme_still_matches(self):
        self.assertTrue(url_matches_pattern("https://music.youtube.com/watch", "https://music.youtube.com"))


if __name__ == "__main__":
    unittest.main()
