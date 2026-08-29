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
# Guarded the same way the config.ahk section below already is — previously assumed
# app-hotkeys.ahk always exists, which held only by accident: the pre-commit hook's own trigger
# condition used to be AHK-files-only, so this script never actually ran anywhere lacking one.
# That stopped being true once the hook's trigger grew to include the Linux hotkeys files too —
# a pure-Linux dev box with no lib/app-hotkeys.ahk at all now hits this section on every commit.
if [ -f "$root/app-hotkeys.ahk" ]; then
awk '
/^;--- BEGIN SENSITIVE ---/ { in_sensitive=1; print; next }
/^;--- END SENSITIVE ---/   { in_sensitive=0; print; next }
{
    if (in_sensitive) {
        line = $0
        gsub(/:=[[:space:]]*"[^"]*"/, ":= \"YOUR_VALUE\"", line)
        gsub(/P1 := "[^"]*"/, "P1 := \"Default\"", line)
        gsub(/P2 := "[^"]*"/, "P2 := \"Profile 1\"", line)
        gsub(/"https?:\/\/[^\\"]*"/, "\"https://YOUR_URL\"", line)
        gsub(/"[^\\"]*\.[^\\"]*"/, "\"YOUR_URL\"", line)
        gsub(/"[A-Za-z]:\\[^"]*"/, "\"C:\\\\YOUR\\\\PATH\"", line)
        gsub(/"\\[^"]*"/, "\"C:\\\\YOUR\\\\PATH\"", line)
        gsub(/Send\("[^"]*"\)/, "Send(\"YOUR_VALUE\")", line)
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
else
  echo "Skipped: $root/app-hotkeys.template.ahk (app-hotkeys.ahk not present)"
fi

# config.ahk → config.template.ahk
# Uses comment-aware sanitizer to preserve example paths in ; comment lines.
if [ -f "$root/config.ahk" ]; then
  sanitize_paths_skip_comments < "$root/config.ahk" > "$root/config.template.ahk"
  echo "Written: $root/config.template.ahk"
else
  echo "Skipped: $root/config.template.ahk (config.ahk not present)"
fi

# Linux: hotkeys.js/hotkeys.json → hotkeys.template.js/hotkeys.template.json
# Deliberately *unsanitized* — a real, working example (this repo's own live config) instead of
# generic "YOUR_BROWSER_RESOURCE_CLASS" placeholders, so a `git pull` always brings something
# that actually works. hotkeys.js/hotkeys.json themselves stay gitignored either way (see
# .gitignore's own comment) — only these two templates are ever tracked.
linux_root="$(cd "$(dirname "$0")/.." && pwd)/linux/kwin/alttabsucks/contents/code"

if [ -f "$linux_root/hotkeys.js" ]; then
  {
    echo "// This file is an unsanitized copy of the repo owner's own real hotkeys.js, refreshed"
    echo "// automatically by dev-scripts/make-template.sh on every commit (see hooks/pre-commit) —"
    echo "// a real, working example instead of generic placeholders. hotkeys.js itself stays"
    echo "// gitignored (a \`git pull\` never touches your own local edits to it); copy this file to"
    echo "// hotkeys.js and edit it to match your own setup. See linux/README.md and the porting"
    echo "// checklist for what each binding type does."
    echo
    cat "$linux_root/hotkeys.js"
  } > "$linux_root/hotkeys.template.js"
  echo "Written: $linux_root/hotkeys.template.js (unsanitized)"
else
  echo "Skipped: $linux_root/hotkeys.template.js (hotkeys.js not present)"
fi

# No banner here — unlike hotkeys.template.js, this has to stay valid JSON (no comments allowed).
if [ -f "$linux_root/hotkeys.json" ]; then
  cp "$linux_root/hotkeys.json" "$linux_root/hotkeys.template.json"
  echo "Written: $linux_root/hotkeys.template.json (unsanitized)"
else
  echo "Skipped: $linux_root/hotkeys.template.json (hotkeys.json not present)"
fi
