#!/bin/sh
# Maze Linux — prepare the Calamares OFFLINE target before initcpiocfg/initcpio/
# bootloader run. Called by the `shellprocess@mountapi` step (un-chrooted) with
# the target mountpoint as $1 (Calamares substitutes ${ROOT}). The logic lives in
# this script so Calamares never tries to expand the internal $R/$d shell vars.
#
# It does three things, all needed because the OFFLINE model copies the WHOLE
# live archiso system onto the target via unpackfs:
#
#   1) Mount /dev /proc /sys /run into the target. Calamares runs initcpiocfg/
#      initcpio/bootloader via a PLAIN chroot (not arch-chroot), so without these
#      mkinitcpio aborts with "==> ERROR: /dev must be mounted!".
#
#   2) De-archiso the target's mkinitcpio. unpackfs copied the LIVE preset
#      (/etc/mkinitcpio.d/*.preset set to the 'archiso' preset) and
#      /etc/mkinitcpio.conf.d/archiso.conf — these build the LIVE ISO image and
#      fail on an installed system. Remove the conf.d override and rewrite each
#      preset to a stock (default + fallback) preset so a NORMAL initramfs builds.
#
#   3) Ensure the kernel image is in the target /boot. mkarchiso often keeps
#      vmlinuz only on the boot medium, not in the squashfs, so /boot/vmlinuz-*
#      can be missing on the target. Copy it from /usr/lib/modules/<kver>/vmlinuz
#      (always present in the squashfs) to /boot/vmlinuz-<pkgbase>.
#
# Idempotent; the `umount` module tears the mounts down later.
set -e

R="$1"
[ -n "$R" ] || { echo "calamares-prepare-target: no target root given" >&2; exit 1; }
# This script mounts pseudo-filesystems under $R and deletes $R/home/maze. With
# R="/" that becomes the LIVE system: its /home/maze (the running live user's
# home) would be erased and the pseudo-mounts stacked onto the host. The check
# above only rejects an empty argument, so bar "/" too — stripping the trailing
# slash first collapses a bare "/" (and "//") to "", which the test then catches.
R="${R%/}"
[ -n "$R" ] && [ "$R" != "/" ] || {
    echo "calamares-prepare-target: refusing to operate on '/' (the live system)" >&2
    exit 1
}
[ -d "$R" ] || { echo "calamares-prepare-target: target '$R' is not a directory" >&2; exit 1; }

# --- 1) API/pseudo filesystems --------------------------------------------
# Mount FRESH pseudo-filesystems (exactly like arch-chroot), NOT `mount --rbind`
# of the live ones. An rbind inherits shared mount propagation, so when these are
# later torn down (or a failed install leaves them), the unmount propagates BACK
# to the live system and unmounts its /dev/pts — which breaks pty allocation in
# the live session ("sudo: unable to allocate pty: No such device"). Fresh,
# private instances never touch the host.
mountpoint -q "$R/proc"     || mount -t proc     proc   "$R/proc"     -o nosuid,noexec,nodev
mountpoint -q "$R/sys"      || mount -t sysfs    sys    "$R/sys"      -o nosuid,noexec,nodev
mountpoint -q "$R/dev"      || mount -t devtmpfs udev   "$R/dev"      -o mode=0755,nosuid
mkdir -p "$R/dev/pts" "$R/dev/shm"
mountpoint -q "$R/dev/pts"  || mount -t devpts   devpts "$R/dev/pts"  -o mode=0620,gid=5,nosuid,noexec
mountpoint -q "$R/dev/shm"  || mount -t tmpfs    shm    "$R/dev/shm"  -o mode=1777,nosuid,nodev
mountpoint -q "$R/run"      || mount -t tmpfs    run    "$R/run"      -o mode=0755,nosuid,nodev
# efivarfs so bootctl / kernel-install can read EFI variables (UEFI installs).
if [ -d /sys/firmware/efi/efivars ]; then
    mountpoint -q "$R/sys/firmware/efi/efivars" \
        || mount -t efivarfs efivarfs "$R/sys/firmware/efi/efivars" 2>/dev/null || true
fi

