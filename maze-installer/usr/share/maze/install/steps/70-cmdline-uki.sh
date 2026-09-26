# 5) Kernel command line — must be written BEFORE mkinitcpio so UKI picks it up.
log "Adding kernel parameters (quiet splash bgrt_disable + AppArmor${NVIDIA_PARAMS:+ + NVIDIA}${KBD_PARAMS:+ + keyboard quirk})"
# The full set of params Maze wants on every boot. NONE of these is root=/
# rootflags=/rootfstype= — those belong to the installer and must never be
# duplicated by us.
EXTRA_PARAMS="quiet splash bgrt_disable logo.nologo lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1 security=apparmor${NVIDIA_PARAMS}${KBD_PARAMS}"

# /etc/kernel/cmdline is the authoritative source for UKI builds. Calamares'
# bootloader module already wrote it with root=, rootflags=, etc. We APPEND
# only the missing params; never overwrite, so root= is preserved.
#
# Token-exact dedup: compare whole tokens, not substrings. (A naive grep for
# "apparmor" would match the "apparmor" inside lsm=...,apparmor,bpf and wrongly
# skip apparmor=1.)
mkdir -p "${TARGET}/etc/kernel"
_existing_cmdline="$(cat "${TARGET}/etc/kernel/cmdline" 2>/dev/null || true)"
_new_cmdline="${_existing_cmdline}"
for _p in ${EXTRA_PARAMS}; do
    _key="${_p%%=*}"
    _present=0
    for _e in ${_new_cmdline}; do
        if [[ "${_e}" == "${_p}" || "${_e}" == "${_key}="* ]]; then
            _present=1; break
        fi
    done
    [[ "${_present}" -eq 1 ]] || _new_cmdline="${_new_cmdline} ${_p}"
done
# TRIM through dm-crypt, the way that needs NO passphrase.
#
# The busybox `encrypt` hook (the one this install uses) reads
# `cryptdevice=<device>:<name>[:<options>]` and turns `allow-discards` in that
# comma-separated third field into `cryptsetup open --allow-discards`
# (/usr/lib/initcpio/hooks/encrypt). Setting it here means every boot unlocks
# root with discards enabled.
#
# This is the primary mechanism precisely because the alternative — persisting
# the flag into the LUKS2 header with `cryptsetup --persistent refresh` further
# down — needs the passphrase (cryptsetup-refresh(8): "Mandatory parameters are
# identical to those of an open action"), and the installer deliberately does
# not keep it. So that call fails on a normal install and used to leave TRIM
# simply not working, with nothing but a warning. Without discards reaching the
# SSD, a DRAM-less QLC drive never reclaims its free-block pool and large writes
# collapse into multi-second stalls.
MAZE_LUKS_DISCARD_CMDLINE=0
if [[ "${ROOT_IS_LUKS}" -eq 1 ]]; then
    _cmdline_out=""
    for _e in ${_new_cmdline}; do
        if [[ "${_e}" == cryptdevice=* ]]; then
            _val="${_e#cryptdevice=}"
            # Field split matches the hook's `IFS=: read cryptdev cryptname
            # cryptoptions`: first colon ends the device, second ends the name,
            # everything after that is the options list.
            _cd_dev="${_val%%:*}"
            _cd_rest="${_val#*:}"
            if [[ "${_cd_rest}" == "${_val}" ]]; then
                # No ":name" at all — not a form the hook understands. Leave it
                # exactly as Calamares wrote it rather than guessing.
                _cmdline_out="${_cmdline_out} ${_e}"
                continue
            fi
            _cd_name="${_cd_rest%%:*}"
            _cd_opts=""
            [[ "${_cd_rest}" == *:* ]] && _cd_opts="${_cd_rest#*:}"
            case ",${_cd_opts}," in
                *,allow-discards,*|*,discard,*) ;;   # already requested
                *) _cd_opts="${_cd_opts:+${_cd_opts},}allow-discards" ;;
            esac
            _cmdline_out="${_cmdline_out} cryptdevice=${_cd_dev}:${_cd_name}:${_cd_opts}"
            MAZE_LUKS_DISCARD_CMDLINE=1
        else
            _cmdline_out="${_cmdline_out} ${_e}"
        fi
    done
    if [[ "${MAZE_LUKS_DISCARD_CMDLINE}" -eq 1 ]]; then
        _new_cmdline="${_cmdline_out# }"
        log "LUKS: allow-discards added to cryptdevice= on the kernel cmdline (TRIM pass-through, no passphrase needed)"
    else
        warn "LUKS: no cryptdevice= token on the kernel cmdline — cannot enable TRIM pass-through there"
    fi
