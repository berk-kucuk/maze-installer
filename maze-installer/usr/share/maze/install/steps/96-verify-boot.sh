# 12) FINAL Secure Boot re-sign. The AUR/app phase can regenerate the initramfs
# AFTER the initial signing (e.g. an nvidia or mkinitcpio pull). Force kernel-install
# to rebuild the UKI (layout=uki) from the CURRENT kernel+initramfs+cmdline, then
# re-sign it via the same locked/atomic in-chroot call as 5b-bis above — not a
# duplicated sbsign, which used to write grubx64.efi directly (no temp+rename,
# no lock) and could leave it truncated if this step were interrupted.
if [[ -n "${MAZE_SB_ESP}" ]]; then
    log "Secure Boot: final re-sign after package install"
    _sb_key="${TARGET}/var/lib/maze-secureboot/MOK.key"
    _sb_crt="${TARGET}/var/lib/maze-secureboot/MOK.crt"
    if [[ -r "${_sb_key}" && -r "${_sb_crt}" ]]; then
        kernel_install_all "Secure Boot final rebuild"
        in_chroot /usr/bin/maze-sb-sign --force-bootloader "${MAZE_SB_ESP}" \
            || warn "Secure Boot: final re-sign reported problems"
    fi
fi

# 12b) Secure Boot verification — CLOSE THE LOOP. Every signing step above is
# best-effort by design (never aborts the install), which means a real failure
# (missing ukify/stub, a sbsign error, …) could otherwise leave the machine
# with an installer that reports "success" but a boot chain that fails
# validation the moment the user enables Secure Boot in firmware — silently,
# with nothing pointing them at why. Explicitly verify the actual on-disk
# state now and make a failure IMPOSSIBLE to miss: loud log lines plus a
# status file. (maze_status.secure_boot_chain_signed() also live-checks this
# same thing later, from the installed system's Security tab — this is the
# install-time half of that same guarantee.)
if [[ -n "${MAZE_SB_ESP}" ]]; then
    _sb_crt="${TARGET}/var/lib/maze-secureboot/MOK.crt"
    _esp_dir="${TARGET}${MAZE_SB_ESP}"
    _shim="${_esp_dir}/EFI/BOOT/BOOTX64.EFI"
    _grub="${_esp_dir}/EFI/BOOT/grubx64.efi"
    _sb_status_file="${TARGET}/var/lib/maze-secureboot/SIGNING-STATUS.txt"
    _sb_ok=1
    _sb_reason=""

    [[ -r "${_sb_crt}" ]] || { _sb_ok=0; _sb_reason="no MOK certificate was generated"; }
    if [[ "${_sb_ok}" -eq 1 ]]; then
        [[ -f "${_shim}" ]] || { _sb_ok=0; _sb_reason="shim (BOOTX64.EFI) was not installed to the ESP"; }
    fi
    if [[ "${_sb_ok}" -eq 1 ]]; then
        [[ -f "${_grub}" ]] || { _sb_ok=0; _sb_reason="grubx64.efi (the signed UKI) was never produced"; }
    fi
    if [[ "${_sb_ok}" -eq 1 ]] && ! sbverify --cert "${_sb_crt}" "${_grub}" >/dev/null 2>&1; then
        _sb_ok=0; _sb_reason="grubx64.efi exists but does NOT verify against the MOK certificate"
    fi

    # --- Does grubx64.efi boot the kernel that is actually installed? --------
    # Every check above can pass on a machine that will not boot at all: a
    # perfectly MOK-signed grubx64.efi built from an OLD kernel's UKI verifies
    # fine, but the kernel inside it has no /usr/lib/modules directory on disk,
    # so not one module loads — vfat included, which is why /boot cannot even be
    # mounted afterwards to work out what happened. Signature validity and boot
    # validity are different questions, and only the first was ever asked here.
    #
    # This failure is also strictly worse than a signing failure: turning Secure
    # Boot off does not rescue it, so it gets its own message.
    _kver_installed="$(
        for _d in "${TARGET}"/usr/lib/modules/*/; do
            [[ -f "${_d}vmlinuz" ]] || continue
            _d="${_d%/}"; printf '%s\n' "${_d##*/}"
        done | sort -V | tail -1
    )"
    _grub_kver=""
    if [[ -f "${_grub}" ]]; then
        _grub_kver="$(objcopy -O binary --only-section=.uname "${_grub}" /dev/stdout 2>/dev/null \
                        | tr -d '\0' | tr -d '[:space:]')"
        if [[ -z "${_grub_kver}" ]]; then
            _grub_kver="$(grep -aoE '[0-9]+\.[0-9]+\.[0-9]+-arch[0-9]+-[0-9]+' "${_grub}" 2>/dev/null \
                            | sort -u | head -1)"
        fi
    fi

    if [[ -z "${_kver_installed}" || -z "${_grub_kver}" ]]; then
        warn "Boot check: could not compare grubx64.efi against the installed kernel (skipped)"
    elif [[ "${_grub_kver}" == "${_kver_installed}" ]]; then
        log "Boot check: grubx64.efi boots ${_grub_kver} — matches the installed kernel"
    elif [[ -d "${TARGET}/usr/lib/modules/${_grub_kver}" ]]; then
        # Mismatched, but the kernel it boots IS installed — the machine comes up,
        # just on an older kernel than the one this install put down. Worth saying,
        # not worth alarming about.
        warn "Boot check: grubx64.efi boots ${_grub_kver}, but ${_kver_installed} is also installed."
        warn "  The system will boot (that kernel's modules are present), just not on the newest kernel."
        warn "  To move it forward: kernel-install add ${_kver_installed} /usr/lib/modules/${_kver_installed}/vmlinuz"
    else
        critical "boot image carries kernel ${_grub_kver}, but ${_kver_installed} is installed — this install will NOT boot (details: /var/lib/maze-secureboot/BOOT-STATUS.txt)"
        warn "=================================================================="
        warn "BOOT CHECK FAILED — this install will NOT boot."
        warn "  grubx64.efi boots kernel : ${_grub_kver}"
        warn "  kernel installed on disk : ${_kver_installed}"
        warn "  ${_grub_kver} has NO modules on disk — nothing will load, not even vfat."
        warn "Turning Secure Boot OFF does NOT help; the boot image itself is wrong."
        warn "Fix from a live/chroot environment:"
        warn "  kernel-install add ${_kver_installed} /usr/lib/modules/${_kver_installed}/vmlinuz"
        warn "  maze-sb-sign ${MAZE_SB_ESP} --force-bootloader"
        warn "=================================================================="
        install -Dm644 /dev/stdin "${TARGET}/var/lib/maze-secureboot/BOOT-STATUS.txt" <<BOOTSTATUS
