import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import startup_logic as L  # noqa: E402


def item(name, delay=0, after_ready=0, **kw):
    return {"name": name, "delay": delay, "afterReady": after_ready, "enabled": 1, **kw}


def state(status, **kw):
    return {"status": status, **kw}


class PlanTestCase(unittest.TestCase):
    def setUp(self):
        self.items = [item("A", 0), item("B", 2), item("C", 1.5)]

    def test_delays_count_from_the_previous_launch(self):
        p = L.plan(self.items, [state("pending")] * 3)
        self.assertEqual([p[i]["at"] for i in range(3)], [0, 2000, 3500])

    def test_a_launched_item_counts_from_its_real_launch(self):
        p = L.plan(self.items, [state("ready", launchMs=300, doneMs=900), state("pending"), state("pending")])
        self.assertEqual((p[1]["at"], p[2]["at"]), (2300, 3800))

    def test_off_items_are_skipped(self):
        p = L.plan(self.items, [state("pending"), state("off"), state("pending")])
        self.assertNotIn(1, p)
        self.assertEqual(p[2]["at"], 1500)

    def test_after_ready_waits_for_the_previous_item(self):
        self.items[1]["afterReady"] = 1
        p = L.plan(self.items, [state("running", launchMs=0), state("pending"), state("pending")])
        self.assertEqual((p[1]["at"], p[1]["after"], p[1]["why"]), (None, 0, "ready"))
        self.assertEqual((p[2]["at"], p[2]["after"], p[2]["why"]), (None, 1, "launch"))
        self.assertEqual(L.status_text(self.items, 1, state("pending"), p[1], 500), "after A is ready")
        self.assertEqual(L.status_text(self.items, 2, state("pending"), p[2], 500), "after B launches")
        p = L.plan(self.items, [state("ready", launchMs=300, readyMs=4000, doneMs=4000), state("pending"), state("pending")])
        self.assertEqual(p[1]["at"], 6000)

    def test_skip_delays(self):
        self.items[1]["afterReady"] = 1
        p = L.plan(self.items, [state("running", launchMs=0), state("pending"), state("pending")], skip_delays=True)
        self.assertEqual((p[1]["at"], p[2]["at"]), (0, 0))


class StatusTestCase(unittest.TestCase):
    items = [item("A"), item("B", process="b"), {"name": "AltTabSucks", "builtin": "alttabsucks", "process": ""},
             item("Off", enabled=0)]

    def text(self, i, st, planned=None, now=0):
        return L.status_text(self.items, i, st, planned, now)

    def test_countdown(self):
        self.assertEqual(self.text(1, state("pending"), {"at": 2000, "after": None, "why": ""}, 750), "in 1.3 s")
        self.assertEqual(self.text(1, state("pending"), {"at": 2000, "after": None, "why": ""}, 2100), "launching")

    def test_done_states(self):
        self.assertEqual(self.text(1, state("ready")), L.CHECK)
        self.assertEqual(self.text(1, state("already")), L.CHECK + " already running")
        self.assertEqual(self.text(1, state("noprocess")), "no b seen yet")
        self.assertEqual(self.text(0, state("noprocess")), L.CHECK + " launched")
        self.assertEqual(self.text(1, state("failed", error="not found")), "failed: not found")
        self.assertEqual(self.text(2, state("running")) + " | " + self.text(2, state("nowindow")),
                         "waiting for AltTabSucks | AltTabSucks not answering yet")

    def test_off(self):
        self.assertEqual(self.text(3, state("off")), "off")
        self.assertEqual(self.text(0, state("off")), "")


class OutcomeTestCase(unittest.TestCase):
    def test_outcomes(self):
        b = item("B", process="b")
        self.assertEqual(L.outcome(b, state("ready")) + L.outcome(b, state("already")), "okok")
        self.assertEqual(L.outcome(item("A"), state("noprocess")), "ok")
        self.assertEqual(L.outcome(b, state("noprocess")) + L.outcome(b, state("nowindow")), "warnwarn")
        self.assertEqual(L.outcome(b, state("failed")), "error")
        self.assertEqual(L.outcome(b, state("running")) + L.outcome(b, state("pending")), "")

    def test_all_up(self):
        two = [item("A"), item("B")]
        self.assertTrue(L.all_up(two, [state("ready"), state("off")]))
        self.assertFalse(L.all_up(two, [state("ready"), state("nowindow")]))
        self.assertFalse(L.all_up(two, [state("ready"), state("running")]))
        self.assertTrue(L.all_done([state("ready"), state("nowindow"), state("off")]))
        self.assertFalse(L.all_done([state("ready"), state("running")]))


class HistoryTestCase(unittest.TestCase):
    def setUp(self):
        self.items = [item("A", 0), item("B", 2), item("C", 1.5)]
        self.states = [state("ready", launchMs=10, processMs=40, readyMs=900, doneMs=900),
                       state("nowindow", launchMs=2900, processMs=3000, doneMs=32900),
                       state("already", launchMs=2900, doneMs=2900)]

    def test_row(self):
        row = L.history_row(self.items, self.states, "logon", "2026-10-26T08:00:00", 41000, 1200)
        self.assertEqual(row["allReadyMs"], 32900)
        self.assertEqual(json.dumps(row["items"][0], sort_keys=True, separators=(",", ":")),
                         '{"afterReady":0,"delayMs":0,"launchMs":10,"name":"A","processMs":40,"ready":"window","readyMs":900,"status":"ready"}')
        self.assertNotIn("readyMs", row["items"][1])
        self.assertNotIn("\n", json.dumps(row))

    def test_table(self):
        line = json.dumps(L.history_row(self.items, self.states, "logon", "2026-10-26T08:00:00", 41000, 1200))
        older = json.loads(line)
        older["time"] = "2026-10-25T08:00:00"
        older["items"][0]["name"] = "Old app"
        t = L.history_table([older, json.loads(line)], ["C", "A", "B"])
        self.assertEqual(t["header"][4:], ["C", "A", "B", "Old app"])
        newest = t["rows"][0]
        self.assertEqual(newest[0], "2026-10-26 08:00:00")
        self.assertEqual(newest[2] + " | " + newest[3], "1.2 s | 32.9 s")
        self.assertEqual(newest[5], "0.9 s (0.9 s)")
        self.assertEqual(newest[6], "3.0 s (0.1 s) no window")
        self.assertEqual(newest[4], "already running")
        self.assertEqual(t["rows"][1][5] + " | " + t["rows"][1][7], " | 0.9 s (0.9 s)")


if __name__ == "__main__":
    unittest.main()