fi

printf '%s\n' "${_new_cmdline}" > "${TARGET}/etc/kernel/cmdline"

# Rollback that actually works, from the first boot. Calamares pins the root
# subvolume twice (rootflags=subvol=/@ on the sealed cmdline, subvol=/@ on the
# / line of fstab), so `maze-rollback` could only be enabled later by hand — and
# every snapshot taken until then carried the pinned fstab that makes a rollback
# undo itself. maze-enable-rollback (maze-snapshots) sets the btrfs default
# subvolume to @, PROVES a subvol-less mount lands on a real root, and only then
# drops the two pins. Here, before the UKI below is built from this cmdline.
# Any failure leaves the pins in place: the machine then boots exactly as it
# did before this existed, with rollback available later via the same tool.
if [[ "$(findmnt -no FSTYPE "${TARGET}" 2>/dev/null)" == btrfs ]]; then
    if ! in_chroot sh -c 'command -v maze-enable-rollback' >/dev/null 2>&1; then
        warn "Rollback: maze-enable-rollback is not on the target (maze-snapshots too old) — root stays pinned to @"
    elif _rb_out="$(in_chroot maze-enable-rollback --apply --no-rebuild 2>&1)"; then
        log "Rollback: enabled — 'sudo maze-rollback <n>' + reboot returns to a snapshot"
        printf '%s\n' "${_rb_out}" | sed 's/^/    /'
    else
        warn "Rollback: could not be enabled; root stays pinned to @ (boots as before). Details:"
        printf '%s\n' "${_rb_out}" | sed 's/^/    /' >&2
    fi
fi

# For systemd-boot/GRUB/Limine config files we append ONLY the extra params
# (these files already carry their own root=). Never the full cmdline.
PARAMS="${EXTRA_PARAMS}"

# Write plymouthd.conf explicitly so BGRT is never shown as a transition
# frame and the maze theme starts immediately (ShowDelay=0).
mkdir -p "${TARGET}/etc/plymouth"
cat > "${TARGET}/etc/plymouth/plymouthd.conf" <<'PLYMOUTHD'
[Daemon]
Theme=maze
ShowDelay=0
DeviceTimeout=5
PLYMOUTHD
in_chroot plymouth-set-default-theme maze >/dev/null 2>&1 || warn "plymouth-set-default-theme failed"

# loader.conf: force a straight-to-default boot. kernel-install (layout=uki,
# see /etc/kernel/install.conf) names the UKI <machine-id>-<kver>.efi and
# Calamares' bootloader module already writes `default <machine-id>*` in
# loader.conf, so there is no vendor-branded filename to rename here.
_loaderconf="${TARGET}/efi/loader/loader.conf"
[[ -f "${_loaderconf}" ]] || _loaderconf="${TARGET}/boot/loader/loader.conf"
if [[ -f "${_loaderconf}" ]]; then
    # Boot straight into Maze. The systemd-boot menu often does not even render
    # on the firmware's post-handoff console, so any nonzero timeout is just a
    # black screen the user sits through (can't be skipped), and Plymouth — which
    # only starts once the kernel loads — appears to come up "slowly". Calamares'
    # bootloader module already sets `timeout 0`; this is the safety net that
    # forces it regardless of what wrote loader.conf. The menu is still reachable
    # by holding a key during early boot.
    if grep -q '^[[:space:]]*timeout' "${_loaderconf}"; then
        sed -i 's|^[[:space:]]*timeout.*|timeout 0|' "${_loaderconf}" 2>/dev/null || true
    else
        printf 'timeout 0\n' >> "${_loaderconf}"
    fi
    # Keep the firmware's native POST framebuffer mode for the EFI console.
    # Do NOT use `console-mode max`: on most UEFI firmware the highest GOP mode
    # it advertises is a small fallback (often 1024x768), so forcing "max"
    # DOWNGRADES the console from native and leaves Plymouth stuck at that low
    # res on every monitor. `keep` makes systemd-boot leave the native mode the
    # firmware already set, giving a seamless splash handoff to the GPU driver.
    if grep -q '^[[:space:]]*console-mode' "${_loaderconf}"; then
        sed -i 's|^[[:space:]]*console-mode.*|console-mode keep|' "${_loaderconf}" 2>/dev/null || true
    else
        printf 'console-mode keep\n' >> "${_loaderconf}"
    fi