Maze Linux — boot image does NOT match the installed kernel
=============================================================

  grubx64.efi boots kernel : ${_grub_kver}
  kernel installed on disk : ${_kver_installed}

The ESP is carrying a boot image for a kernel that is not the one installed.
That kernel's modules are not on disk, so nothing loads at boot — including
vfat, which is why /boot cannot be mounted to investigate. Disabling Secure
Boot does NOT work around this.

Boot the live ISO, unlock and mount the install, chroot in, then run:

    kernel-install add ${_kver_installed} /usr/lib/modules/${_kver_installed}/vmlinuz
    maze-sb-sign ${MAZE_SB_ESP} --force-bootloader

Verify before rebooting — these two must report the same version:

    objcopy -O binary --only-section=.uname /boot/EFI/BOOT/grubx64.efi /dev/stdout
    ls /usr/lib/modules/
BOOTSTATUS
    fi

    if [[ "${_sb_ok}" -eq 1 ]]; then
        log "Secure Boot: VERIFIED — grubx64.efi is validly signed (ESP=${MAZE_SB_ESP})"
        rm -f "${_sb_status_file}" 2>/dev/null || true
    else
        warn "=================================================================="
        warn "Secure Boot: SIGNING VERIFICATION FAILED — ${_sb_reason}"
        warn "The system WILL FAIL TO BOOT if Secure Boot is enabled in firmware."
        warn "It boots normally with Secure Boot OFF. Details written to:"
        warn "  /var/lib/maze-secureboot/SIGNING-STATUS.txt"
        warn "Fix from a live/chroot environment: maze-sb-sign ${MAZE_SB_ESP} --force-bootloader"
        warn "=================================================================="
        install -Dm644 /dev/stdin "${_sb_status_file}" <<SBSTATUS
Maze Linux — Secure Boot signing FAILED at install time
=========================================================

Reason: ${_sb_reason}

This machine's boot chain (shim -> grubx64.efi) is NOT validly signed. It will
boot normally as long as Secure Boot stays OFF in firmware. If you enable
Secure Boot, the firmware will refuse to boot with a "Security Violation" (or
similar) error.

To fix it, boot the live ISO (or chroot into this install) and run:

    maze-sb-sign ${MAZE_SB_ESP} --force-bootloader

