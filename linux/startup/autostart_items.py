#!/usr/bin/env python3
"""
Takes the user's XDG autostart entries (~/.config/autostart/*.desktop) over into the startup
manager's startup.json, and gives them back — the Linux side of Server/StartupItems.ps1.

Taking an entry over adds it to startup.json and switches it off in the desktop's own autostart by
writing Hidden=true into its .desktop file, which both Plasma's autostart and systemd's
xdg-autostart-generator honour; the previous Hidden value (or its absence) is recorded on the item
so restore() can put it back. Only the user's own entries are taken over: /etc/xdg/autostart is
mostly the desktop's own components (Plasma, KDE Connect, polkit agent...), which have to keep
starting the desktop's way.

Paths (XDG, so tests and trial runs can point them elsewhere):
  $XDG_CONFIG_HOME/autostart/                     the entries
  $XDG_CONFIG_HOME/alttabsucks/startup.json       the startup manager's list
  $XDG_STATE_HOME/alttabsucks/startup-history.jsonl, startup-errors.log

Command line (installer.sh): autostart_items.py scan | import [--no] | init | restore
"""

import json
import os
import re
import shlex
import sys
from pathlib import Path

DESKTOP_GROUP = "[Desktop Entry]"


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def state_home() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")


def autostart_dir() -> Path:
    return config_home() / "autostart"


def config_path() -> Path:
    return config_home() / "alttabsucks" / "startup.json"


def history_path() -> Path:
    return state_home() / "alttabsucks" / "startup-history.jsonl"


def errors_path() -> Path:
    return state_home() / "alttabsucks" / "startup-errors.log"


def builtin_item() -> dict:
    """AltTabSucks itself: its server and toast daemon (systemd user services) and its KWin
    script. Ready once the server answers and the KWin script is loaded."""
    return {"name": "AltTabSucks", "builtin": "alttabsucks", "command": "", "workingDir": "", "process": "",
            "delay": 0, "afterReady": 0, "ready": "process", "enabled": 1}


def default_config() -> dict:
    return {"version": 1, "autoCloseSeconds": 5, "readyTimeoutSeconds": 30, "items": []}


# ---- .desktop files ------------------------------------------------------------------------------

def parse_desktop(text: str) -> dict:
    """The [Desktop Entry] group's keys (localized ones like Name[de] left out). Leading spaces
    are tolerated: some apps write them."""
    out, in_group = {}, False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            in_group = line == DESKTOP_GROUP
            continue
        if in_group and "=" in line:
            k, v = line.split("=", 1)
            k = k.strip()
            if "[" not in k:
                out.setdefault(k, v.strip())
    return out


def set_hidden(text: str, value) -> str:
    """The .desktop text with Hidden set to value in [Desktop Entry] (None: the key removed)."""
    lines = text.splitlines()
    group_at, in_group, hidden_at = None, False, None
    for i, raw in enumerate(lines):
        line = raw.strip()
        if line.startswith("["):
            in_group = line == DESKTOP_GROUP
            if in_group and group_at is None:
                group_at = i
            continue
        if in_group and re.match(r"Hidden\s*=", line):
            hidden_at = i
    if hidden_at is not None:
        if value is None:
            del lines[hidden_at]
        else:
            lines[hidden_at] = f"Hidden={value}"
    elif value is not None:
        if group_at is None:
            lines[0:0] = [DESKTOP_GROUP]
            group_at = 0
        lines.insert(group_at + 1, f"Hidden={value}")
    return "\n".join(lines) + "\n"


def command_from_exec(exec_line: str) -> str:
    """Exec= with its field codes (%f, %U...) dropped and %% unescaped."""
    s = re.sub(r"(?<!%)%[fFuUdDnNickvm]", "", exec_line)
    return re.sub(r"\s+", " ", s.replace("%%", "%")).strip()


def argv_of(command: str) -> list:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def process_name(command: str) -> str:
    """The name the launched app's process has: its executable's file name, past an "env VAR=x"
    prefix. "" for flatpak apps (their process is sandboxed; windowClass finds their window)."""
    argv = argv_of(command)
    if argv and os.path.basename(argv[0]) == "env":
        argv = [a for a in argv[1:] if not ("=" in a and not a.startswith("-"))]
    if not argv or os.path.basename(argv[0]) == "flatpak":
        return ""
    return os.path.basename(argv[0])


def flatpak_app_id(command: str) -> str:
    argv = argv_of(command)
    if argv and os.path.basename(argv[0]) == "flatpak" and "run" in argv:
        rest = [a for a in argv[argv.index("run") + 1:] if not a.startswith("-")]
        return rest[0] if rest else ""
    return ""


def ready_mode(command: str) -> str:
    """Apps started with a flag like this usually go straight to the tray, so they never show a
    window: for them, "ready" means their process is running. Same rule as Windows."""
    pattern = r"(?i)(^|\s)[-/]{1,2}[\w-]*(minimi[sz]ed|tray|background|silent|hidden|startup|autostart|autorun)\b"
    return "process" if re.search(pattern, command) else "window"


