#!/usr/bin/env python3
"""Tests for linux/server/tab_search.py."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tab_search import open_tab_items, query_words, rank, search  # noqa: E402


def tab(tid, title, url, last, active=False):
    return {"id": tid, "title": title, "url": url[:30], "fullUrl": url, "lastAccessed": last, "active": active}


TABS = {
    "Personal": [
        {"id": 1, "focused": True, "tabs": [
            tab(11, "Inbox - Gmail", "https://mail.google.com/mail/u/0/#inbox", 500, active=True),
            tab(12, "YouTube", "https://www.youtube.com/watch?v=abc", 400),
            tab(13, "Sailing forecast", "https://windy.com/sailing", 300),
        ]},
        {"id": 2, "focused": False, "tabs": [
            tab(21, "GitHub - alttabsucks", "https://github.com/tomatointhesand/AltTabSucks", 450, active=True),
        ]},
    ],
}
NO_BOOKMARKS = lambda words: []  # noqa: E731


class QueryTestCase(unittest.TestCase):
    def test_words_are_lowercased_and_split(self):
        self.assertEqual(query_words("  Gmail  INBOX "), ["gmail", "inbox"])
        self.assertEqual(query_words(""), [])

    def test_all_words_must_match_title_or_url_in_any_order(self):
        items = [{"title": "Inbox - Gmail", "url": "https://mail.google.com"}]
        self.assertEqual(len(rank(items, ["gmail", "inbox"])), 1)
        self.assertEqual(len(rank(items, ["inbox", "google"])), 1)  # one in title, one in URL
        self.assertEqual(rank(items, ["gmail", "calendar"]), [])

    def test_title_matches_rank_above_url_only_matches(self):
        items = [{"title": "Something", "url": "https://sail.example"}, {"title": "Sail plans", "url": "https://x.example"}]
        self.assertEqual([i["title"] for i in rank(items, ["sail"])], ["Sail plans", "Something"])

    def test_then_most_recent_first(self):
        items = [{"title": "a sail", "t": 1}, {"title": "b sail", "t": 3}, {"title": "c sail", "t": 2}]
        self.assertEqual([i["title"] for i in rank(items, ["sail"], recency_key="t")], ["b sail", "c sail", "a sail"])

    def test_limit(self):
        self.assertEqual(len(rank([{"title": "x"}] * 80, [], limit=50)), 50)


class OpenTabsTestCase(unittest.TestCase):
    def test_most_recently_used_first_with_the_current_tab_last(self):
        items = open_tab_items(TABS, {"Personal"})
        self.assertEqual([t["tabId"] for t in items], [21, 12, 13, 11])

    def test_uses_the_full_url(self):
        self.assertEqual(open_tab_items(TABS, {"Personal"})[1]["url"], "https://www.youtube.com/watch?v=abc")

    def test_closed_profiles_tabs_are_left_out(self):
        self.assertEqual(open_tab_items(TABS, set()), [])


class SearchTestCase(unittest.TestCase):
    RECENT = {"Personal": [
        {"sessionId": "s1", "title": "Old sailing article", "url": "https://news.example/sail", "closedAt": 100},
        {"sessionId": "s2", "title": "Recipe", "url": "https://food.example/pasta", "closedAt": 200},
    ]}

    def bookmarks(self, calls):
        def search_bookmarks(words):
            calls.append(words)
            return [{"kind": "bookmark", "profile": "Personal", "id": "b1", "title": "Pasta recipes", "url": "https://food.example/", "live": True}]
        return search_bookmarks

    def test_open_tabs_win_and_nothing_else_is_searched(self):
        calls = []
        r = search("sail", TABS, self.RECENT, {"Personal"}, self.bookmarks(calls))
        self.assertEqual((r["category"], [i["tabId"] for i in r["items"]]), ("tabs", [13]))
        self.assertEqual(calls, [], "bookmarks aren't searched when an open tab matches")

    def test_recently_closed_only_when_no_open_tab_matches(self):
        r = search("recipe", TABS, self.RECENT, {"Personal"}, self.bookmarks([]))
        self.assertEqual(r["category"], "recent")
        self.assertEqual([i["sessionId"] for i in r["items"]], ["s2"])
        self.assertTrue(r["items"][0]["live"])

    def test_bookmarks_only_when_neither_matches(self):
        calls = []
        r = search("pasta recipes", TABS, self.RECENT, {"Personal"}, self.bookmarks(calls))
        self.assertEqual((r["category"], r["items"][0]["id"]), ("bookmarks", "b1"))
        self.assertEqual(calls, [["pasta", "recipes"]])

    def test_empty_query_lists_open_tabs(self):
        r = search("", TABS, self.RECENT, {"Personal"}, NO_BOOKMARKS)
        self.assertEqual((r["category"], len(r["items"])), ("tabs", 4))

    def test_browser_closed_falls_back_to_recently_closed(self):
        r = search("", TABS, self.RECENT, set(), NO_BOOKMARKS)
        self.assertEqual(r["category"], "recent")
        self.assertEqual([i["sessionId"] for i in r["items"]], ["s2", "s1"])  # most recently closed first
        self.assertFalse(r["items"][0]["live"])

    def test_profile_label_only_with_several_profiles_open(self):
        self.assertFalse(search("", TABS, {}, {"Personal"}, NO_BOOKMARKS)["showProfile"])
        two = dict(TABS, Work=[{"id": 9, "focused": False, "tabs": [tab(91, "Jira", "https://jira.example", 600)]}])
        r = search("", two, {}, {"Personal", "Work"}, NO_BOOKMARKS)
        self.assertTrue(r["showProfile"])
        self.assertFalse(search("", two, {}, {"Personal"}, NO_BOOKMARKS)["showProfile"], "Work isn't open")

    def test_nothing_matches(self):
        self.assertEqual(search("zzz", TABS, self.RECENT, {"Personal"}, NO_BOOKMARKS)["category"], "")


if __name__ == "__main__":
    unittest.main()
