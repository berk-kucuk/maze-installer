#!/bin/sh
# Maze Linux — keep the LUKS keyfile OUT of the initramfs (and so out of the UKI).
#
# Called by the `shellprocess@stripkeyfile` step (un-chrooted) right after
# `initcpiocfg` and before `initcpio`/`bootloader`, with the target mountpoint
# as $1 (Calamares substitutes ${ROOT}).
#
# WHY: Calamares' `luksbootkeyfile` creates /crypto_keyfile.bin whenever /boot
# is NOT a separate unencrypted partition, and `initcpiocfg` then lists it in
# mkinitcpio's FILES=(). That design assumes GRUB unlocks an encrypted /boot,
# so the initramfs sits inside the encrypted volume. Maze boots Unified Kernel
# Images from the FAT32 ESP instead — nothing there is encrypted. With a manual
# layout that mounts the ESP at /efi (no separate /boot), the keyfile would be
# embedded in a UKI anyone can read off the ESP, and the busybox `encrypt` hook
# uses /crypto_keyfile.bin automatically, so the disk would also unlock without
# ever asking for the passphrase.
#
# The keyfile itself stays on the encrypted root: /etc/crypttab still uses it to
# unlock any OTHER encrypted partitions (e.g. a separate /home) after root is
# open, which is exactly where it is safe. Only the initramfs copy is removed.
#
# The default Maze layout (ESP at /boot) never hits this — initcpiocfg already
# skips the keyfile there — so on a normal install this is a no-op. Idempotent.
set -eu

R="${1:-}"
R="${R%/}"
[ -n "$R" ] && [ "$R" != "/" ] || {
    echo "calamares-strip-keyfile: refusing to operate on '${1:-}' (empty or the live system)" >&2
    exit 1
}
conf="$R/etc/mkinitcpio.conf"
[ -f "$conf" ] || { echo "calamares-strip-keyfile: $conf not found; nothing to do"; exit 0; }

if grep -qE '^[[:space:]]*FILES=\([^)]*/crypto_keyfile\.bin' "$conf"; then
    sed -i -E '/^[[:space:]]*FILES=\(/ s#[[:space:]]*"?/crypto_keyfile\.bin"?##' "$conf"
    if grep -qE '^[[:space:]]*FILES=\([^)]*/crypto_keyfile\.bin' "$conf"; then
        echo "calamares-strip-keyfile: could not remove /crypto_keyfile.bin from FILES in $conf" >&2
        exit 1
    fi
    echo "calamares-strip-keyfile: removed /crypto_keyfile.bin from the initramfs FILES (UKI lives on the unencrypted ESP)"
else
    echo "calamares-strip-keyfile: no LUKS keyfile in the initramfs FILES; nothing to do"
fi