def applies_here(entry: dict, desktop: str) -> bool:
    """OnlyShowIn/NotShowIn against $XDG_CURRENT_DESKTOP (KDE)."""
    current = {d for d in desktop.split(":") if d}
    only = {d for d in entry.get("OnlyShowIn", "").split(";") if d}
    never = {d for d in entry.get("NotShowIn", "").split(";") if d}
    if only and not (only & current):
        return False
    return not (never & current)


def read_entries(directory: Path = None, desktop: str = None) -> list:
    """Every autostart entry in the user's directory that applies to this desktop: file, name,
    command, workingDir, process, windowClass, ready, on (it starts at logon), hidden (its raw
    Hidden value, None if it has none)."""
    directory = directory or autostart_dir()
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "KDE") if desktop is None else desktop
    out = []
    for path in sorted(directory.glob("*.desktop")) if directory.is_dir() else []:
        try:
            e = parse_desktop(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError):
            continue
        command = command_from_exec(e.get("Exec", ""))
        if not command or e.get("Type", "Application") != "Application" or not applies_here(e, desktop):
            continue
        hidden = e.get("Hidden")
        on = (hidden or "").lower() != "true" and e.get("X-GNOME-Autostart-enabled", "true").lower() != "false"
        out.append({"file": str(path), "name": e.get("Name") or path.stem, "command": command,
                    "workingDir": e.get("Path", ""), "process": process_name(command),
                    "windowClass": e.get("StartupWMClass") or flatpak_app_id(command),
                    "ready": ready_mode(command), "on": on, "hidden": hidden})
    return out


# ---- startup.json ----------------------------------------------------------------------------

def read_config(path: Path = None):
    path = path or config_path()
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def save_config(config: dict, path: Path = None):
    path = path or config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def merge(config, entries: list, take_over=True) -> dict:
    """startup.json with the built-in AltTabSucks item first, and (with take_over) every entry
    that's on added after the existing items (an entry it already has keeps its settings).
    {"config", "takeOver": the entries to switch off}. Same rules as Merge-StartupItems.
    take_over None: nothing taken over and no answer recorded, so the manager's notice still
    offers it (an existing install that got the startup manager without being asked)."""
    config = dict(config) if isinstance(config, dict) else default_config()
    items = [i for i in config.get("items") or [] if isinstance(i, dict)]
    if not any(i.get("builtin") == "alttabsucks" for i in items):
        items.insert(0, builtin_item())
    if take_over is not None:
        config["takeOver"] = take_over
    switch_off = []
    for e in entries if take_over else []:
        if not e["on"]:
            continue  # off in the desktop's autostart: the user doesn't want it
        known = next((i for i in items if (i.get("autostart") or {}).get("file") == e["file"]), None)
        if known is None:
            item = {"name": e["name"], "command": e["command"], "workingDir": e["workingDir"], "process": e["process"],
                    "delay": 1, "afterReady": 0, "ready": e["ready"], "enabled": 1,
                    "autostart": {"file": e["file"], "previous": e["hidden"]}}
            if e["windowClass"]:
                item["windowClass"] = e["windowClass"]
            items.append(item)
        else:
            known["autostart"]["previous"] = e["hidden"]
        switch_off.append(e)
    config["items"] = items
    return {"config": config, "takeOver": switch_off}


def new_entries(config_file: Path = None, directory: Path = None) -> list:
    """The entries import_items would take over now (on, not the startup manager's yet), for the
    manager's "not in this list yet" notice."""
    return merge(read_config(config_file), read_entries(directory))["takeOver"]


def import_items(take_over=True, config_file: Path = None, directory: Path = None, log=print) -> dict:
    r = merge(read_config(config_file), read_entries(directory), take_over)
    save_config(r["config"], config_file)
    for e in r["takeOver"]:
        try:
            p = Path(e["file"])
            p.write_text(set_hidden(p.read_text(encoding="utf-8"), "true"), encoding="utf-8")
            log(f"Startup manager took over: {e['name']}")
        except OSError as ex:
            log(f"Couldn't switch {e['name']} off in autostart ({ex}); it may start twice.")
    return r


def restore(config_file: Path = None, log=print):
    """Puts every entry import_items switched off back the way it was. The items stay in
    startup.json, so a reinstall takes them over again with their settings."""
    config = read_config(config_file)
    if not config:
        return
    for item in config.get("items") or []:
        a = item.get("autostart") if isinstance(item, dict) else None
        if not a or not a.get("file"):
            continue
        p = Path(a["file"])
        try:
            p.write_text(set_hidden(p.read_text(encoding="utf-8"), a.get("previous")), encoding="utf-8")
            log(f"Restored autostart entry: {item.get('name', p.name)}")
        except OSError as ex:
            log(f"Couldn't restore {p.name} ({ex}).")


def main(argv) -> int:
    action = argv[1] if len(argv) > 1 else ""
    if action == "scan":
        for e in new_entries():
            print(e["name"])
    elif action == "import":
        import_items(take_over="--no" not in argv)
    elif action == "init":  # startup.json exists, nothing decided (installer.sh restart's upgrade)
        if read_config() is None:
            import_items(take_over=None)
    elif action == "restore":
        restore()
    else:
        print("usage: autostart_items.py scan | import [--no] | init | restore", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
