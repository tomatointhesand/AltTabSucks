#!/usr/bin/env python3
"""
Chromium profile discovery for Linux.

On Windows, lib/chromium.ahk's _InitChromiumState() populates the profile list by regexing the
browser's "Local State" file for info_cache entries (AHK has no JSON library, so it can't just
parse it), then POSTs the display names to the server. On Linux there's no AHK-equivalent process
doing that yet, so the server discovers profiles itself at startup instead — "Local State" is
actually valid JSON, so this is most of the AHK version's regex logic, straightforwardly done.

This only changes *how* the server's profile_list gets populated (self-discovered vs. pushed via
POST /profiles) — the wire contract GET /profiles returns is unchanged, so BrowserExtension/
needs no changes, and none of this touches the Windows side (Server/AltTabSucksServer.ps1,
lib/*.ahk) at all.
"""

import json
import re
from pathlib import Path


def discover_chromium_profiles(user_data_dir: str) -> dict[str, str]:
    """Returns {display_name: profile_dir_name}, e.g. {"Personal": "Default", "Work": "Profile 1"}.
    Empty dict if user_data_dir is unset, doesn't exist, or Local State can't be parsed — same
    "just don't populate anything" behavior as the AHK version's failure paths."""
    if not user_data_dir:
        return {}

    profiles: dict[str, str] = {}
    try:
        with (Path(user_data_dir) / "Local State").open(encoding="utf-8") as f:
            data = json.load(f)
        info_cache = data.get("profile", {}).get("info_cache", {})
        for dir_name, info in info_cache.items():
            name = info.get("name")
            if name:
                profiles[name] = dir_name
    except (OSError, json.JSONDecodeError):
        pass

    if profiles:
        return profiles

    # Fallback: scan for Default/Profile N subdirectories when info_cache parsing yields nothing
    # (e.g. a browser without info_cache, or non-standard directory names) — mirrors
    # _InitChromiumState's fallback on the AHK side.
    base = Path(user_data_dir)
    try:
        if base.is_dir():
            for entry in sorted(base.iterdir()):
                if entry.is_dir() and re.match(r"^(Default|Profile \d+)$", entry.name):
                    profiles[entry.name] = entry.name
    except OSError:
        pass
    if not profiles and (base / "Default").is_dir():
        profiles["Default"] = "Default"

    return profiles
