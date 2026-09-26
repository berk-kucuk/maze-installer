# Secure Boot (shim + per-machine MOK):
#   firmware -> shim (Microsoft-signed, \EFI\BOOT\BOOTX64.EFI)
#            -> grubx64.efi = the Unified Kernel Image (kernel + initramfs +
#               cmdline) signed with this machine's MOK.
# A per-machine key is generated (private half never leaves the target), shim is
# taken from the live system (shim-signed is AUR, preinstalled on the live ISO),
# the UKI is signed by maze-sb-sign, and a pacman hook + .path unit keep it
# signed across updates. Best-effort: NEVER aborts the install — on failure the
# system still boots with Secure Boot DISABLED in firmware. Replacing the
# removable BOOTX64.EFI with shim is harmless when SB is off (shim just
# chainloads), so this does not affect a Secure-Boot-OFF boot.
MAZE_SB_ESP=""
setup_secure_boot() {
    local live_shim=/usr/share/shim-signed/shimx64.efi
    local live_mm=/usr/share/shim-signed/mmx64.efi
    if [[ ! -f "${live_shim}" ]]; then
        warn "Secure Boot: ${live_shim} not on live system; skipping SB setup"
        return 0
    fi
    # Locate the ESP on the target (Calamares mounts Maze's ESP at /boot).
    local esp_rel="" cand
    for cand in /boot /efi /boot/efi; do
        [[ -d "${TARGET}${cand}/EFI" ]] && { esp_rel="${cand}"; break; }
    done
    if [[ -z "${esp_rel}" ]]; then
        warn "Secure Boot: no ESP (EFI dir) under target; skipping (BIOS install?)"
        return 0
    fi
    local esp_abs="${TARGET}${esp_rel}"
    log "Secure Boot: configuring shim + per-machine MOK (ESP=${esp_rel})"

    # Signing tooling is already on the target via unpackfs; top up if online.
    # systemd-ukify provides ukify, which kernel-install's own UKI plugin uses
    # (layout=uki, /etc/kernel/install.conf) to build the UKI that shim chainloads.
    # (efitools was in this list but nothing ever called sign-efi-sig-list or
    # cert-to-efi-sig-list — Maze signs with sbsign and enrolls with mokutil.)
    #
    # Best-effort ONLY, and it normally does nothing: this runs at step 5b, well
    # before the target keyring is initialised (step 8b), so pacman cannot verify
    # signatures yet and the call fails. That is fine — sbsigntools, mokutil and
    # systemd-ukify all ship on the ISO and unpackfs has already put them on the
    # target. This line exists purely to top up an image that somehow lacks them.
    # Only the ones that are genuinely absent: `-S --needed` would DOWNGRADE an
    # installed maze-secureboot that is newer than the repo's (ISO built from
    # ./localrepo) if the keyring happened to work here. Same rule as
    # install_maze_repo_apps — never touch what unpackfs delivered.
    local _sbmiss=() _sbp
    for _sbp in maze-secureboot sbsigntools mokutil systemd-ukify; do
        in_chroot pacman -Qq "${_sbp}" >/dev/null 2>&1 || _sbmiss+=("${_sbp}")
    done
    [[ ${#_sbmiss[@]} -gt 0 ]] && { in_chroot pacman -S --needed --noconfirm "${_sbmiss[@]}" >/dev/null 2>&1 || true; }

    local keydir="${TARGET}/var/lib/maze-secureboot"
    mkdir -p "${keydir}"; chmod 700 "${keydir}"
    cp -f "${live_shim}" "${keydir}/shimx64.efi" 2>/dev/null || true
    [[ -f "${live_mm}" ]] && cp -f "${live_mm}" "${keydir}/mmx64.efi" 2>/dev/null || true

    # 1) Per-machine MOK key.
    if [[ ! -f "${keydir}/MOK.key" ]]; then
        if ! in_chroot openssl req -newkey rsa:2048 -nodes \
                -keyout /var/lib/maze-secureboot/MOK.key -new -x509 -sha256 -days 3650 \
                -subj "/CN=Maze Linux Secure Boot machine key/" \
                -out /var/lib/maze-secureboot/MOK.crt >/dev/null 2>&1; then
            warn "Secure Boot: MOK key generation failed; skipping SB"
            return 0
        fi
        in_chroot openssl x509 -outform DER -in /var/lib/maze-secureboot/MOK.crt \
            -out /var/lib/maze-secureboot/MOK.cer >/dev/null 2>&1 || true
        in_chroot chmod 600 /var/lib/maze-secureboot/MOK.key >/dev/null 2>&1 || true
    fi

    # 2) The signing machinery itself is NOT written here any more — it ships in
    #    the `maze-secureboot` package (pulled in by maze-meta, so unpackfs has
    #    already put it on the target):
    #
    #      /usr/bin/maze-sb-sign                                 sign the UKI as grubx64.efi
    #      /usr/bin/maze-kernel-install-add                      run `kernel-install add`
    #      /usr/share/libalpm/hooks/85-maze-kernel-install.hook  rebuild on kernel upgrade
    #      /usr/share/libalpm/hooks/zz-maze-secureboot.hook      belt-and-suspenders re-sign
    #      /usr/lib/kernel/install.d/95-maze-sb-sign.install     sign inline during kernel-install
    #      /usr/lib/systemd/system/maze-sb-resign.{service,path} out-of-band self-heal
    #      /usr/lib/systemd/system/systemd-boot-update.service.d/99-maze-resign.conf
    #
    #    Writing them here, as inline heredocs into /usr/local/bin and /etc, is
    #    exactly what made them unfixable once a machine was installed: pacman
    #    owned none of those files, so no update could ever replace a broken
    #    signer — on the one subsystem whose failure mode is "does not boot".
    #    What stays below is what is genuinely per-machine: the MOK key, the shim
    #    binaries copied off the ISO, the NVRAM entry and the enrollment note.
    #
    #    Fail LOUDLY if the package is absent. Silently continuing would produce
    #    a machine that is signed once, here, and never again — which looks fine
    #    until the first kernel update and then does not boot.
    if [[ ! -x "${TARGET}/usr/bin/maze-sb-sign" ]]; then
        warn "Secure Boot: maze-secureboot is NOT on the target (/usr/bin/maze-sb-sign missing)."
        warn "Secure Boot: without it kernel updates never rebuild or re-sign the UKI — skipping SB setup."
        warn "Secure Boot: add 'maze-secureboot' to packages.x86_64 (and maze-meta) and rebuild the ISO."
        return 0
    fi

    # The package's .install scriptlet ran in the ISO build chroot, so the units
    # are already enabled in the tree unpackfs copied. Re-apply anyway: cheap,
    # idempotent, and it covers an image built before the preset landed.
    in_chroot systemctl enable maze-sb-resign.path maze-sb-resign.service >/dev/null 2>&1 \
        || warn "Secure Boot: could not enable maze-sb-resign units"

    # `bootctl update` replaces EFI/BOOT/BOOTX64.EFI with an UNSIGNED systemd-boot.
    # Maze used to `systemctl mask` the unit outright, which also meant systemd-boot
    # could never be updated again (security fixes included). The packaged
    # 99-maze-resign.conf drop-in repairs the chain as ExecStartPost instead, so
    # undo any mask an older Maze install left behind.
    in_chroot systemctl unmask systemd-boot-update.service >/dev/null 2>&1 || true

    # 3) Sign now (explicit ESP — bootctl is unreliable in the install chroot).
    if in_chroot /usr/bin/maze-sb-sign --force-bootloader "${esp_rel}"; then
        MAZE_SB_ESP="${esp_rel}"
    else
        warn "Secure Boot: initial signing reported problems; boot with SB disabled until resolved"
        MAZE_SB_ESP="${esp_rel}"
    fi

    # 4) NVRAM entry pointing at shim (best-effort; the removable
    #    /EFI/BOOT/BOOTX64.EFI fallback covers most firmware incl. OVMF VMs).
    local espdev disk="" partn=""
    espdev="$(findmnt -no SOURCE "${esp_abs}" 2>/dev/null || true)"
    if [[ -n "${espdev}" ]]; then
        if [[ "${espdev}" =~ ^(/dev/.*[0-9])p([0-9]+)$ ]]; then      # nvme/mmcblk
            disk="${BASH_REMATCH[1]}"; partn="${BASH_REMATCH[2]}"
        elif [[ "${espdev}" =~ ^(/dev/.*[a-z])([0-9]+)$ ]]; then     # sd/vd
            disk="${BASH_REMATCH[1]}"; partn="${BASH_REMATCH[2]}"
        fi
        if [[ -n "${disk}" && -n "${partn}" ]]; then
            # Remove any earlier "Maze Linux" entry pointing at a partition that
            # no longer exists before adding this one. Without this every
            # reinstall on the same machine left another identical line in the
            # firmware boot menu — a box installed four times showed four "Maze
            # Linux" entries, three of them aimed at partitions the reinstall had
            # just wiped. Only dead ones go: an entry whose partition is still
            # present may belong to another Maze install the user still boots.
            local _live_guids _bn _bguid
            _live_guids="$(lsblk -rno PARTUUID 2>/dev/null | tr 'A-Z' 'a-z' | grep . || true)"
            if [[ -n "${_live_guids}" ]]; then
                while read -r _bn _bguid; do
                    [[ -n "${_bn}" ]] || continue
                    grep -Fxq "${_bguid}" <<<"${_live_guids}" && continue
                    in_chroot efibootmgr --bootnum "${_bn}" --delete-bootnum >/dev/null 2>&1 \
                        && log "Secure Boot: removed stale 'Maze Linux' entry Boot${_bn} (its partition is gone)" \
                        || true
                done < <(in_chroot efibootmgr -v 2>/dev/null \
                           | grep -E '^Boot[0-9A-Fa-f]{4}\*? +Maze Linux\b' \
                           | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*HD([0-9]*,GPT,\([0-9a-fA-F-]*\),.*/\1 \2/p' \
                           | tr 'A-Z' 'a-z')
            fi

            in_chroot efibootmgr --create --disk "${disk}" --part "${partn}" \
                --label "Maze Linux" --loader '\EFI\BOOT\BOOTX64.EFI' --unicode >/dev/null 2>&1 \
                || warn "Secure Boot: NVRAM entry not created (relying on removable fallback)"
        fi
    fi

    # 4b) Remove the competing UNSIGNED boot entry. Calamares' bootloader module
    # ran `bootctl install`, which created a "Linux Boot Manager" NVRAM entry
    # pointing DIRECTLY at \EFI\systemd\systemd-bootx64.efi. With Secure Boot ON
    # the firmware would boot THAT entry first and fail validation — the binary is
    # signed by nobody, and even a MOK signature would not help because MOK is only
    # honoured when shim is in the chain. Delete every such entry so the firmware
    # can only boot through shim (our "Maze Linux" entry, or the removable
    # \EFI\BOOT\BOOTX64.EFI fallback — both are shim).
    # Newer bootctl creates TWO entries: "Linux Boot Manager" -> systemd-bootx64.efi
    # and "Fallback Linux Boot Manager" -> systemd-boot-fallbackx64.efi. The old
    # pattern here only matched the first; a real install kept the fallback one
    # (unsigned, can never boot with Secure Boot on) as Boot0001.
    #
    # ONLY entries on THIS install's ESP (matched by its GPT partition GUID). Any
    # other systemd-boot entry belongs to another OS on another disk/ESP — an
    # existing Arch/Fedora/EndeavourOS install in a dual-boot setup — and
    # deleting it would make that system vanish from the firmware boot menu.
    local bn esp_guid=""
    [[ -n "${espdev}" ]] && esp_guid="$(lsblk -rno PARTUUID "${espdev}" 2>/dev/null | head -1 | tr 'A-Z' 'a-z')"
    if [[ -z "${esp_guid}" ]]; then
        warn "Secure Boot: could not determine the ESP partition GUID; leaving systemd-boot NVRAM entries untouched"
    else
        for bn in $(in_chroot efibootmgr -v 2>/dev/null \
                      | tr 'A-Z' 'a-z' \
                      | grep -E 'systemd-boot(-fallback)?x64\.efi' \
                      | grep -F "gpt,${esp_guid}," \
                      | sed -n 's/^boot\([0-9a-f]\{4\}\).*/\1/p'); do
            in_chroot efibootmgr --bootnum "${bn}" --delete-bootnum >/dev/null 2>&1 \
                && log "Secure Boot: removed unsigned direct systemd-boot entry Boot${bn}" \
                || true
        done
    fi

    # 5) First-boot enrollment instructions (password-less, physical presence).
    install -Dm644 /dev/stdin "${TARGET}/var/lib/maze-secureboot/ENROLLMENT.txt" <<'SBNOTE'
Maze Linux — Secure Boot key enrollment
========================================

This machine boots with UEFI Secure Boot using a Microsoft-signed shim plus a
key unique to this computer. The key's certificate must be enrolled once. There
is NO password — enrollment requires physical presence (you confirm it at the
firmware-level MokManager menu on the next boot).

On the FIRST reboot the boot loader is not trusted yet, so a blue "Verification
failed" / "MOK Management" (MokManager) screen appears. Do this once:

  1. Choose "Enroll key from disk"
  2. Select the EFI system partition volume, then the file:  MOK.cer
  3. Confirm / "Continue", then "Yes" to enroll
  4. Reboot

After that the system boots normally with Secure Boot enabled. Factory/Windows
keys are left untouched; kernel updates are re-signed automatically.

Certificate:  /var/lib/maze-secureboot/MOK.cer  (also at the ESP root /MOK.cer)
Check status:  mokutil --sb-state
SBNOTE

    log "Secure Boot configured. Enroll MOK.cer via MokManager on first boot (no password)."
}

