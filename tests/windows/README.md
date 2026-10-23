# Windows test VM

`dev-scripts/run-windows-tests.sh` runs the AHK and PowerShell suites, and the end-to-end tests in
this folder, on a real Windows 11 desktop: a local QEMU/KVM VM, set up once as below and driven by
`dev-scripts/windows-vm.sh` over SSH. Every run rolls the VM back to a snapshot, copies in the
working tree (uncommitted changes included) and does a fresh install, so runs don't affect each
other. A full run takes about 3 minutes.

What `e2e.ps1` covers: the installer and first-run dialogs (answered by `drive-first-run.ahk`),
starter hotkeys, the Hotkeys UI API and the page itself in Edge (driven through the DevTools
protocol by `cdp.ps1`), save → reload and broken edit → no reload, the `hotkeys.json` fold-in, tab
focus / profile cycling / split / merge through the extension in Edge (keys pressed by
`press.ahk`), launching Edge when it's closed, folder hotkeys against real Explorer
(`explorer-mash.ahk`), and uninstall.

SSH sessions have no desktop, so `e2e.ps1` launches anything that needs one through a one-off
scheduled task on the logged-on user's session (`Start-OnDesktop`). Don't click in the VM window
during a run; that can steal focus mid-test.

## One-time setup (Linux host)

Tested on Arch/CachyOS with KVM. About 30 minutes, mostly the Windows install.

1. **Host packages**: `sudo pacman -S swtpm qemu-desktop` and `quickemu` from the AUR
   (`paru -S quickemu`). `qemu-base` alone isn't enough: quickemu needs the audio, display and
   SPICE modules `qemu-desktop` pulls in, and QEMU segfaults instead of saying which is missing.

