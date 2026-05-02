#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow
# SPDX-License-Identifier: Apache-2.0
#
# cixmini-gen — reproducible nclawzero-distro image builder for the
# Minisforum MS-R1 (Cix Sky1 / CP8180).
#
# This is v0 of cix-gen (a pi-gen-style stages builder is the planned
# follow-up) — single shell script, idempotent, runs on any aarch64
# Linux host with sudo, debootstrap, qemu-user-static (if cross-host).
#
# USAGE
#   cixmini-gen.sh --target /dev/nvme0n1 [--debs-dir /path/to/cix-debs] \
#                  [--kernel-image /path/to/Image-cixmini.bin] \
#                  [--kernel-modules /path/to/modules-cixmini.tgz]
#
# REQUIREMENTS
#   - aarch64 Linux env (or amd64 with qemu-aarch64-static for emulation)
#   - sudo
#   - debootstrap, dosfstools, e2fsprogs, parted, util-linux
#   - Internet access for debootstrap + apt install
#   - The Cix proprietary .debs bundle (from dpkg-repack of a stock Cix
#     image, or downloaded from the cixmini-gen-assets release artifact)
#   - Our linux-cix-msr1 6.6.10 kernel binary + modules tarball (built via
#     gitlab.com/nclawzero/meta-cix branch feat/msr1-rebake-2026-05-01)
#
# WHAT IT BUILDS
#   - Debian 12 (bookworm) arm64 base via debootstrap
#   - Cix Sky1 closed-source userspace (35+ cix-* .debs, dpkg -i'd in)
#   - GNOME desktop (gnome-core + gdm3 + nautilus + chromium +
#     gnome-remote-desktop)
#   - linux-cix-msr1 6.6.10 kernel + modules (replaces Cix's stock kernel)
#   - nclawzero agent stack (zeroclaw + openclaw + hermes podman quadlets,
#     auto-start on boot)
#   - Claude Code CLI (npm install of @anthropic-ai/claude-code)
#   - nclawzero distro identity (/etc/os-release, motd)
#   - ncz operator user with NOPASSWD sudo
#
# IDEMPOTENCY
#   Re-running this script on the same target is destructive — the device
#   is wiped and rebuilt. Use --skip-wipe to layer onto an existing fs (for
#   incremental updates).

set -euo pipefail

# ------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------
TARGET=""
DEBS_DIR=""
KERNEL_IMAGE=""
KERNEL_MODULES=""
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
HOSTNAME="cixmini"
NCZ_USER="ncz"
NCZ_PASSWORD="Gumbo@Kona1b"
SKIP_WIPE=0

# ------------------------------------------------------------------------
# Args
# ------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --debs-dir) DEBS_DIR="$2"; shift 2 ;;
        --kernel-image) KERNEL_IMAGE="$2"; shift 2 ;;
        --kernel-modules) KERNEL_MODULES="$2"; shift 2 ;;
        --debian-suite) DEBIAN_SUITE="$2"; shift 2 ;;
        --debian-mirror) DEBIAN_MIRROR="$2"; shift 2 ;;
        --hostname) HOSTNAME="$2"; shift 2 ;;
        --skip-wipe) SKIP_WIPE=1; shift ;;
        -h|--help) sed -n '4,40p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -z "$TARGET" ] && { echo "ERROR: --target required" >&2; exit 1; }
[ ! -b "$TARGET" ] && { echo "ERROR: $TARGET is not a block device" >&2; exit 1; }
[ -z "$DEBS_DIR" ] && { echo "ERROR: --debs-dir required" >&2; exit 1; }
[ ! -d "$DEBS_DIR" ] && { echo "ERROR: $DEBS_DIR not a directory" >&2; exit 1; }
[ -z "$KERNEL_IMAGE" ] && { echo "ERROR: --kernel-image required" >&2; exit 1; }
[ ! -f "$KERNEL_IMAGE" ] && { echo "ERROR: $KERNEL_IMAGE not a file" >&2; exit 1; }
[ -z "$KERNEL_MODULES" ] && { echo "ERROR: --kernel-modules required" >&2; exit 1; }
[ ! -f "$KERNEL_MODULES" ] && { echo "ERROR: $KERNEL_MODULES not a file" >&2; exit 1; }