Then re-check from the installed system:

    sbverify --cert /var/lib/maze-secureboot/MOK.crt /boot/EFI/BOOT/grubx64.efi

This file is removed automatically the next time signing succeeds.
SBSTATUS
    fi
fi

# 12c) LUKS: prove that NO boot image on the ESP carries the keyfile. The config
# checks above are the prevention; this inspects the artifacts the firmware
# actually loads (every UKI plus shim's grubx64.efi and its .maze-prev copy),
# because a keyfile inside any of them hands the disk key to whoever can read the
# unencrypted ESP.
if [[ "${ROOT_IS_LUKS}" -eq 1 ]] && is_uefi; then
    _kf_hits=()
    _kf_checked=0
    _kf_unchecked=0
    shopt -s nullglob
    for _img in "${TARGET}"/boot/EFI/Linux/*.efi "${TARGET}"/efi/EFI/Linux/*.efi \
                "${TARGET}"/boot/EFI/BOOT/grubx64.efi* "${TARGET}"/efi/EFI/BOOT/grubx64.efi*; do
        [[ -f "${_img}" ]] || continue
        # grubx64.efi* also matches the .maze-kver label files next to the
        # images; only PE executables (starting with "MZ") are boot images.
        [[ "$(head -c 2 "${_img}" 2>/dev/null)" == MZ ]] || continue
        _ird="$(mktemp)"
        _list=""
        if objcopy -O binary --only-section=.initrd "${_img}" "${_ird}" 2>/dev/null \
           && [[ -s "${_ird}" ]] \
           && _list="$(lsinitcpio -l "${_ird}" 2>/dev/null)" \
           && [[ -n "${_list}" ]]; then
            _kf_checked=$((_kf_checked + 1))
            grep -qxE '(\./)?crypto_keyfile\.bin' <<<"${_list}" && _kf_hits+=("${_img#"${TARGET}"}")
        else
            _kf_unchecked=$((_kf_unchecked + 1))
        fi
        rm -f "${_ird}"
    done
    shopt -u nullglob
    if [[ ${#_kf_hits[@]} -gt 0 ]]; then
        critical "the LUKS keyfile is inside a boot image on the UNENCRYPTED ESP — the disk unlocks without the passphrase: ${_kf_hits[*]}"
        warn "=================================================================="
        warn "LUKS KEYFILE ON THE UNENCRYPTED ESP — the disk unlocks WITHOUT a passphrase:"
        for _h in "${_kf_hits[@]}"; do warn "  ${_h}"; done
        warn "Fix before trusting this install:"
        warn "  1. remove /crypto_keyfile.bin from FILES=() in /etc/mkinitcpio.conf(.d)"
        warn "  2. sudo maze-initramfs-rebuild   (rebuilds + re-signs every UKI)"
        warn "  3. treat the keyfile as leaked: cryptsetup luksRemoveKey <root-dev> /crypto_keyfile.bin"
        warn "=================================================================="
    elif [[ "${_kf_checked}" -gt 0 ]]; then
        log "LUKS: no keyfile inside the ${_kf_checked} boot image(s) on the ESP"
    fi
    if [[ "${_kf_unchecked}" -gt 0 ]]; then
        warn "LUKS: ${_kf_unchecked} boot image(s) on the ESP could not be inspected for a keyfile (objcopy/lsinitcpio)"
    fi
fi

# 12d) Discard a boot-chain verdict reached inside this install chroot. Package
# work above (the system upgrade in particular) fires maze-secureboot's
# zzz-maze-boot-verify.hook, which runs maze-boot-check HERE — where the chain is
# necessarily unfinished: the machine key is only enrolled on the first boot, so
# with Secure Boot on it reports "MOK not enrolled" and writes
# /var/lib/maze/boot-unsafe. Left in place, a healthy new install would greet
# its owner with "this machine may not start up again" and an inhibited
# shutdown. The flag has no protective value before first boot anyway (no guard
# runs here), and the booted system re-checks itself 3 minutes after start
# (maze-boot-check.timer), which raises it again if something is really wrong.
# Real install-time problems are reported by the checks above (12, 12b, 12c).
_boot_flag="${TARGET}/var/lib/maze/boot-unsafe"
if [[ -e "${_boot_flag}" ]]; then
    log "Discarding the boot check flag raised inside the install chroot ($(tr '\n' ';' < "${_boot_flag}" 2>/dev/null))"
    log "  — the installed system re-verifies its boot chain itself shortly after first boot."
    rm -f "${_boot_flag}"
fi

