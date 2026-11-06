import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import startup_runner as R  # noqa: E402


class FakeProbes(R.Probes):
    def __init__(self):
        self.launched = []
        self.processes = set()   # process names "running"
        self.windows = set()     # process names with a window
        self.missing = set()     # commands that fail to launch
        self.builtin = False

    def launch(self, item):
        if item.get("command") in self.missing:
            raise OSError(f"{item['command']}: not found")
        self.launched.append(item["name"])
        return len(self.launched)

    def already_running(self, item):
        return item.get("process") in self.processes and item["name"] not in self.launched

    def process_seen(self, item, handle):
        return item.get("process") in self.processes

    def window_seen(self, item, handle):
        return item.get("process") in self.windows

    def builtin_ready(self):
        return self.builtin


def item(name, delay=0, **kw):
    return {"name": name, "command": name.lower(), "process": name.lower(), "delay": delay,
            "afterReady": 0, "ready": "window", "enabled": 1, **kw}


class RunnerTestCase(unittest.TestCase):
    def setUp(self):
        self.t = 0
        self.p = FakeProbes()
        self.items = [{"name": "AltTabSucks", "builtin": "alttabsucks", "delay": 0, "ready": "process", "enabled": 1},
                      item("Kate", 0), item("Tray", 1, ready="process"), item("Later", 2, afterReady=1)]
        self.r = R.Runner(self.items, {"readyTimeoutSeconds": 3}, self.p, lambda: self.t)
        self.r.start()

    def at(self, ms):
        self.t = ms
        return self.r.tick()

    def status(self):
        return [s["status"] for s in self.r.states]

    def test_a_run(self):
        self.at(0)
        self.assertEqual(self.p.launched, ["AltTabSucks", "Kate"])
        self.assertEqual(self.status(), ["running", "launched", "pending", "pending"])
        self.p.builtin = True
        self.p.processes.add("kate")
        self.at(500)
        self.assertEqual(self.status()[:2], ["ready", "running"])
        self.p.windows.add("kate")
        self.at(900)
        self.assertEqual(self.r.states[1]["readyMs"], 900)
        self.at(1000)  # Tray: 1 s after Kate's launch
        self.assertEqual(self.p.launched[-1], "Tray")
        self.p.processes.add("tray")
        self.at(1100)
        self.assertEqual(self.r.states[2]["status"], "ready")
        self.assertFalse(self.at(3000))  # Later: 2 s after Tray was ready
        self.assertEqual(self.p.launched[-1], "Tray")
        self.at(3100)
        self.assertEqual(self.p.launched[-1], "Later")
        self.p.processes.add("later")
        self.p.windows.add("later")
        self.assertTrue(self.at(3200))
        self.assertTrue(self.r.finished)

    def test_timeouts_are_still_watched(self):
        self.items[:] = [item("Slow")]
        self.r = R.Runner(self.items, {"readyTimeoutSeconds": 3}, self.p, lambda: self.t)
        self.r.start()
        self.at(0)
        self.assertTrue(self.at(3001))
        self.assertEqual(self.r.states[0]["status"], "noprocess")
        self.p.processes.add("slow")
        self.at(5000)
        self.assertEqual(self.r.states[0]["status"], "nowindow")
        self.p.windows.add("slow")
        self.at(9000)
        st = self.r.states[0]
        self.assertEqual((st["status"], st["readyMs"], st["doneMs"]), ("ready", 9000, 3001))

    def test_already_running_and_failed(self):
        self.p.processes.add("kate")
        self.p.missing.add("tray")
        self.at(0)
        self.at(1000)
        self.assertEqual(self.r.states[1]["status"], "already")
        self.assertEqual(self.r.states[2]["status"], "failed")
        self.assertIn("not found", self.r.states[2]["error"])

    def test_nothing_to_watch(self):
        self.items[:] = [{"name": "Script", "command": "x", "process": "", "delay": 0, "enabled": 1}]
        self.r = R.Runner(self.items, {}, self.p, lambda: self.t)
        self.r.start()
        self.assertTrue(self.at(0))
        self.assertEqual(self.r.states[0]["status"], "noprocess")

    def test_editing_during_a_run(self):
        self.r.set_enabled(3, False)
        self.assertEqual(self.r.states[3]["status"], "off")
        self.r.insert(1)
        self.items.insert(1, item("New"))
        self.assertEqual(self.r.states[1]["status"], "off")
        self.r.swap(1, 2)
        self.items[1], self.items[2] = self.items[2], self.items[1]
        self.at(0)
        self.assertNotIn("New", self.p.launched)
        self.assertIn("Kate", self.p.launched)


if __name__ == "__main__":
    unittest.main()