# ------------------------------------------------------------------------
# Sanity: must be root (debootstrap, mount, mkfs)
# ------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (use sudo)" >&2; exit 1
fi

# ------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------
MNT="/mnt/cixmini-target"
ESP_PART="${TARGET}p1"
ROOT_PART="${TARGET}p2"

log()  { printf "\n\033[1;36m[cixmini-gen]\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31m[cixmini-gen FAIL]\033[0m %s\n" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------
# Stage 0: wipe + partition + mkfs
# ------------------------------------------------------------------------
stage_partition() {
    log "Stage 0: wipe + partition $TARGET"

    # Make sure nothing's mounted
    for mp in $(mount | awk -v t="$TARGET" '$1 ~ t {print $3}' | sort -r); do
        umount -R "$mp" 2>/dev/null || true
    done

    if [ "$SKIP_WIPE" -eq 0 ]; then
        wipefs -a "$TARGET" || true
        sgdisk -o "$TARGET"
        sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:boot "$TARGET"
        sgdisk -n 2:0:0     -t 2:8300 -c 2:root "$TARGET"
        partprobe "$TARGET"
        sleep 1
    fi

    mkfs.vfat -F 32 -n boot "$ESP_PART"
    mkfs.ext4 -F -L root "$ROOT_PART"
}

# ------------------------------------------------------------------------
# Stage 1: debootstrap Debian Bookworm arm64
# ------------------------------------------------------------------------
stage_debootstrap() {
    log "Stage 1: debootstrap $DEBIAN_SUITE arm64 to $MNT"
    mkdir -p "$MNT"
    mount "$ROOT_PART" "$MNT"
    mkdir -p "$MNT/boot/efi"
    mount "$ESP_PART" "$MNT/boot/efi"

    debootstrap --arch=arm64 \
        --include=systemd,systemd-sysv,init,locales,sudo,openssh-server,ca-certificates,gpg,curl,wget,nano,vim-tiny,bash-completion \
        "$DEBIAN_SUITE" "$MNT" "$DEBIAN_MIRROR"
}

# ------------------------------------------------------------------------
# Stage 2: bind mounts + chroot helper
# ------------------------------------------------------------------------
stage_bind() {
    log "Stage 2: bind /dev /proc /sys /run + resolv.conf into chroot"
    for d in dev proc sys run dev/pts; do
        mount --bind "/$d" "$MNT/$d"
    done
    cp /etc/resolv.conf "$MNT/etc/resolv.conf"
}

chroot_run() {
    chroot "$MNT" /bin/bash -c "$*"
}

# ------------------------------------------------------------------------
# Stage 3: system config (apt sources, timezone, locale, hostname)
# ------------------------------------------------------------------------
stage_sysconfig() {
    log "Stage 3: apt sources + locale + hostname"

    cat > "$MNT/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main contrib non-free non-free-firmware
EOF

    echo "$HOSTNAME" > "$MNT/etc/hostname"
    cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # Locale: en_US.UTF-8
    chroot_run "echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen && locale-gen && update-locale LANG=en_US.UTF-8"

    chroot_run "apt-get update -q"
}

# ------------------------------------------------------------------------
# Stage 4: GNOME desktop + chromium + tools
# ------------------------------------------------------------------------
stage_desktop() {
    log "Stage 4: install GNOME desktop + chromium + Wayland"

    chroot_run "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gnome-core gdm3 nautilus chromium gnome-remote-desktop \
        gnome-terminal gnome-system-monitor gnome-text-editor gnome-disk-utility \
        gnome-keyring network-manager-gnome network-manager \
        pipewire wireplumber pulseaudio pavucontrol \
        fonts-dejavu fonts-liberation fonts-noto \
        xdg-utils xdg-user-dirs polkit-1-auth-agent-gnome"

    # gdm autostarts on graphical.target
    chroot_run "systemctl set-default graphical.target"
}

# ------------------------------------------------------------------------
# Stage 5: Cix proprietary userspace (35+ closed-source .debs)
# ------------------------------------------------------------------------
stage_cix_proprietary() {
    log "Stage 5: install Cix Sky1 closed-source userspace"

    mkdir -p "$MNT/var/cache/nclawzero/cix-debs"
    cp -a "$DEBS_DIR"/*.deb "$MNT/var/cache/nclawzero/cix-debs/"

    # Skip Cix's kernel debs — we install our own.
    chroot_run "cd /var/cache/nclawzero/cix-debs && \
        rm -f linux-image-*-cix-build-generic_*.deb \
              linux-headers-*-cix-build-generic_*.deb && \
        dpkg -i *.deb || apt-get install -fy"
}

# ------------------------------------------------------------------------
# Stage 6: install our linux-cix-msr1 6.6.10 kernel + modules
# ------------------------------------------------------------------------
stage_kernel() {
    log "Stage 6: install our kernel (linux-cix-msr1 6.6.10)"

    # Our KERNEL_LOCALVERSION = -cix-build-generic, on top of base 6.6.10-cix-build,
    # produces uname-r 6.6.10-cix-build-cix-build-generic.
    KVER="6.6.10-cix-build-cix-build-generic"

    cp "$KERNEL_IMAGE" "$MNT/boot/vmlinuz-$KVER"
    chroot_run "mkdir -p /lib/modules/$KVER"
    tar xzf "$KERNEL_MODULES" -C "$MNT/" --strip-components=0
    chroot_run "depmod -a $KVER"
}

# ------------------------------------------------------------------------
# Stage 7: systemd-boot + UEFI entry
# ------------------------------------------------------------------------
stage_bootloader() {
    log "Stage 7: systemd-boot install + UEFI entry"

    chroot_run "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd-boot systemd-boot-efi efibootmgr"

    # Install systemd-boot to ESP
    chroot_run "bootctl install --esp-path=/boot/efi || bootctl install --esp-path=/boot/efi --no-variables"

    # Loader entry — note we have no initramfs; kernel mounts root directly
    # via root=PARTUUID=...
    ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")
    cat > "$MNT/boot/efi/loader/loader.conf" <<EOF
default nclawzero
timeout 3
console-mode auto
editor yes
EOF

    cat > "$MNT/boot/efi/loader/entries/nclawzero.conf" <<EOF
title nclawzero (cixmini)
linux /vmlinuz-6.6.10-cix-build-cix-build-generic
options root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 console=tty0 console=ttyAMA0,115200 earlycon clk_ignore_unused fbcon=map:0
EOF

    # Copy kernel into ESP (systemd-boot reads from /boot/efi by default)
    cp "$KERNEL_IMAGE" "$MNT/boot/efi/vmlinuz-6.6.10-cix-build-cix-build-generic"
}

# ------------------------------------------------------------------------
# Stage 8: nclawzero agent stack (3 quadlets + agent-env)
# ------------------------------------------------------------------------
stage_agents() {
    log "Stage 8: agent stack (zeroclaw + openclaw + hermes + claude-code)"

    chroot_run "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        podman crun conmon netavark aardvark-dns catatonit \
        nodejs npm"

    mkdir -p "$MNT/etc/containers/systemd" "$MNT/etc/nclawzero"

    # Quadlet files (zeroclaw v0.7.4, openclaw, hermes — each pinned by sha256)
    if [ -d "$ASSETS_DIR/agent-stack" ]; then
        cp "$ASSETS_DIR/agent-stack/zeroclaw.container" "$MNT/etc/containers/systemd/"
        cp "$ASSETS_DIR/agent-stack/openclaw.container" "$MNT/etc/containers/systemd/"
        cp "$ASSETS_DIR/agent-stack/hermes.container" "$MNT/etc/containers/systemd/"
        cp "$ASSETS_DIR/agent-stack/hermes-isolated.network" "$MNT/etc/containers/systemd/"
        cp "$ASSETS_DIR/agent-stack/agent-env.sample" "$MNT/etc/nclawzero/agent-env"
        chmod 0640 "$MNT/etc/nclawzero/agent-env"
    fi

    # Stub the load-images service (defer to podman registry pull on first boot)
    cat > "$MNT/etc/systemd/system/nclawzero-load-agent-images.service" <<'UNIT'
[Unit]
Description=Stub: defer agent OCI image load to podman registry pull
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    chroot_run "systemctl enable nclawzero-load-agent-images.service"

    # Claude Code via npm (network needed in chroot — works because we
    # bind-mounted /etc/resolv.conf in stage_bind).
    chroot_run "npm install -g @anthropic-ai/claude-code" || \
        log "WARN: claude-code npm install deferred — run manually post-boot"
}

# ------------------------------------------------------------------------
# Stage 9: ncz user + sshd config
# ------------------------------------------------------------------------
stage_user() {
    log "Stage 9: $NCZ_USER user + sudo + sshd"

    chroot_run "useradd -m -s /bin/bash -G sudo,disk,dialout,plugdev,audio,video,input,render,netdev,users $NCZ_USER || true"
    chroot_run "echo '$NCZ_USER:$NCZ_PASSWORD' | chpasswd"
    chroot_run "echo 'root:$NCZ_PASSWORD' | chpasswd"

    cat > "$MNT/etc/sudoers.d/00-${NCZ_USER}-nopasswd" <<EOF
$NCZ_USER ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$MNT/etc/sudoers.d/00-${NCZ_USER}-nopasswd"

    chroot_run "systemctl enable ssh"
}

# ------------------------------------------------------------------------
# Stage 10: nclawzero distro identity
# ------------------------------------------------------------------------
stage_branding() {
    log "Stage 10: /etc/os-release nclawzero branding"

    cat > "$MNT/etc/os-release" <<EOF
PRETTY_NAME="nclawzero (cixmini) 2026.05"
NAME="nclawzero"
VERSION_ID="2026.05"
VERSION="2026.05 (cixmini)"
VERSION_CODENAME=cixmini
ID=nclawzero
ID_LIKE=debian
HOME_URL="https://gitlab.com/nclawzero"
SUPPORT_URL="https://gitlab.com/nclawzero/cix-gen/-/issues"
DEBIAN_DERIVATIVE=true
EOF

    cat > "$MNT/etc/motd" <<'EOF'
   ┌─────────────────────────────────────────────────────────┐
   │  nclawzero (cixmini)  —  Cix Sky1 / CP8180 edge agent   │
   │                                                         │
   │  Agents:  zeroclaw · openclaw · hermes · claude-code    │
   │  Kernel:  linux-cix-msr1 6.6.10 (Yocto-built)           │
   │  GPU:     Mali-G720 (cix-gpu-umd)                       │
   │  NPU:     45 TOPS (cix-noe-umd / cix-llama-cpp)         │
   └─────────────────────────────────────────────────────────┘
EOF
}

# ------------------------------------------------------------------------
# Stage 11: cleanup
# ------------------------------------------------------------------------
stage_cleanup() {
    log "Stage 11: cleanup + sync + unmount"

    rm -f "$MNT/etc/resolv.conf"
    chroot_run "ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true"

    chroot_run "apt-get clean"

    sync
    for d in dev/pts dev proc sys run; do
        umount "$MNT/$d" 2>/dev/null || true
    done
    umount "$MNT/boot/efi"
    umount "$MNT"
}

# ------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------
ASSETS_DIR="${ASSETS_DIR:-$(dirname "$0")/assets}"

stage_partition
stage_debootstrap
stage_bind
stage_sysconfig
stage_desktop
stage_cix_proprietary
stage_kernel
stage_bootloader
stage_agents
stage_user
stage_branding
stage_cleanup

log "DONE — reboot to boot nclawzero on $TARGET"
