#!/usr/bin/env bash
# install-arch.sh - installs the Linux test VM's system from the Arch live ISO (run as root there,
# over SSH: see tests/linux/README.md). Minimal Arch + Plasma (plasma-desktop, not the whole
# plasma group), SDDM logging "tester" straight into a Plasma Wayland session, SSH with the VM's
# key for root and tester, and what AltTabSucks needs. UEFI, systemd-boot, one ext4 root.
# Usage: install-arch.sh "<ssh public key>"
set -euo pipefail
KEY="$1"
DISK=/dev/vda
USER_NAME=tester

timedatectl set-ntp true
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8304 -c2:root "$DISK"
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F -q "${DISK}2"
mount "${DISK}2" /mnt
mount --mkdir "${DISK}1" /mnt/boot

# The packages: a base system; Plasma's desktop, SDDM, Konsole, Dolphin, Kate and KCalc (apps the
# tests start); Chromium for the extension; and AltTabSucks' own dependencies (installer.sh's
# check_deps: kpackage/kconfig/qt6-tools for kpackagetool6/kwriteconfig6/qdbus6, python-dbus,
# python-gobject, gtk4-layer-shell).
pacstrap -K /mnt base linux sudo openssh networkmanager vim \
    plasma-desktop sddm sddm-kcm breeze-gtk konsole dolphin kate kcalc xdg-user-dirs noto-fonts \
    chromium python python-dbus python-gobject gtk4 gtk4-layer-shell qt6-tools kpackage kconfig \
    git socat qemu-guest-agent

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash -e <<CHROOT
ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo alttabsucks-arch > /etc/hostname

bootctl install
cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 0
EOF
cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=PARTLABEL=root rw quiet
EOF

useradd -m -G wheel -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_NAME" | chpasswd
echo "root:root" | chpasswd
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
for home in /root /home/$USER_NAME; do
    mkdir -p \$home/.ssh
    echo "$KEY" > \$home/.ssh/authorized_keys
    chmod 700 \$home/.ssh
    chmod 600 \$home/.ssh/authorized_keys
done
chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.ssh

# Straight into a Plasma Wayland session, every boot.
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USER_NAME
Session=plasma
Relogin=false
EOF

systemctl enable sshd NetworkManager sddm qemu-guest-agent
CHROOT

# Plasma settings for tester: dark theme, no screen locking or power-off during long test runs.
install -d -o 1000 -g 1000 /mnt/home/$USER_NAME/.config
cat > /mnt/home/$USER_NAME/.config/kdeglobals <<EOF
[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
EOF
cat > /mnt/home/$USER_NAME/.config/kscreenlockerrc <<EOF
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
EOF
cat > /mnt/home/$USER_NAME/.config/powerdevilrc <<EOF
[AC][Display]
TurnOffDisplayWhenIdle=false
DimDisplayWhenIdle=false
[AC][SuspendAndShutdown]
AutoSuspendAction=0
EOF
chown -R 1000:1000 /mnt/home/$USER_NAME/.config

umount -R /mnt
echo "installed"
