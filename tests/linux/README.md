# Linux test VM

`dev-scripts/run-linux-tests.sh` runs AltTabSucks' Linux side on a small VM: minimal Arch with
Plasma (Wayland), the user `tester` logged straight in by SDDM. Every run rolls the VM back to a
snapshot, copies in the working tree (uncommitted changes included), runs the Python unit suites
there, then `tests/linux/e2e.sh`:

- **install**: `installer.sh install` in the Plasma session, with the browser picker (Chromium,
  its window class confirmed from a real window); the startup manager off, then switched on and
  off through the server's `POST /settings`, and two seeded autostart entries taken over and
  given back
- **real key presses** on the VM's keyboard (QEMU `sendkey`, `linux-vm.sh key`), so hotkeys go
  the whole way through kglobalaccel, the KWin script and the server: the starter Text editor
  (Kate) and Downloads folder (Dolphin, showing ~/Downloads, no second window on a second press)
- **the extension** in Chromium (loaded unpacked from the synced tree) fetching its token by
  itself and reporting its tabs
- **the startup manager**: a `--run` (KCalc by its window, a tray-style app by its process,
  AltTabSucks by the server and KWin script), its history row, and closing itself
- **a reboot** and the real logon: the logon run, each app started once (not again by Plasma's
  autostart), the window closing itself; then **uninstall** giving the autostart entries back

Screenshots and logs go to `$ALTTABSUCKS_TEST_SHOTS` (default `/tmp/alttabsucks-linux-e2e`).
`--no-reset` reuses the running VM and runs only the unit suites. The VM is shut down when the run
ends (passed, failed or interrupted); `--keep-vm` leaves it running to look into a failure.

The VM takes about 5 GB of disk (20 GB thin disk), 2 cores and 4 GB of memory while running.

## One-time setup

Needs `quickemu`/`quickget`, `genisoimage`, `socat` and ImageMagick on the host. The VM lives in
`$ALTTABSUCKS_VM_DIR` (default `~/VMs`), next to the Windows one.

1. **The ISO and VM config:**

   ```bash
   cd ~/VMs && quickget archlinux latest
   cat >> archlinux-latest.conf <<'EOF'
   fixed_iso="archlinux-latest/cidata.iso"
   disk_size="20G"
   cpu_cores="2"
   ram="4G"
   gl="off"
   width="1440"
   height="900"
   EOF
   ```

2. **An SSH key, handed to the live ISO through cloud-init** (the Arch ISO reads a NoCloud
   "cidata" disc), so the install can run over SSH:

   ```bash
   V=~/VMs/archlinux-latest
   ssh-keygen -q -t ed25519 -N "" -C alttabsucks-linux-vm -f $V/id_ed25519
   mkdir -p $V/cidata
   printf 'instance-id: alttabsucks-arch-install\nlocal-hostname: archiso\n' > $V/cidata/meta-data
   printf '#cloud-config\nusers:\n  - name: root\n    ssh_authorized_keys:\n      - %s\n' "$(cat $V/id_ed25519.pub)" > $V/cidata/user-data
   genisoimage -quiet -output $V/cidata.iso -volid cidata -joliet -rock $V/cidata/user-data $V/cidata/meta-data
   ```

3. **Install** (from the repo root): boot the live ISO, then run `tests/linux/install-arch.sh` in
   it. It partitions the disk (UEFI, systemd-boot, ext4), installs Arch with `plasma-desktop`
   (not the whole Plasma group), SDDM autologin into Plasma Wayland, SSH, Chromium, Kate, KCalc,
   Dolphin and AltTabSucks' dependencies, and turns off screen locking:

   ```bash
   (cd ~/VMs && quickemu --vm archlinux-latest.conf)
   P=$(cut -d, -f2 ~/VMs/archlinux-latest/archlinux-latest.ports)
   S="ssh -p $P -i ~/VMs/archlinux-latest/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
   scp -P $P -i ~/VMs/archlinux-latest/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tests/linux/install-arch.sh root@localhost:
   $S "bash install-arch.sh '$(cat ~/VMs/archlinux-latest/id_ed25519.pub)'"
   $S systemctl poweroff
   sed -i '/^iso=/d; /^fixed_iso=/d' ~/VMs/archlinux-latest.conf
   ```

   The kernel's "couldn't mount as ext3/ext2 due to feature incompatibilities" lines on the VM's
   console during the install are normal (it tries the older drivers before ext4).

4. **The screen size, then the `clean` snapshot:**

   ```bash
   V=dev-scripts/linux-vm.sh
   $V start
   $V desktop 'kscreen-doctor output.Virtual-1.mode.1440x900@60'
   $V stop && $V snapshot clean
   ```

5. **Chromium's first run** (its `Default` profile has to exist for the browser picker and
   profile discovery), then the `browser` snapshot the tests reset to:

   ```bash
   $V start
   $V desktop '(chromium --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &); sleep 10; pkill -x chromium'
   $V stop && $V snapshot browser
   ```

## Notes

- **KWallet:** with autologin the wallet stays locked, and Chromium holds every request that
  needs cookies until it gets its key from it (a wallet dialog nobody answers), which looks like
  the extension never connecting. The tests start Chromium with `--password-store=basic`.
- **`--load-extension`** is ignored by recent Chromium unless
  `--disable-features=DisableLoadExtensionCommandLineSwitch` is passed too.
- **`linux-vm.sh desktop`** runs a command inside the Plasma session, with the session's own D-Bus
  and Wayland display (taken from systemd's user environment; the socket isn't always
  `wayland-0`). The installer has to run that way, as it would from a terminal on the desktop: it
  talks to KWin.
- **`tests/linux/cdp.py`** evaluates JavaScript in a Chromium target (a page, or the extension's
  service worker) over the DevTools protocol, with the standard library only. Chromium has to run
  with `--remote-debugging-port`.
- To keep the snapshot current with Arch updates: `$V reset clean`, `$V root 'pacman -Syu --noconfirm'`,
  then redo step 5 and save both snapshots again (`qemu-img snapshot -d` the old names first).
