#!/usr/bin/env python3
"""
Offers the starter hotkeys for new features (hotkeys.starter.json) to an existing hotkeys.js,
each once: added if its key is free, added switched off if it isn't (see
hotkeys_generator.add_starter_hotkeys). installer.sh runs this before every KWin script install,
so a `git pull` plus a restart (Ctrl+Alt+Shift+') or reinstall picks up new ones. Prints what it
did, and also shows it as a desktop notification when not run from a terminal (the restart
hotkey). Windows counterpart: POST /init-hotkeys at AltTabSucks.ahk startup.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import hotkeys_generator  # noqa: E402

STARTER_PATH = HERE / "hotkeys.starter.json"
HOTKEYS_JS_PATH = HERE.parents[1] / "linux" / "kwin" / "alttabsucks" / "contents" / "code" / "hotkeys.js"


def default_profile(profile_dirs: dict) -> str:
    """The profile in the "Default" directory, else the first one, else ""."""
    for name, directory in profile_dirs.items():
        if directory == "Default":
            return name
    return next(iter(profile_dirs), "")


def load_starter(path: Path, profile: str) -> list:
    text = path.read_text(encoding="utf-8").replace("__PROFILE__", json.dumps(profile)[1:-1])
    return json.loads(text).get("bindings") or []


def main(hotkeys_path: Path = HOTKEYS_JS_PATH, starter_path: Path = STARTER_PATH) -> int:
    if not hotkeys_path.exists() or not starter_path.exists():
        return 0
    try:
        import config
    except ImportError:
        config = None
    import profile_discovery
    profiles = profile_discovery.discover_chromium_profiles(getattr(config, "CHROMIUM_USERDATA", ""))
    resource_class = getattr(config, "CHROMIUM_RESOURCE_CLASS", "")
    text = hotkeys_path.read_text(encoding="utf-8")
    r = hotkeys_generator.add_starter_hotkeys(text, load_starter(starter_path, default_profile(profiles)), resource_class)
    if r["text"] != text:
        hotkeys_path.with_name(hotkeys_path.name + ".bak").write_text(text, encoding="utf-8")
        hotkeys_path.write_text(r["text"], encoding="utf-8")
    notice = hotkeys_generator.format_starter_notice(r)
    if notice:
        print(notice)
        if not sys.stdout.isatty() and shutil.which("notify-send"):
            subprocess.run(["notify-send", "--app-name=AltTabSucks", "AltTabSucks", notice], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