fi

# The LUKS keyfile must never be inside the initramfs: the UKI that carries it
# lives on the UNENCRYPTED ESP, and the busybox `encrypt` hook uses
# /crypto_keyfile.bin automatically — the disk would unlock without a passphrase
# for anyone holding the ESP. shellprocess@stripkeyfile already removed it right
# after initcpiocfg; this repeats the check on the final config (main file AND
# drop-ins) so a re-run of this script, or a drop-in added later, cannot bring it
# back. The keyfile itself stays on the encrypted root for crypttab.
for _mkc in "${mkconf}" "${TARGET}"/etc/mkinitcpio.conf.d/*.conf; do
    [[ -f "${_mkc}" ]] || continue
    if grep -qE '^[[:space:]]*FILES=\([^)]*/crypto_keyfile\.bin' "${_mkc}"; then
        sed -i -E '/^[[:space:]]*FILES=\(/ s#[[:space:]]*"?/crypto_keyfile\.bin"?##' "${_mkc}" 2>/dev/null \
            && log "LUKS: removed /crypto_keyfile.bin from FILES in ${_mkc#"${TARGET}"} (must not reach the ESP)" \
            || warn "LUKS: could not remove /crypto_keyfile.bin from FILES in ${_mkc#"${TARGET}"}"
    fi
done

# `mkinitcpio -P` is a no-op on a layout=uki install (calamares-mount-api.sh
# empties every preset); it is kept so a machine with a non-empty preset still
# gets its images rebuilt. The image that actually boots is rebuilt just below.
if ! _mki_log="$(in_chroot mkinitcpio -P 2>&1)"; then
    warn "mkinitcpio -P failed:"
    printf '%s\n' "${_mki_log}" >&2
fi

# Rebuild the UKI with the FINAL HOOKS (encrypt + plymouth + GPU) and the final
# /etc/kernel/cmdline. With layout=uki, kernel-install runs mkinitcpio itself
# (50-mkinitcpio.install) and glues kernel + initramfs + cmdline together with
# ukify — without this the ESP keeps the UKI from Calamares' bootloader step,
# built before the HOOKS/cmdline edits above. setup_secure_boot has NOT run yet,
# so this UKI lands unsigned; setup_secure_boot signs it and the final re-sign
# after the package phase is the safety net.
if is_uefi; then
    kernel_install_all "UKI rebuild"
fi
if [[ "${ROOT_IS_LUKS}" -eq 1 ]]; then
    # Verify the passphrase prompt will actually appear. This used to iterate over
    # ${TARGET}/boot/initramfs-*.img, but /etc/kernel/install.conf ships layout=uki:
    # kernel-install writes a UKI to $ESP/EFI/Linux/ and NO loose initramfs image is
    # ever produced, so that loop matched nothing and every install ended on the
    # "no plain image to verify" warning — the check never actually ran.
    #
    # HOOKS in mkinitcpio.conf is what drives the build, so check that first (it is
    # authoritative and always available), then confirm a UKI was really produced.
    if grep -qE '^[[:space:]]*HOOKS=\([^)]*\bencrypt\b' "${mkconf}" 2>/dev/null; then
        log "LUKS: 'encrypt' hook present in HOOKS — the passphrase box will appear at boot"
    else
        critical "LUKS: 'encrypt' hook MISSING from HOOKS — the encrypted root will not unlock at boot. HOOKS=$(grep -E '^HOOKS=' "${mkconf}" 2>/dev/null)"
    fi
    _uki_found=0
    for _esp_dir in "${TARGET}/efi/EFI/Linux" "${TARGET}/boot/EFI/Linux"; do
        for _uki in "${_esp_dir}"/*.efi; do
            [[ -f "${_uki}" ]] || continue
            _uki_found=1
            log "LUKS: UKI present — $(basename "${_uki}") ($(du -h "${_uki}" 2>/dev/null | cut -f1))"
        done
    done
    [[ "${_uki_found}" -eq 0 ]] \
        && warn "LUKS: no UKI found under EFI/Linux on the ESP — kernel-install may not have run"
fi

