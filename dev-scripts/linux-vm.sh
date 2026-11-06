#!/usr/bin/env bash
# Linux test VM for AltTabSucks (quickemu): minimal Arch + Plasma (Wayland), logging the user
# "tester" straight into Plasma at boot. One-time setup: tests/linux/README.md. The VM lives in
# $ALTTABSUCKS_VM_DIR (default ~/VMs): archlinux-latest.conf, archlinux-latest/.
# Usage:
#   linux-vm.sh start          boot it (window opens) and wait until SSH answers
#   linux-vm.sh stop           shut it down
#   linux-vm.sh reboot         restart and wait until SSH answers again (it logs on by itself)
#   linux-vm.sh reset [NAME]   stop, roll the disk back to a snapshot (default "browser"), start
#   linux-vm.sh ssh [cmd]      a shell as tester (no cmd: interactive)
#   linux-vm.sh root [cmd]     the same as root
#   linux-vm.sh desktop cmd    cmd as tester inside the Plasma session (its D-Bus, Wayland display)
#   linux-vm.sh sync [repo]    copy a git working tree (default: this repo) to ~tester/alttabsucks
#   linux-vm.sh key KEYS       press keys on the VM's keyboard, QEMU sendkey style (ctrl-alt-shift-a)
#   linux-vm.sh screenshot F   save the VM's screen as F (PNG)
#   linux-vm.sh snapshot NAME  save the (stopped) disk as a new snapshot
# Snapshots: "clean" = Arch, Plasma, SDDM autologin, SSH (key ./archlinux-latest/id_ed25519),
# AltTabSucks' dependencies, dark theme, 1440x900; "browser" = clean + Chromium's first run done.
set -euo pipefail

VMS="${ALTTABSUCKS_VM_DIR:-$HOME/VMs}"
NAME=archlinux-latest
DIR="$VMS/$NAME"
[ -f "$VMS/$NAME.conf" ] || { echo "No VM at $VMS/$NAME.conf (set ALTTABSUCKS_VM_DIR; setup: tests/linux/README.md)" >&2; exit 1; }
DISK="$DIR/disk.qcow2"
MONITOR="$DIR/$NAME-monitor.socket"
SSH_CONFIG="$DIR/ssh_config"

running() { pgrep -f "^/usr/bin/qemu-system-x86_64 -name $NAME," >/dev/null; }

# quickemu forwards SSH to the first free port from 22220 (the Windows VM may hold that one).
write_ssh_config() {
    local port
    port="$(cut -d, -f2 "$DIR/$NAME.ports" 2>/dev/null || echo 22220)"
    cat > "$SSH_CONFIG" <<EOF
Host archvm archvm-root
    HostName localhost
    Port $port
    IdentityFile $DIR/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
    BatchMode yes
    ConnectTimeout 10
    LogLevel ERROR
Host archvm
    User tester
Host archvm-root
    User root
EOF
}

ssh_vm() { ssh -F "$SSH_CONFIG" archvm "$@"; }

wait_ssh() {
    for _ in $(seq 1 90); do
        ssh_vm "exit 0" 2>/dev/null && return 0
        sleep 2
    done
    echo "SSH didn't come up within 3 minutes" >&2
    return 1
}

# Until Plasma's session is up for tester: its D-Bus answers and KWin is on it.
wait_desktop() {
    for _ in $(seq 1 90); do
        "$0" desktop "qdbus6 org.kde.KWin /KWin org.kde.KWin.currentDesktop" >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo "Plasma's session didn't come up within 3 minutes" >&2
    return 1
}

monitor() { echo "$1" | socat - "UNIX-CONNECT:$MONITOR" >/dev/null; }

case "${1:-}" in
    start)
        if ! running; then
            rm -f "$DIR/$NAME.pid" "$MONITOR" "$DIR/$NAME-serial.socket"
            (cd "$VMS" && quickemu --vm "$NAME.conf" >"$VMS/$NAME-run.log" 2>&1)
        fi
        write_ssh_config
        wait_ssh && wait_desktop && echo "$NAME is up"
        ;;
    stop)
        if running; then
            ssh -F "$SSH_CONFIG" archvm-root "systemctl poweroff" 2>/dev/null || true
            for _ in $(seq 1 60); do running || break; sleep 2; done
        fi
        running && { echo "still running" >&2; exit 1; }
        echo "$NAME is stopped"
        ;;
    reboot)
        ssh -F "$SSH_CONFIG" archvm-root "systemctl reboot" 2>/dev/null || true
        for _ in $(seq 1 60); do ssh_vm "exit 0" 2>/dev/null || break; sleep 2; done  # until it's going down
        wait_ssh && wait_desktop && echo "$NAME is back up"
        ;;
    reset)
        "$0" stop
        qemu-img snapshot -a "${2:-browser}" "$DISK"
        "$0" start
        ;;
    ssh)
        shift
        ssh_vm "$@"
        ;;
    root)
        shift
        ssh -F "$SSH_CONFIG" archvm-root "$@"
        ;;
    desktop)
        shift
        # The session's own display settings (Plasma puts them in systemd's user environment at
        # logon; the Wayland socket isn't always wayland-0).
        ssh_vm "export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus
            eval \"\$(systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_CURRENT_DESKTOP|XDG_SESSION_TYPE|XAUTHORITY)=' | sed 's/^/export /')\"
            $*"
        ;;
    sync)
        repo="${2:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
        ssh_vm "rm -rf ~/alttabsucks && mkdir ~/alttabsucks"
        git -C "$repo" ls-files -z --cached --others --exclude-standard \
            | (cd "$repo" && tar -cf - --null -T -) \
            | ssh_vm "tar -xf - -C ~/alttabsucks"
        echo "synced $repo -> ~tester/alttabsucks"
        ;;
    key)
        shift
        for k in "$@"; do monitor "sendkey $k"; sleep 0.3; done
        ;;
    screenshot)
        out="${2:?file}"
        monitor "screendump $out.ppm"
        sleep 1
        magick "$out.ppm" "$out" && rm -f "$out.ppm"
        ;;
    snapshot)
        running && { echo "stop the VM first" >&2; exit 1; }
        qemu-img snapshot -c "${2:?snapshot name}" "$DISK"
        qemu-img snapshot -l "$DISK"
        ;;
    *)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