2. **Create the VM** in `~/VMs` (or set `ALTTABSUCKS_VM_DIR` everywhere below):

   ```bash
   mkdir -p ~/VMs && cd ~/VMs && quickget windows 11
   ```

   - If Microsoft blocks the ISO download (quickget says so), download the Windows 11 ISO in a
     browser from microsoft.com/software-download/windows11 and link it in:
     `ln -s ~/Downloads/Win11_*.iso windows-11/windows-11.iso`. The regular multi-edition ISO is
     what's wanted; the VM runs unactivated (quickget's answer file installs Pro with Microsoft's
     generic setup key, which doesn't activate).
   - If `windows-11/virtio-win.iso` is a few KB, it's a bot-check page, not the drivers:
     `curl -fL -o windows-11/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`

   Then append to `windows-11.conf`:

   ```bash
   cpu_cores="8"
   ram="12G"
   gl="off"
   ```

   (`gl="off"`: Windows can't use VirGL anyway, and it avoids GL crashes on some host GPUs.)

3. **Install Windows**: `cd ~/VMs && quickemu --vm windows-11.conf`. Press Enter on the
   language and keyboard screens; the rest is unattended (account `Quickemu`, password
   `quickemu`, auto-login, UAC off) and ends at the desktop after ~15 minutes.

4. **SSH**: make a key for the VM, and an SSH config for `windows-vm.sh`:

   ```bash
   ssh-keygen -q -t ed25519 -N "" -C alttabsucks-test-vm -f ~/VMs/windows-11/id_ed25519
   cat ~/VMs/windows-11/id_ed25519.pub
   cat > ~/VMs/windows-11/ssh_config <<EOF
   Host win11
       HostName localhost
       Port 22220
       User Quickemu
       IdentityFile $HOME/VMs/windows-11/id_ed25519
       IdentitiesOnly yes
       UserKnownHostsFile $HOME/VMs/windows-11/known_hosts
       StrictHostKeyChecking accept-new
       BatchMode yes
       ConnectTimeout 10
       LogLevel ERROR
   EOF
   ```

   In the VM, open PowerShell (Win+R, `powershell`; it's already elevated) and run, with your
   public key pasted in (copy-paste into the VM doesn't work with the GTK display, so type it or
   use QEMU's `sendkey` through `windows-11/windows-11-monitor.socket`):

   ```powershell
   Set-NetConnectionProfile -InterfaceAlias Ethernet -NetworkCategory Private
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Set-Service sshd -StartupType Automatic; Start-Service sshd
   Set-Content C:\ProgramData\ssh\administrators_authorized_keys 'ssh-ed25519 AAAA... alttabsucks-test-vm'
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant Administrators:F /grant SYSTEM:F
   ```

   (Private: the SSH firewall rule only allows the Private profile, and Windows puts the VM's
   network in Public.) Check from the host: `dev-scripts/windows-vm.sh ssh whoami`.

5. **Tools and settings**, from the host:

   ```bash
   V=dev-scripts/windows-vm.sh
   $V ssh 'reg add HKLM\SOFTWARE\OpenSSH /v DefaultShell /t REG_SZ /d C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe /f'
   $V ssh 'foreach ($id in "AutoHotkey.AutoHotkey","Microsoft.PowerShell","Git.Git") { winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity }'
   $V ssh 'Add-MpPreference -ExclusionPath C:\alttabsucks,"C:\Program Files\AutoHotkey"; $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; New-Item $au -Force | Out-Null; Set-ItemProperty $au NoAutoUpdate 1 -Type DWord; Set-ItemProperty $au NoAutoRebootWithLoggedOnUsers 1 -Type DWord'
   $V stop && $V snapshot clean
   ```

   Defender exclusions rather than turning it off: Tamper Protection blocks that from a script.
   Updates off so the VM never restarts itself mid-run.

6. **Edge with the extension** (the `browser` snapshot the tests reset to). The tests use the fixed
   token `alttabsucks-vm-test` (e2e writes it before installing) and Edge's profile name
   `Profile 1`:

   ```bash
   $V start && $V sync
   $V ssh 'Set-Content C:\alttabsucks\Server\token.txt alttabsucks-vm-test -NoNewline -Encoding ASCII'
   ```

   Then in the VM: run `C:\alttabsucks\Install.bat` and pick Edge (No to the default-browser
   question); open Edge, finish or dismiss its welcome pages, go to `edge://extensions`, turn on
   Developer mode, **Load unpacked** → `C:\alttabsucks\BrowserExtension`; in the extension's
   Options pick `Profile 1` and enter the token `alttabsucks-vm-test`. If `Profile 1` isn't in the
   dropdown, press Ctrl+Alt+Shift+' (AltTabSucks reads profiles at startup, before Edge's first run
   created one) and hit ↺. Leave the extension pointing at `C:\alttabsucks\BrowserExtension`. Each run
   replaces that folder, and `e2e.ps1` starts Edge with `--load-extension` pointing at it, because
   Chromium doesn't re-read an unpacked extension's files on its own: until you click Reload on the
   extensions page, it keeps running the copy it loaded before.

   Finally, uninstall AltTabSucks again (runs must start from a fresh install), keep Edge from
   running in the background (it would hold that folder open during a sync), and snapshot:

   ```bash
   $V ssh '& "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe" -File C:\alttabsucks\installer.ps1 -Action uninstall; $e = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"; New-Item $e -Force | Out-Null; Set-ItemProperty $e StartupBoostEnabled 0 -Type DWord; Set-ItemProperty $e BackgroundModeEnabled 0 -Type DWord'
   $V stop && $V snapshot browser
   ```

## Day to day

```bash
bash dev-scripts/run-windows-tests.sh              # reset, sync, all suites (~3 min)
bash dev-scripts/run-windows-tests.sh --no-reset   # unit suites only, on the running VM
dev-scripts/windows-vm.sh ssh                      # a PowerShell prompt in the VM
dev-scripts/windows-vm.sh stop                     # when done
```

To look at the VM's screen without the window, QEMU's monitor can save a screenshot:
`echo "screendump /tmp/vm.ppm" | socat - unix-connect:$HOME/VMs/windows-11/windows-11-monitor.socket`.
