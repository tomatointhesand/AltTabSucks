#!/usr/bin/env bash
# Regenerates sanitized template files from their gitignored sources.
# Run this before committing whenever you edit app-hotkeys.ahk or config.ahk.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)/lib"

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
# Sensitive section (between BEGIN/END SENSITIVE markers): redact profile var values,
# https:// URLs (match patterns and destination URLs), and bare domain match patterns.
# Everything outside the sensitive block passes through unchanged.
awk '
/^;--- BEGIN SENSITIVE ---/ { in_sensitive=1; print; next }
/^;--- END SENSITIVE ---/   { in_sensitive=0; print; next }
{
    if (in_sensitive) {
        line = $0
        gsub(/P1 := "[^"]*"/, "P1 := \"Default\"", line)
        gsub(/P2 := "[^"]*"/, "P2 := \"Profile 1\"", line)
        gsub(/"https?:\/\/[^\\"]*"/, "\"https://YOUR_URL\"", line)
        gsub(/"[^\\"]*\.[^\\"]*"/, "\"YOUR_URL\"", line)
        if (line ~ /^[[:space:]]*P[12][[:space:]]*:=/ || line ~ /^[[:space:]]*;[[:space:]]*P[12][[:space:]]*:=/) {
            print line
        } else if (line ~ /^[[:space:]]*;/) {
            print line
        } else {
            print "; " line
        }
    } else {
        print $0
    }
}
' "$root/app-hotkeys.ahk" > "$root/app-hotkeys.template.ahk"
echo "Written: $root/app-hotkeys.template.ahk"

# config.ahk → config.template.ahk
# Uses comment-aware sanitizer to preserve example paths in ; comment lines.
if [ -f "$root/config.ahk" ]; then
  sanitize_paths_skip_comments < "$root/config.ahk" > "$root/config.template.ahk"
  echo "Written: $root/config.template.ahk"
else
  echo "Skipped: $root/config.template.ahk (config.ahk not present)"
fi
