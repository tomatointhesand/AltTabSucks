# config.py — AltTabSucks Linux server settings. Copy this file to config.py and fill in.
# config.py is gitignored, same pattern as lib/config.ahk on the Windows side.
#
# installer.sh's browser wizard (./installer.sh configure) writes this file for you — this
# template is mainly for reference, or for setting things up by hand.

import os

# The configured browser's user-data directory. Examples:
#   Brave:   ~/.config/BraveSoftware/Brave-Browser
#   Chrome:  ~/.config/google-chrome
#   Edge:    ~/.config/microsoft-edge
#   Vivaldi: ~/.config/vivaldi
CHROMIUM_USERDATA = os.path.expanduser("~/.config/YOUR_BROWSER")

# The command used to launch the browser — NOT necessarily the same as hotkeys.js's
# resourceClass. On Arch, Brave's package installs it as plain "brave", not "brave-browser",
# even though its window resourceClass *is* "brave-browser" — check what's actually on your
# PATH (`which brave-browser` / `which brave` / etc.) rather than assuming. Used by the
# launch-a-browser-profile escape hatch (dbus_bridge.py's LaunchChromiumProfile).
CHROMIUM_EXE = "YOUR_BROWSER_COMMAND"

# Extra command-line flags passed on every launch, e.g. ["--remote-debugging-port=9222"].
# Optional — leave as an empty list if you don't need any.
CHROMIUM_EXTRA_FLAGS = []
