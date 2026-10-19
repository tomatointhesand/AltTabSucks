#!/usr/bin/env bash
# Lists MIGRATIONS.md entries not yet recorded for this clone, and records them once handled.
# See MIGRATIONS.md for what the entries are and how to apply them.
#
#   pending-migrations.sh                    list pending entries (with the commit that added each)
#   pending-migrations.sh --mark <ID> <status>   record an entry: applied | already-done | not-applicable
#   pending-migrations.sh --hook             one-line reminder if anything is pending, else silent
#                                            (used by hooks/post-merge and hooks/post-rewrite)
#
# The record is a plain file inside .git/ ("<ID> <status> <date>" per line): per-clone, since the
# local files it tracks are per-machine, and never committed.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
MIGRATIONS="$REPO_ROOT/MIGRATIONS.md"
RECORD="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)/alttabsucks-local-migrations"

# IDs are the "## YYYY-MM-DD-slug" headings, in file (= apply) order.
list_ids() {
    [ -f "$MIGRATIONS" ] || return 0
    sed -nE 's/^## ([0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+)[[:space:]]*$/\1/p' "$MIGRATIONS"
}

is_recorded() {
    [ -f "$RECORD" ] && cut -d' ' -f1 "$RECORD" | grep -qxF "$1"
}

pending_ids() {
    list_ids | while IFS= read -r id; do
        is_recorded "$id" || echo "$id"
    done
}

# The commit that added the entry's heading, found from history rather than written into the
# file (a commit can't contain its own hash, and rebases change hashes).
introduced_by() {
    local c
    c="$(git -C "$REPO_ROOT" log --reverse --format='%h %ad %s' --date=short -S"## $1" -- MIGRATIONS.md | head -n1)"
    echo "${c:-(not committed yet)}"
}

case "${1:-}" in
    --mark)
        id="${2:-}"; status="${3:-}"
        [ -n "$id" ] && [ -n "$status" ] || { echo "usage: $0 --mark <ID> <applied|already-done|not-applicable>" >&2; exit 2; }
        case "$status" in applied|already-done|not-applicable) ;; *) echo "unknown status '$status'" >&2; exit 2 ;; esac
        list_ids | grep -qxF "$id" || { echo "no entry '$id' in MIGRATIONS.md" >&2; exit 2; }
        if is_recorded "$id"; then
            echo "$id already recorded:"; grep "^$id " "$RECORD"
            exit 0
        fi
        echo "$id $status $(date +%Y-%m-%d)" >> "$RECORD"
        echo "Recorded: $id $status"
        ;;
    --hook)
        # Never fail or block the git operation that triggered this.
        n="$(pending_ids 2>/dev/null | wc -l | tr -d ' ')" || exit 0
        if [ "${n:-0}" -gt 0 ]; then
            echo
            echo "AltTabSucks: $n local-file migration(s) pending — your own untracked hotkeys/config"
            echo "files may need updating for what you just pulled. Ask your agent to \"apply pending"
            echo "migrations from MIGRATIONS.md\", or see that file. List: bash dev-scripts/pending-migrations.sh"
        fi
        exit 0
        ;;
    "")
        ids="$(pending_ids)"
        if [ -z "$ids" ]; then
            echo "No pending migrations."
            exit 0
        fi
        echo "Pending migrations (apply top to bottom, see MIGRATIONS.md):"
        while IFS= read -r id; do
            printf '  %-45s added in %s\n' "$id" "$(introduced_by "$id")"
        done <<< "$ids"
        ;;
    *)
        echo "usage: $0 [--mark <ID> <status> | --hook]" >&2
        exit 2
        ;;
esac