# --- 2) Replace the archiso mkinitcpio setup with a stock one -------------
rm -f "$R/etc/mkinitcpio.conf.d/archiso.conf"
# EVERY preset, not just the archiso one. The guard here used to be
# `grep -q archiso "$preset" || continue`, written when `linux` was the only
# kernel on the medium — and mkarchiso only marks THAT preset with 'archiso'.
# The day maze-meta started pulling linux-lts, its stock preset sailed straight
# past the filter, `mkinitcpio -P` on the target tried to build it, and because
# /boot is the freshly formatted ESP there is no /boot/vmlinuz-linux-lts to
# build from. mkinitcpio does not skip a preset it cannot satisfy: it aborts the
# whole run and exits 1, which failed the Calamares job and therefore the entire
# installation — the exact error this file's own comment predicted.
#
# The reasoning below applies to every kernel on a layout=uki system, so apply it
# to every preset.
for preset in "$R"/etc/mkinitcpio.d/*.preset; do
    [ -f "$preset" ] || continue
    k=$(basename "$preset" .preset)        # e.g. 'linux'
    echo "calamares-prepare-target: restoring stock mkinitcpio preset for $k"
    cat > "$preset" <<PRESET
# mkinitcpio preset for '$k' — Maze Linux (replaces the archiso preset).
#
# Maze boots ONLY Unified Kernel Images: /etc/kernel/install.conf ships
# layout=uki, so the artifact the firmware actually loads is
# \$ESP/EFI/Linux/<machine-id>-<kver>.efi, built by 'kernel-install add'.
# kernel-install's own mkinitcpio plugin (50-mkinitcpio.install) invokes
# mkinitcpio directly with -k/-g and never reads this preset, so the loose
# /boot/initramfs-*.img a normal preset produces are NEVER booted here. And
# because /boot IS the FAT32 ESP on a Maze install, generating them burns
# ~250-400 MB of it on every kernel update for nothing.
#
# The preset this replaces also carried ALL_kver="/boot/vmlinuz-$k". On a UKI
# system that path is not guaranteed to exist, and when it is missing
# 'mkinitcpio -P' does not skip the preset — it aborts the whole run with
#     ==> ERROR: Invalid option -k -- '/boot/vmlinuz-$k' is an invalid path
# and exits 1, taking every caller down with it (deploy-to-target.sh and
# maze-gpu-driver both call it and both only 'warn' on failure).
#
# An EMPTY PRESETS makes 'mkinitcpio -P' a clean no-op — it exits 0 with an
# informational warning — while kernel-install keeps building the real UKI.
# If Maze ever moves off layout=uki, uncomment the lines below to restore a
# conventional BLS-style preset.
ALL_config="/etc/mkinitcpio.conf"
PRESETS=()
#ALL_kver="/boot/vmlinuz-$k"
#PRESETS=('default' 'fallback')
#default_image="/boot/initramfs-$k.img"
#fallback_image="/boot/initramfs-$k-fallback.img"
#fallback_options="-S autodetect"

# mkinitcpio SOURCES this file, so everything below runs on every 'mkinitcpio -P'.
#
# With PRESETS=() that command exits 0 having done nothing, and prints only
# "Preset file is empty or does not contain any presets" — which, after a
# boot-critical edit to mkinitcpio.conf or /etc/kernel/cmdline, reads exactly
# like success. The user reboots and nothing has changed, or worse, trusts a
# risky change they believe is live. Being inert is correct here; being SILENT
# about it is not. Say what actually happened and name the command that works.
#
# mkinitcpio's process_preset is a SUBSHELL function (it is declared with
# parentheses, not braces), so no variable can carry state from one preset to
# the next and a print-once guard is impossible. This therefore prints once per
# installed kernel — which is the right place anyway: directly beside each
# "Preset file is empty" warning it explains. Kept to three lines for that reason.
echo "==> NOTE (Maze Linux): this does NOT rebuild your boot images. Maze boots" >&2
echo "==>   Unified Kernel Images (layout=uki), so presets are empty by design." >&2
echo "==>   Rebuild + re-sign with:  sudo maze-initramfs-rebuild" >&2
PRESET
done

# --- 3) (removed) /boot/vmlinuz-<pkgbase> copy ----------------------------
# This used to copy the kernel out of /usr/lib/modules into the target /boot so
# the restored preset's ALL_kver="/boot/vmlinuz-<pkgbase>" could resolve. That
# preset is gone (PRESETS=() above), and nothing else reads the file:
#   * Calamares' bootloader module walks /usr/lib/modules and calls
#     `kernel-install add <kver> /usr/lib/modules/<kver>/vmlinuz` directly;
#   * kernel-install's mkinitcpio plugin is passed the kernel image explicitly;
#   * maze-sb-sign only globs it opportunistically.
# Keeping it would put a 17 MB image on the FAT32 ESP that nothing boots and
# nothing refreshes — so after the first kernel upgrade it would sit there
# stale, and maze-sb-sign would keep signing a kernel that is no longer current.

# --- 4) Purge the live 'maze' user's leftover home ------------------------
# unpackfs copied the live user 'maze' and its /home/maze. The `removeuser`
# module (later in the sequence) drops the ACCOUNT, but we must remove the home
# HERE — BEFORE the `users` module creates the real account — so that even if the
# installer's new user is ALSO named 'maze' it gets a FRESH skel home instead of
# inheriting the live session's config (and so deploy-to-target never has to, and
# must never, delete a real user's home).
rm -rf "$R/home/maze"

echo "calamares-prepare-target: target prepared under $R"
