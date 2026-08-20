# config.py — AltTabSucks Linux server settings. Copy this file to config.py and fill in.
# config.py is gitignored, same pattern as lib/config.ahk on the Windows side.
#
# Only Chromium-profile discovery uses this so far (see profile_discovery.py). More fields will
# land here alongside future features (e.g. CHROMIUM_EXE once the launch-a-browser escape hatch
# is built).

import os

# The configured browser's user-data directory. Examples:
#   Brave:   ~/.config/BraveSoftware/Brave-Browser
#   Chrome:  ~/.config/google-chrome
#   Edge:    ~/.config/microsoft-edge
#   Vivaldi: ~/.config/vivaldi
CHROMIUM_USERDATA = os.path.expanduser("~/.config/YOUR_BROWSER")
