# No systemd-boot BLS entries to patch: /etc/kernel/install.conf ships
# layout=uki, so kernel-install never writes loader/entries/*.conf — the full
# PARAMS set is already embedded in the UKI via /etc/kernel/cmdline (written
# above, before the mkinitcpio -P + kernel-install rebuild below).

# Maze is UEFI-only (the ISO ships no BIOS bootmode — see profiledef.sh), so this
# always runs on a UEFI/systemd-boot install: the kernel is a UKI on the FAT32 ESP
# and layout=uki is correct. The former BIOS-only blocks here — disabling
# layout=uki, marking /boot uncompressed so GRUB's i386-pc btrfs driver could read
# the zstd-compressed kernel ("premature end of file /@/boot/vmlinuz-linux"), and
# GRUB menu branding/theme — were removed with BIOS support. Secure Boot (a
# flagship feature) is UEFI-only anyway, and no BIOS bootloader reads zstd-btrfs
# reliably, so the fix was to drop BIOS rather than nurse a fragile GRUB path.

# 5b) Secure Boot (shim + per-machine MOK). Runs AFTER the kernel/initramfs and
# bootloader are in place so there are artifacts to sign, and BEFORE the AUR/app
# phase so the pacman re-sign hook is already active when those rebuild the
# initramfs. A final re-sign runs at the very end (after AUR). Best-effort.
setup_secure_boot

# (There used to be a "5b-bis" re-sign block here. It duplicated — with its own
# hand-rolled, non-atomic sbsign — the exact `in_chroot maze-sb-sign
# --force-bootloader <esp>` call that setup_secure_boot() itself makes as its
# final step, with nothing touching the UKI in between. Removed: the internal
# call already covers it, and the final re-sign after the AUR phase (step 12)
# catches everything that changes later.)

