#!/bin/bash
# manage-secrets.sh - Secret store setup and interactive management for gopass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BRIDGE_SCRIPT="$REPO_ROOT/lib/secret-bridge.sh"
APP_HOTKEYS_FILE="$REPO_ROOT/lib/app-hotkeys.ahk"
LOCK_SIGNAL_PATH="$HOME/AppData/Local/Temp/alts_secrets_lock.trigger"
GOPASS_PATH="${GOPASS_PATH:-gopass}"
SELECTED_SECRET_NAME=""

fail() {
    echo "error: $*" >&2
    exit 1
}

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

ensure_gopass() {
    if ! command -v "$GOPASS_PATH" &> /dev/null; then
        fail "gopass not found. Install with: winget install gopass.gopass"
    fi
    if ! command -v gpg &> /dev/null; then
        fail "gpg not found. Install with: winget install GnuPG.GnuPG"
    fi
}

ensure_store_initialized() {
    if "$GOPASS_PATH" ls >/dev/null 2>&1; then
        return 0
    fi

    local store_paths=(
        "$HOME/.password-store"
        "$HOME/AppData/Local/gopass/stores/root"
        "/c/Users/$USERNAME/AppData/Local/gopass/stores/root"
    )
    local p
    for p in "${store_paths[@]}"; do
        if [ -d "$p" ]; then
            fail "Password store exists but is not accessible (possibly locked). Run 'gopass ls' to unlock, then retry."
        fi
    done

    echo "Initializing password store..."
    if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -q "^sec:"; then
        echo "Generating GPG key pair..."
        gpg --quick-gen-key "AltTabSucks Secrets" rsa3072 encr 0
    fi
    local key_id
    key_id=$(gpg --list-secret-keys --with-colons | grep "^sec:" | head -1 | cut -d: -f5)
    [ -z "$key_id" ] && fail "Could not find or generate a GPG key"
    "$GOPASS_PATH" init "$key_id" || fail "Failed to initialize gopass"
    echo "Password store initialized"
}

# Resolves PasswordSecretNameN entries from app-hotkeys.ahk
PASSWORD_SECRET_NAMES=()

resolve_secret_names() {
    [ -f "$APP_HOTKEYS_FILE" ] || fail "Missing app-hotkeys file: $APP_HOTKEYS_FILE"
    PASSWORD_SECRET_NAMES=()
    local i=1
    while true; do
        local p
        p=$(sed -nE "s/^[[:space:]]*PasswordSecretName${i}[[:space:]]*:=[[:space:]]*\"([^\"]+)\".*/\1/p" "$APP_HOTKEYS_FILE" | head -1)
        [ -z "$p" ] && break
        PASSWORD_SECRET_NAMES+=("$p")
        (( i++ ))
    done
}

pick_secret_from_list() {
    SELECTED_SECRET_NAME=""
    mapfile -t secrets < <(gopass list --flat 2>/dev/null | sed '/^[[:space:]]*$/d')

    if [ "${#secrets[@]}" -eq 0 ]; then
        echo "No secrets found."
        return 1
    fi

    echo ""
    echo "Select a secret:"
    local i
    for i in "${!secrets[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${secrets[$i]}"
    done
    echo ""

    local sel
    read -rp "Choose a number (or press Enter to cancel): " sel
    [ -z "$sel" ] && { echo "Selection cancelled"; return 1; }
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "Invalid selection"; return 1; }
    [ "$sel" -ge 1 ] && [ "$sel" -le "${#secrets[@]}" ] || { echo "Selection out of range"; return 1; }

    SELECTED_SECRET_NAME="${secrets[$((sel - 1))]}"
    return 0
}

do_initial_setup() {
    echo ""
    echo "Initial Setup"
    echo "============="
    resolve_secret_names

    if [ "${#PASSWORD_SECRET_NAMES[@]}" -eq 0 ]; then
        echo "No PasswordSecretNameN entries found in lib/app-hotkeys.ahk."
        echo "Add PasswordSecretName1 (and higher) variables and rerun."
        return
    fi

    echo ""
    echo "Enter values for password secrets defined in app-hotkeys.ahk."
    echo "(Press Enter to skip any entry and keep existing value.)"
    echo ""

    local i
    for (( i=0; i<${#PASSWORD_SECRET_NAMES[@]}; i++ )); do
        local pw_key="${PASSWORD_SECRET_NAMES[$i]}"
        read -rsp "Password for '$pw_key' (will not echo): " pw_val
        echo ""
        if [ -n "$pw_val" ]; then
            "$GOPASS_PATH" insert -f "$pw_key" <<< "$pw_val" > /dev/null
            echo "✓ Stored $pw_key"
        fi
        echo ""
    done
    echo "Setup complete."
}

show_menu() {
    echo ""
    echo "Secret Management"
    echo "================="
    echo "1. List all secrets"
    echo "2. Initial setup (seed secrets from app-hotkeys.ahk)"
    echo "3. Define a new secret"
    echo "4. Update a secret"
    echo "5. Delete a secret"
    echo "6. Lock secrets (kill gpg-agent)"
    echo "7. Exit"
    echo ""
    read -rp "Choose an option (1-7): " choice
}

main() {
    ensure_gopass
    ensure_store_initialized

    while true; do
        show_menu

        case "$choice" in
            1)
                echo ""
                bash "$BRIDGE_SCRIPT" list
                ;;
            2)
                do_initial_setup
                ;;
            3)
                read -rp "Enter new secret name: " secret_name
                if [ -n "$secret_name" ]; then
                    read -rsp "Enter value for '$secret_name': " new_value
                    echo ""
                    if [ -n "$new_value" ]; then
                        bash "$BRIDGE_SCRIPT" set "$secret_name" <<< "$new_value"
                    fi
                fi
                ;;
            4)
                pick_secret_from_list || true
                secret_name="$SELECTED_SECRET_NAME"
                if [ -n "$secret_name" ]; then
                    read -rsp "Enter new value for '$secret_name': " new_value
                    echo ""
                    if [ -n "$new_value" ]; then
                        bash "$BRIDGE_SCRIPT" set "$secret_name" <<< "$new_value"
                    fi
                fi
                ;;
            5)
                pick_secret_from_list || true
                secret_name="$SELECTED_SECRET_NAME"
                if [ -n "$secret_name" ]; then
                    read -rp "Delete '$secret_name'? Type yes to confirm: " confirm
                    if [ "$confirm" = "yes" ]; then
                        bash "$BRIDGE_SCRIPT" delete "$secret_name"
                    else
                        echo "Delete cancelled"
                    fi
                fi
                ;;
            6)
                bash "$BRIDGE_SCRIPT" lock
                mkdir -p "$(dirname "$LOCK_SIGNAL_PATH")"
                : > "$LOCK_SIGNAL_PATH"
                echo "Secrets locked (gpg-agent killed)"
                echo "AHK cache clear signaled"
                ;;
            7)
                echo "Exiting"
                exit 0
                ;;
            *)
                echo "Invalid option"
                ;;
        esac
    done
}

main "$@"
