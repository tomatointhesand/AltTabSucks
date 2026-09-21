#!/usr/bin/env python3
"""
Suggests a launch command (argv) for a given window resourceClass by scanning .desktop files in
the standard XDG application directories — the same mechanism every Linux app launcher/dock/menu
already relies on to know how to start an app, used here instead of requiring a user to already
know (or go look up) the right binary name/flags for a windowCycle/windowToggle hotkey binding's
"launch if not running" field. Feeds GET /suggest-launch-command (see alttabsucks_server.py),
called by shared/hotkeys-ui.html once a resourceClass field is filled in.

Best-effort and inherently fuzzy, not guaranteed correct — a resourceClass and a .desktop entry's
own declared StartupWMClass frequently just don't agree, a real, well-known Linux desktop
ecosystem inconsistency, not something specific to this codebase (confirmed live on this exact
machine: org.kde.kate.desktop declares StartupWMClass=kate, but Kate's real live window
resourceClass is org.kde.kate — this project's own README already calls that exact reversed-
domain-vs-binary-name mismatch out as the single most common hotkey failure mode, just hitting a
different field this time). So this tries more than one signal, in priority order, and returns
the first reasonably-confident match rather than promising correctness — the caller always
surfaces a suggestion as a normal, still-editable field value, never something silently trusted
the way a resourceClass typed by hand isn't either.
"""

import os
import shlex
from pathlib import Path

# Standard freedesktop.org Desktop Entry Spec field codes — %f/%F/%u/%U etc. get substituted by
# whatever actually launched the entry (a file path, a URL, ...) at real invocation time; none of
# them make sense as a literal argv token for a "start this app fresh" hotkey with nothing to hand
# it, so they're stripped rather than passed through as garbage command-line text.
_FIELD_CODES = ("%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k", "%v", "%m")


