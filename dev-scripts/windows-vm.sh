#!/usr/bin/env bash
# Windows 11 test VM for AltTabSucks (quickemu) - see tests/windows/README.md for the one-time
# setup. The VM lives in $ALTTABSUCKS_VM_DIR (default ~/VMs): windows-11.conf, windows-11/.
# Usage:
#   windows-vm.sh start         boot it (window opens) and wait until SSH answers
#   windows-vm.sh stop          shut Windows down
#   windows-vm.sh reboot        restart Windows and wait until SSH answers again (it logs on by itself)
#   windows-vm.sh reset [NAME]  stop, roll the disk back to a snapshot (default "browser"), start
#   windows-vm.sh ssh [cmd]     PowerShell over SSH (no cmd: interactive)
#   windows-vm.sh sync [repo]   copy a git working tree (default: this repo) to C:\alttabsucks
#   windows-vm.sh snapshot NAME save the (stopped) disk as a new snapshot
#   windows-vm.sh resolution [WxH] set the display mode in Windows (default 1920x1080); snapshot
#                               afterwards to keep it
# Snapshots: "clean" = AutoHotkey v2, PowerShell 7.6, Git, OpenSSH (key: ./windows-11/id_ed25519),
# Defender exclusions for C:\alttabsucks, automatic updates off; Windows is unactivated.
# "browser" = clean + Edge (profile "Profile 1") with the extension loaded unpacked from
# C:\alttabsucks\BrowserExtension and token "alttabsucks-vm-test", startup boost off.
set -euo pipefail

VMS="${ALTTABSUCKS_VM_DIR:-$HOME/VMs}"
[ -f "$VMS/windows-11.conf" ] || { echo "No VM at $VMS (set ALTTABSUCKS_VM_DIR; setup: tests/windows/README.md)" >&2; exit 1; }
DISK="$VMS/windows-11/disk.qcow2"
SSH=(ssh -F "$VMS/windows-11/ssh_config" win11)

running() { pgrep -f "^/usr/bin/qemu-system-x86_64 -name windows-11," >/dev/null; }

wait_ssh() {
    for _ in $(seq 1 90); do
        "${SSH[@]}" "exit 0" 2>/dev/null && return 0
        sleep 2
    done
    echo "SSH didn't come up within 3 minutes" >&2
    return 1
}

case "${1:-}" in
    start)
        if ! running; then
            rm -f "$VMS"/windows-11/windows-11.{pid,swtpm-sock} "$VMS/windows-11/windows-11-monitor.socket"
            (cd "$VMS" && quickemu --vm windows-11.conf >"$VMS/quickemu-run.log" 2>&1)
        fi
        wait_ssh && echo "win11 is up"
        ;;
    stop)
        if running; then
            "${SSH[@]}" "Stop-Computer -Force" 2>/dev/null || true
            for _ in $(seq 1 60); do running || break; sleep 2; done
        fi
        running && { echo "still running" >&2; exit 1; }
        echo "win11 is stopped"
        ;;
    reboot)
        "${SSH[@]}" "Restart-Computer -Force" 2>/dev/null || true
        for _ in $(seq 1 60); do "${SSH[@]}" "exit 0" 2>/dev/null || break; sleep 2; done  # until it's going down
        wait_ssh && echo "win11 is back up"
        ;;
    reset)
        "$0" stop
        qemu-img snapshot -a "${2:-browser}" "$DISK"
        "$0" start
        ;;
    ssh)
        shift
        "${SSH[@]}" "$@"
        ;;
    sync)
        repo="${2:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
        "${SSH[@]}" "Remove-Item C:\\alttabsucks -Recurse -Force -ErrorAction SilentlyContinue; New-Item C:\\alttabsucks -ItemType Directory | Out-Null"
        git -C "$repo" ls-files -z --cached --others --exclude-standard \
            | (cd "$repo" && tar -cf - --null -T -) \
            | "${SSH[@]}" "tar -xf - -C C:\\alttabsucks"
        echo "synced $repo -> C:\\alttabsucks"
        ;;
    resolution)
        size="${2:-1920x1080}"
        tar -cf - -C "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../tests/windows" set-resolution.ps1 \
            | "${SSH[@]}" "New-Item C:\\vm-tools -ItemType Directory -Force | Out-Null; tar -xf - -C C:\\vm-tools"
        # On the desktop, through a one-off task: display settings can't be changed from SSH.
        "${SSH[@]}" "\$u = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            \$a = New-ScheduledTaskAction -Execute \"\$env:LOCALAPPDATA\\Microsoft\\WindowsApps\\pwsh.exe\" -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\\vm-tools\\set-resolution.ps1 -Width ${size%x*} -Height ${size#*x}'
            Register-ScheduledTask -TaskName vm-resolution -Action \$a -Principal (New-ScheduledTaskPrincipal -UserId \$u -LogonType Interactive -RunLevel Highest) -Force | Out-Null
            Remove-Item \"\$env:TEMP\\set-resolution.txt\" -ErrorAction SilentlyContinue
            Start-ScheduledTask vm-resolution
            for (\$i = 0; \$i -lt 60 -and -not (Test-Path \"\$env:TEMP\\set-resolution.txt\"); \$i++) { Start-Sleep -Milliseconds 500 }
            Unregister-ScheduledTask vm-resolution -Confirm:\$false
            Get-Content \"\$env:TEMP\\set-resolution.txt\" -ErrorAction SilentlyContinue
            Get-CimInstance Win32_VideoController | ForEach-Object { 'now ' + \$_.CurrentHorizontalResolution + 'x' + \$_.CurrentVerticalResolution }"
        ;;
    snapshot)
        running && { echo "stop the VM first" >&2; exit 1; }
        qemu-img snapshot -c "${2:?snapshot name}" "$DISK"
        qemu-img snapshot -l "$DISK"
        ;;
    *)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
