#!/usr/bin/env python3
"""
Offers the starter hotkeys (hotkeys.starter.json) to hotkeys.js, each once: the whole set to a new
hotkeys.js (created here, with just the header, when it doesn't exist yet), and to an existing one
the entries marked "upgrade" (new features). Each is added if its key is free, added switched off
if it isn't (see hotkeys_generator.add_starter_hotkeys). Placeholders: __PROFILE__ (the browser's
default profile), __DOWNLOADS__ (the XDG Downloads folder, as ~/...), __REPO_ROOT__ (this clone).
An entry with "ifInstalled": "<command>" is skipped when that command isn't on PATH (the starter
editor and terminal are KDE's Kate and Konsole). installer.sh runs this before every KWin script install,
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


def downloads_dir() -> str:
    """The XDG Downloads folder, written ~/... when it's under the home folder."""
    home = str(Path.home())
    path = ""
    try:
        path = subprocess.run(["xdg-user-dir", "DOWNLOAD"], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    if not path or path.rstrip("/") == home:  # xdg-user-dir answers $HOME for an unset folder
        return "~/Downloads"
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def load_starter(path: Path, profile: str, downloads: str = "~/Downloads",
                 repo_root: str = str(HERE.parents[1]), installed=shutil.which) -> list:
    text = path.read_text(encoding="utf-8")
    for name, value in (("__PROFILE__", profile), ("__DOWNLOADS__", downloads), ("__REPO_ROOT__", repo_root)):
        text = text.replace(name, json.dumps(value)[1:-1])
    bindings = json.loads(text).get("bindings") or []
    out = []
    for b in bindings:
        need = b.pop("ifInstalled", None) if isinstance(b, dict) else None
        if not need or installed(need):
            out.append(b)
    return out


def main(hotkeys_path: Path = HOTKEYS_JS_PATH, starter_path: Path = STARTER_PATH) -> int:
    if not starter_path.exists():
        return 0
    new_file = not hotkeys_path.exists()
    try:
        import config
    except ImportError:
        config = None
    import profile_discovery
    profiles = profile_discovery.discover_chromium_profiles(getattr(config, "CHROMIUM_USERDATA", ""))
    resource_class = getattr(config, "CHROMIUM_RESOURCE_CLASS", "")
    text = hotkeys_generator.HEADER if new_file else hotkeys_path.read_text(encoding="utf-8")
    starter = load_starter(starter_path, default_profile(profiles), downloads_dir())
    r = hotkeys_generator.add_starter_hotkeys(text, starter, resource_class)
    if new_file or r["text"] != text:
        if not new_file:
            hotkeys_path.with_name(hotkeys_path.name + ".bak").write_text(text, encoding="utf-8")
        hotkeys_path.write_text(r["text"], encoding="utf-8")
    if new_file:
        print(f"Created {hotkeys_path} with {len(r['added']) + len(r['switchedOff'])} suggested hotkeys.")
    notice = hotkeys_generator.format_starter_notice(r)
    if notice:
        print(notice)
        if not sys.stdout.isatty() and shutil.which("notify-send"):
            subprocess.run(["notify-send", "--app-name=AltTabSucks", "AltTabSucks", notice], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