def _xdg_desktop_dirs():
    """XDG data directories to scan for .desktop files, most-preferred first. Reads
    XDG_DATA_HOME/XDG_DATA_DIRS when set (transparently covers Flatpak/Snap-exported entries
    whenever the session's own XDG_DATA_DIRS already includes them, no special-casing needed) but
    falls back to the standard hardcoded locations when they're not — confirmed empirically both
    env vars are simply unset in this server's actual systemd --user environment on this machine,
    the same kind of environment-doesn't-propagate-the-way-you'd-hope gap this project has already
    hit more than once (see the porting checklist's graphical-session.target entries). Flatpak's
    own export directories are added unconditionally on top, regardless of XDG_DATA_DIRS, for the
    same robustness reason rather than trusting the env var alone to carry them."""
    home = Path(os.path.expanduser("~"))
    data_home = os.environ.get("XDG_DATA_HOME") or str(home / ".local" / "share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    dirs = [Path(data_home)] + [Path(p) for p in data_dirs.split(":") if p]
    dirs += [
        home / ".local" / "share" / "flatpak" / "exports" / "share",
        Path("/var/lib/flatpak/exports/share"),
    ]
    seen = set()
    result = []
    for d in dirs:
        app_dir = d / "applications"
        if app_dir not in seen:
            seen.add(app_dir)
            result.append(app_dir)
    return result


class DesktopEntry:
    __slots__ = ("name", "argv", "startup_wm_class", "no_display")

    def __init__(self, name, argv, startup_wm_class, no_display=False):
        self.name = name
        self.argv = argv
        self.startup_wm_class = startup_wm_class
        self.no_display = no_display


def _strip_field_codes(exec_value):
    for code in _FIELD_CODES:
        exec_value = exec_value.replace(code, "")
    return exec_value.replace("%%", "%")


def parse_desktop_entry(text):
    """Parses just the [Desktop Entry] section's Name/Exec/StartupWMClass out of a .desktop
    file's raw text — pulled out as its own function (mirrors normalize_resource_classes/
    url_matches_pattern's own reasoning elsewhere in this codebase) so it's unit-testable without
    touching the real filesystem. Deliberately stops at the first following [...] section header
    (a file like steam.desktop has several [Desktop Action ...] blocks, each with its own
    Exec=/Name= for a specific action like "Store"/"Big Picture" — only the main entry's own
    fields are what a fresh, ordinary launch should use). Returns None if there's no usable Exec
    line, or the entry is Hidden=true (the spec's own "this file has been deleted" convention —
    unambiguous, worth honoring outright). NoDisplay=true is deliberately NOT excluded the same
    way — plenty of legitimately-launchable entries are hidden from menus without being any less
    launchable — but IS recorded on the returned entry (DesktopEntry.no_display), since it turned
    out to matter for ranking, not filtering: confirmed live, a real background helper
    (com.shellyorg.shelly-notifications.desktop, NoDisplay=true) shared enough of its binary name
    with the actual app it accompanies (shelly-notifications vs shelly-ui) to tie on every other
    signal suggest_launch_command checks — NoDisplay is what correctly tells those two apart."""
    name = None
    exec_line = None
    startup_wm_class = None
    no_display = False
    in_main_section = False
    seen_main_section = False

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            if line == "[Desktop Entry]":
                in_main_section = True
                seen_main_section = True
            else:
                in_main_section = False
            continue
        if not in_main_section:
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if key == "Hidden" and value.lower() == "true":
            return None
        elif key == "NoDisplay" and value.lower() == "true":
            no_display = True
        elif key == "Name" and name is None:
            name = value
        elif key == "Exec" and exec_line is None:
            exec_line = value
        elif key == "StartupWMClass":
            startup_wm_class = value

    if not seen_main_section or not exec_line:
        return None
    try:
        argv = shlex.split(_strip_field_codes(exec_line))
    except ValueError:
        # Genuinely malformed quoting in a real .desktop file found in the wild — skip rather
        # than crash the whole scan over one bad entry.
        return None
    if not argv:
        return None
    return DesktopEntry(name or "", argv, startup_wm_class or "", no_display)


def load_desktop_entries(dirs=None):
    """Scans every .desktop file under `dirs` (default: _xdg_desktop_dirs()) and returns the
    parsed entries, most-preferred directory's entries first. One slow filesystem walk — callers
    should cache the result across a single suggestion request rather than re-scanning per
    candidate, though this module doesn't impose any caching policy itself (see
    alttabsucks_server.py's own call site for how often it actually runs)."""
    entries = []
    for app_dir in (dirs if dirs is not None else _xdg_desktop_dirs()):
        try:
            filenames = sorted(os.listdir(app_dir))
        except OSError:
            continue
        for filename in filenames:
            if not filename.endswith(".desktop"):
                continue
            try:
                text = (app_dir / filename).read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            entry = parse_desktop_entry(text)
            if entry:
                entries.append(entry)
    return entries


def suggest_launch_command(resource_class, entries):
    """The actual matching heuristic — pure function over an already-loaded entries list (see
    load_desktop_entries), so it's unit-testable without any real .desktop files on disk. Returns
    an argv list, or None if nothing reasonably confident was found.

    Two signals, tried in priority order:
      1. StartupWMClass matches resourceClass exactly (case-insensitive) — the field the Desktop
         Entry Spec actually defines for exactly this purpose, when a packager bothered to set it
         correctly. First match wins; a packager who set this at all is describing one specific
         real app, not several plausible ones, so there's no real ambiguity left to rank.
      2. The launch command's own binary name (Exec's first token, path-stripped) matches
         resourceClass's last dot-segment ("org.kde.kate" -> "kate", "steam" -> "steam" — a no-op
         split for a resourceClass with no dots at all) exactly, or — only when *both* strings are
         at least 3 characters, so a short, generic one can't loosely prefix-match half the
         installed system (confirmed live: resourceClass "com.shellyorg.shelly" -> "shelly"
         otherwise trivially prefix-matched an unrelated arch-update tray icon's `sh -c ...`
         wrapper, since "shelly".startswith("sh") is true of nearly anything) — one is a prefix of
         the other ("Bitwarden" -> "bitwarden" is a prefix of Exec's "bitwarden-desktop").

         This pass ranks rather than first-match-wins, unlike pass 1: confirmed live that Steam
         auto-generates a separate .desktop shortcut per installed game (e.g. Half-Life.desktop,
         Exec=steam steam://rungameid/70), and every one of them shares the exact same binary name
         as the real steam.desktop entry — a plain first match could just as easily land on a
         specific game shortcut as on the actual "launch Steam" entry, purely depending on
         directory-scan order. Ranked instead, by two keys: fewest leftover argv tokens first (a
         plain launch command — just the binary, maybe one flag — outranks one carrying an extra
         positional argument, exactly what marks a *specific*-target shortcut rather than a
         generic one; this alone is what correctly separates Steam's real entry from a per-game
         one), then NoDisplay=false before NoDisplay=true as a tiebreak (confirmed live this
         second key is what's actually needed when the *first* one ties too: Shelly's real
         shelly-ui entry and its separate shelly-notifications background helper both resolve to
         a bare one-token argv, tying on argv length alone — NoDisplay is what tells a primary
         app from a helper/tray/background one that happens to share enough of its name).
         Remaining ties broken by original scan order (load_desktop_entries' own directory-
         priority order, preserved by Python's min() being stable)."""
    resource_class = (resource_class or "").strip()
    if not resource_class:
        return None
    rc_lower = resource_class.lower()
    rc_last_segment = rc_lower.rsplit(".", 1)[-1]

    for entry in entries:
        if entry.startup_wm_class and entry.startup_wm_class.lower() == rc_lower:
            return entry.argv

    candidates = []
    for entry in entries:
        if not entry.argv:
            continue
        bin_name = os.path.basename(entry.argv[0]).lower()
        if not bin_name:
            continue
        is_exact = bin_name == rc_last_segment
        is_fuzzy_prefix = (
            len(rc_last_segment) >= 3
            and len(bin_name) >= 3
            and (bin_name.startswith(rc_last_segment) or rc_last_segment.startswith(bin_name))
        )
        if is_exact or is_fuzzy_prefix:
            candidates.append(entry)
    if candidates:
        return min(candidates, key=lambda e: (len(e.argv), e.no_display)).argv

    return None
