#!/usr/bin/env bash
# Install tracked git hooks into .git/hooks/.
# Run once after cloning: bash install-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for hook in "$REPO_ROOT/hooks/"*; do
    name="$(basename "$hook")"
    dest="$REPO_ROOT/.git/hooks/$name"
    cp "$hook" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    echo "Installed: .git/hooks/$name"
done

# Hooks this repo used to ship (pending-migrations reminders); removed from hooks/ since.
for old in post-merge post-rewrite; do
    if [ -f "$REPO_ROOT/.git/hooks/$old" ] && grep -q "pending-migrations" "$REPO_ROOT/.git/hooks/$old"; then
        rm "$REPO_ROOT/.git/hooks/$old"
        echo "Removed: .git/hooks/$old"
    fi
done

echo "Done."
