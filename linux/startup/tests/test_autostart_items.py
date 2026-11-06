import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import autostart_items as A  # noqa: E402

DISCORD = "[Desktop Entry]\nType=Application\nName=Discord\nExec=/home/me/.config/discord/Discord\nHidden=false\n"
SURFSHARK = "[Desktop Entry]\nName=surfshark\nExec=/opt/Surfshark/surfshark --hidden\n"
ANTIMICROX = ("[Desktop Entry]\nType=Application\nName=AntiMicroX\nExec=antimicrox --show %f\n\n"
              "[Desktop Action tray]\nName=Open in system tray only\nExec=antimicrox --tray\n")
BITWARDEN = "[Desktop Entry]\n  Type=Application\n  Name=Bitwarden\n  Exec=bitwarden-desktop\n"
OFF = "[Desktop Entry]\nName=Off app\nExec=offapp\nHidden=true\n"
GNOME_ONLY = "[Desktop Entry]\nName=Gnome thing\nExec=gthing\nOnlyShowIn=GNOME;\n"
FLATPAK = "[Desktop Entry]\nName=Signal\nExec=/usr/bin/flatpak run --branch=stable org.signal.Signal --start-in-tray\n"


class DesktopFileTestCase(unittest.TestCase):
    def test_parse_keeps_to_the_main_group(self):
        e = A.parse_desktop(ANTIMICROX)
        self.assertEqual((e["Name"], e["Exec"]), ("AntiMicroX", "antimicrox --show %f"))
        self.assertEqual(A.parse_desktop(BITWARDEN)["Exec"], "bitwarden-desktop")

    def test_command_drops_field_codes(self):
        self.assertEqual(A.command_from_exec("antimicrox --show %f"), "antimicrox --show")
        self.assertEqual(A.command_from_exec("app --pct 100%% %U"), "app --pct 100%")

    def test_process_and_ready_mode(self):
        self.assertEqual(A.process_name("/opt/Surfshark/surfshark --hidden"), "surfshark")
        self.assertEqual(A.process_name("env FOO=1 BAR=2 /usr/bin/thing -x"), "thing")
        self.assertEqual(A.process_name("flatpak run org.signal.Signal"), "")
        self.assertEqual(A.flatpak_app_id("/usr/bin/flatpak run --branch=stable org.signal.Signal --x"), "org.signal.Signal")
        self.assertEqual(A.ready_mode("/opt/Surfshark/surfshark --hidden"), "process")
        self.assertEqual(A.ready_mode("antimicrox --tray"), "process")
        self.assertEqual(A.ready_mode("discord"), "window")

    def test_set_hidden(self):
        self.assertIn("Hidden=true", A.set_hidden(DISCORD, "true"))
        self.assertNotIn("Hidden=false", A.set_hidden(DISCORD, "true"))
        added = A.set_hidden(SURFSHARK, "true")
        self.assertEqual(added.splitlines()[:2], ["[Desktop Entry]", "Hidden=true"])
        self.assertNotIn("Hidden", A.set_hidden(added, None))
        # Only the main group: an action's keys are left alone.
        self.assertEqual(A.set_hidden(ANTIMICROX, "true").count("Hidden="), 1)


class TakeOverTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.dir = root / "autostart"
        self.dir.mkdir()
        for name, text in [("discord", DISCORD), ("surfshark", SURFSHARK), ("antimicrox", ANTIMICROX),
                           ("bitwarden", BITWARDEN), ("off", OFF), ("gnome", GNOME_ONLY), ("signal", FLATPAK)]:
            (self.dir / f"{name}.desktop").write_text(text)
        self.config = root / "alttabsucks" / "startup.json"
        self.log = []

    def tearDown(self):
        self.tmp.cleanup()

    def entries(self):
        return A.read_entries(self.dir, "KDE")

    def test_read_entries(self):
        by = {e["name"]: e for e in self.entries()}
        self.assertNotIn("Gnome thing", by)
        self.assertFalse(by["Off app"]["on"])
        self.assertTrue(by["Discord"]["on"])
        self.assertEqual((by["Signal"]["process"], by["Signal"]["windowClass"], by["Signal"]["ready"]),
                         ("", "org.signal.Signal", "process"))

    def test_import_takes_over_and_restore_gives_back(self):
        r = A.import_items(True, self.config, self.dir, log=self.log.append)
        items = r["config"]["items"]
        self.assertEqual(items[0]["builtin"], "alttabsucks")
        names = [i["name"] for i in items[1:]]
        self.assertEqual(sorted(names), ["AntiMicroX", "Bitwarden", "Discord", "Signal", "surfshark"])
        for name in ("discord", "surfshark", "bitwarden"):
            self.assertTrue(A.parse_desktop((self.dir / f"{name}.desktop").read_text())["Hidden"] == "true", name)
        self.assertEqual(A.new_entries(self.config, self.dir), [])
        self.assertEqual(A.read_config(self.config)["takeOver"], True)

        A.restore(self.config, log=self.log.append)
        self.assertEqual(A.parse_desktop((self.dir / "discord.desktop").read_text())["Hidden"], "false")
        self.assertNotIn("Hidden", A.parse_desktop((self.dir / "surfshark.desktop").read_text()))
        self.assertEqual(A.parse_desktop((self.dir / "off.desktop").read_text())["Hidden"], "true")

        # Reinstalling takes them over again, keeping their settings.
        cfg = A.read_config(self.config)
        next(i for i in cfg["items"] if i["name"] == "Discord")["delay"] = 7
        A.save_config(cfg, self.config)
        r = A.import_items(True, self.config, self.dir, log=self.log.append)
        self.assertEqual(next(i for i in r["config"]["items"] if i["name"] == "Discord")["delay"], 7)
        self.assertEqual(len(r["config"]["items"]), 6)
        self.assertEqual(A.parse_desktop((self.dir / "discord.desktop").read_text())["Hidden"], "true")

    def test_undecided_records_no_answer(self):
        r = A.import_items(None, self.config, self.dir, log=self.log.append)
        self.assertNotIn("takeOver", r["config"])
        self.assertEqual(len(r["config"]["items"]), 1)
        self.assertEqual(len(A.new_entries(self.config, self.dir)), 5)

    def test_declining_leaves_autostart_alone(self):
        r = A.import_items(False, self.config, self.dir, log=self.log.append)
        self.assertEqual([i.get("builtin") for i in r["config"]["items"]], ["alttabsucks"])
        self.assertEqual(r["config"]["takeOver"], False)
        self.assertEqual(A.parse_desktop((self.dir / "discord.desktop").read_text())["Hidden"], "false")
        self.assertEqual(len(A.new_entries(self.config, self.dir)), 5)


if __name__ == "__main__":
    unittest.main()
