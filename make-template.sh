#!/usr/bin/env bash
# Regenerates sanitized template files from their gitignored sources.
# Run this before committing whenever you edit app-hotkeys.ahk or config.ahk.

set -euo pipefail

root="$(dirname "$0")/lib"

sanitize_paths() {
  sed \
    -e 's|"https\?://\(localhost\|127\.0\.0\.1\)[^"]*"|\0|g' \
    -e 's|"https\?://[^"]*"|"https://YOUR_URL"|g' \
    -e 's|"[A-Za-z]:\\[^"]*"|"C:\\YOUR\\PATH"|g' \
    -e 's|"\\[A-Za-z][^"\\]*\\[^"]*"|"C:\\YOUR\\PATH"|g'
}

# Same patterns but skipping AHK comment lines (leading ;).
# Used for config.ahk where example paths in comments must be preserved.
sanitize_paths_skip_comments() {
  sed \
    -e '/^[[:space:]]*;/!s|"https\?://\(localhost\|127\.0\.0\.1\)[^"]*"|\0|g' \
    -e '/^[[:space:]]*;/!s|"https\?://[^"]*"|"https://YOUR_URL"|g' \
    -e '/^[[:space:]]*;/!s|"[A-Za-z]:\\[^"]*"|"C:\\YOUR\\PATH"|g' \
    -e '/^[[:space:]]*;/!s|"\\[A-Za-z][^"\\]*\\[^"]*"|"C:\\YOUR\\PATH"|g'
}

# app-hotkeys.ahk → app-hotkeys.template.ahk
sanitize_paths < "$root/app-hotkeys.ahk" \
  | sed \
      -e 's|FocusTab("[^"]*"|FocusTab("YOUR_BROWSER_PROFILE"|g' \
      -e 's|CycleChromiumProfile("[^"]*"|CycleChromiumProfile("YOUR_BROWSER_PROFILE"|g' \
      -e 's|CycleBraveProfile("[^"]*"|CycleBraveProfile("YOUR_BROWSER_PROFILE"|g' \
  > "$root/app-hotkeys.template.ahk"
echo "Written: $root/app-hotkeys.template.ahk"

# config.ahk → config.template.ahk
# Uses comment-aware sanitizer to preserve example paths in ; comment lines.
sanitize_paths_skip_comments < "$root/config.ahk" > "$root/config.template.ahk"
echo "Written: $root/config.template.ahk"
