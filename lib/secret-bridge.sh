#!/bin/bash
# secret-bridge.sh - bash-based gopass wrapper for cross-platform secret management
# Supports get, lock, status, list, set, delete actions

set -euo pipefail

action="${1:-}"
name="${2:-}"
allow_prompt="${3:-}"

GOPASS_PATH="${GOPASS_PATH:-gopass}"
PASSWORD_STORE_DIR="${PASSWORD_STORE_DIR:-$HOME/.password-store}"

# Find gopass if not on PATH (common issue with winget installations)
if ! command -v "$GOPASS_PATH" &> /dev/null && [ "$GOPASS_PATH" = "gopass" ]; then
    for dir in \
        "$HOME/AppData/Local/gopass" \
        "/c/Users/$USERNAME/AppData/Local/gopass" \
        "/c/Program Files/gopass" \
        "/c/Program Files (x86)/gopass"; do
        if [ -f "$dir/gopass.exe" ]; then
            GOPASS_PATH="$dir/gopass.exe"
            break
        fi
    done
fi

fail() {
    echo "error: $*" >&2
    exit 1
}

ensure_store_initialized() {
    if ! "$GOPASS_PATH" ls >/dev/null 2>&1; then
        fail "Password store not initialized or inaccessible. Run: bash dev-scripts/setup-secrets.sh"
    fi
}

case "$action" in
    get)
        [ -z "$name" ] && fail "Name is required for action 'get'"
        ensure_store_initialized

        if output=$("$GOPASS_PATH" show "$name" 2>/dev/null); then
            printf "%s" "$output"
            exit 0
        else
            if [ -n "$allow_prompt" ]; then
                fail "Secret '$name' not found in password store"
            fi
            exit 0
        fi
        ;;

    set)
        [ -z "$name" ] && fail "Name is required for action 'set'"
        ensure_store_initialized
        
        read -rsp "Enter secret for $name: " secret
        echo ""
        "$GOPASS_PATH" insert -f "$name" <<< "$secret" > /dev/null
        echo "Secret '$name' stored"
        exit 0
        ;;

    delete)
        [ -z "$name" ] && fail "Name is required for action 'delete'"
        ensure_store_initialized
        "$GOPASS_PATH" rm -f "$name" > /dev/null 2>&1 || fail "Secret '$name' not found"
        echo "Secret '$name' deleted"
        exit 0
        ;;

    list)
        ensure_store_initialized
        entries="$($GOPASS_PATH list --flat 2>/dev/null | sed '/^[[:space:]]*$/d')"
        if [ -z "$entries" ]; then
            echo "No secrets found."
        else
            "$GOPASS_PATH" ls
        fi
        exit 0
        ;;

    lock)
        # gopass doesn't have an explicit lock command like PowerShell SecretStore.
        # The GPG agent timeout controls when cached passphrases expire.
        # We can kill the gpg-agent to force re-prompt on next use:
        if command -v gpgconf &> /dev/null; then
            gpgconf --kill gpg-agent 2>/dev/null || true
        fi
        echo "LOCKED"
        exit 0
        ;;

    status)
        if "$GOPASS_PATH" ls >/dev/null 2>&1; then
            echo "UNLOCKED"
            exit 0
        else
            echo "LOCKED"
            exit 0
        fi
        ;;

    *)
        fail "Unknown action: $action. Valid actions: get, set, delete, list, lock, status"
        ;;
esac
