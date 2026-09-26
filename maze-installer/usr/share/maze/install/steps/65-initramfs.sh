# 4) Plymouth boot splash --------------------------------------------------
log "Configuring Plymouth"
mkconf="${TARGET}/etc/mkinitcpio.conf"

# Is the target root on LUKS? Decides whether the initramfs MUST carry the
# `encrypt` hook — the hook that actually stops boot and prompts (via Plymouth)
# to unlock root. Reused below to both guarantee the hook is in HOOKS and to
# verify it landed in the rebuilt image.
_root_src_dev="$(findmnt -no SOURCE "${TARGET}" 2>/dev/null | sed 's/\[.*\]//')"
ROOT_IS_LUKS=0
if [[ "${_root_src_dev}" == /dev/mapper/* ]] && cryptsetup status "${_root_src_dev##*/}" >/dev/null 2>&1; then
    ROOT_IS_LUKS=1
fi

if [[ -f "${mkconf}" ]]; then
    # EARLY KMS. `kms` loads the DRM driver for the GPU `autodetect` actually found,
    # inside the initramfs — so Plymouth and the LUKS passphrase box come up on the
    # real GPU at native resolution, instead of on efifb/simpledrm and then flipping
    # mode once root is mounted.
    #
    # This block used to REMOVE `kms` (Calamares' initcpiocfg adds it by default —
    # see its main.py hooks list) to keep GPU firmware out of the UKI. Measured on a
    # Raptor Lake + MX550 machine, same kernel, only HOOKS differing:
    #
    #     kms absent .......  20 MB initramfs
    #     kms present ...... 138 MB initramfs
    #
    # and the +118 MB breaks down as i915 9.6 MB + xe 3.5 MB + nvidia 106 MB — i.e.
    # ~90% of it is the GSP firmware tree nouveau pulls in. On Intel-only or AMD
    # hardware `kms` costs ~11-30 MB, which is a fair price for a clean splash.
    #
    # Listing the drivers in MODULES instead is NOT a substitute: MODULES entries are
    # added unconditionally, so `MODULES=(i915? xe? amdgpu? radeon?)` on an Intel-only
    # box still dragged in amdgpu's firmware (measured: 31 MB -> 66 MB) for a GPU that
    # is not there. `kms` is the hardware-adaptive mechanism, so `kms` is what we keep.
    #
    # That "nouveau shrinks by itself" reasoning turned out to be wrong in practice:
    # maze-gpu-driver used to put the nvidia modules back into MODULES, and the
    # proprietary driver's GSP blobs are even bigger (~214 MB) — so both GPU paths
    # ended up with a 160-240 MB UKI. Measured on the same Raptor Lake + MX550
    # machine (systemd-analyze, Secure Boot on): loader 6.9 s with the 161 MB UKI,
    # 2.3 s with a 44 MB one, and the LUKS prompt up at ~2 s instead of ~4 s.
    #
    # So the rule is now driven by which GPU actually owns the panel. On every
    # hybrid laptop that is the iGPU: the discrete GPU contributes nothing to the
    # splash or to mounting root, so it has no business in the initramfs — it loads
    # from the real root a few seconds later with all of its firmware available
    # (verified: nouveau came up at 19 s with 2 GB VRAM, no errors). The driver is
    # read from the boot_vga device, and ONLY that one module goes into MODULES —
    # a single detected entry, not the unconditional list the note above warns
    # about. `kms` is dropped in that case because it would re-add the dGPU.
    #
    # When the panel hangs off NVIDIA (desktop, no iGPU) the answer depends on
    # WHICH driver owns it:
    #
    #   * proprietary `nvidia` — `kms` is pure dead weight. The kms hook only
    #     knows in-tree DRM drivers, so on this box it adds NOUVEAU (matched by
    #     the PCI alias) plus its whole /lib/firmware/nvidia tree, and the
    #     nvidia-utils modprobe.d blacklist that `modconf` also copies in then
    #     forbids nouveau from ever loading. Measured on a Ryzen 5700X + RTX 5060
    #     desktop (Secure Boot on, LUKS root): 150 MB UKI with `kms` — 112 MB of
    #     it nouveau firmware that is never read — firmware phase 13.6 s, loader
    #     3.6 s; Plymouth and the LUKS box were on simpledrm the whole time and
    #     nvidia-drm only came up from the real root. Dropping `kms` changes
    #     nothing on screen and takes ~110 MB off every UKI on the ESP.
    #   * `nouveau` (no nvidia-utils) — `kms` is what puts the splash on the
    #     real GPU, so it stays, firmware included. That is the one NVIDIA case
    #     with no cheap option.
    # MAZE_BOOT_GPU_DRV overrides the detection (tests; a repair run from a
    # different machine than the one being fixed). Normally unset.
    _boot_gpu_drv="${MAZE_BOOT_GPU_DRV:-}"
    [[ -n "${_boot_gpu_drv}" ]] || for _pd in /sys/bus/pci/devices/*; do
        [[ "$(cat "${_pd}/boot_vga" 2>/dev/null)" == "1" ]] || continue
        _boot_gpu_drv="$(basename "$(readlink -f "${_pd}/driver" 2>/dev/null)" 2>/dev/null)"
        break
    done
    if [[ -z "${_boot_gpu_drv}" ]]; then
        # No boot_vga flag (some firmware never sets it): fall back to the first
        # DRM card that has a driver bound.
        for _cd in /sys/class/drm/card[0-9]/device; do
            _boot_gpu_drv="$(basename "$(readlink -f "${_cd}/driver" 2>/dev/null)" 2>/dev/null)"
            [[ -n "${_boot_gpu_drv}" ]] && break
        done
    fi
    case "${_boot_gpu_drv}" in
        i915|xe|amdgpu|radeon)
            log "Early KMS: panel is on ${_boot_gpu_drv} — MODULES=(${_boot_gpu_drv}), no 'kms' hook (keeps dGPU firmware out of the UKI)"
            if ! grep -qE "^[[:space:]]*MODULES=\([^)]*\b${_boot_gpu_drv}\b" "${mkconf}"; then
                sed -i -E "/^[[:space:]]*MODULES=\(/ s/^([[:space:]]*MODULES=\()[[:space:]]*/\1${_boot_gpu_drv} /; s/^([[:space:]]*MODULES=\(${_boot_gpu_drv}) \)/\1)/" "${mkconf}" 2>/dev/null \
                    || warn "mkinitcpio MODULES (${_boot_gpu_drv}) edit failed"
            fi
            # Also drop any dGPU entries an older Maze / maze-gpu-driver left behind.
            sed -i -E '/^[[:space:]]*MODULES=/ s/[[:space:]]*\b(nouveau|nvidia(_modeset|_uvm|_drm)?)\b\??//g' "${mkconf}" 2>/dev/null || true
            sed -i -E '/^[[:space:]]*HOOKS=/ s/[[:space:]]*\bkms\b//' "${mkconf}" 2>/dev/null \
                || warn "mkinitcpio HOOKS (kms) removal failed"
            ;;
        nvidia)
            log "Early KMS: panel is on the proprietary nvidia driver — no 'kms' hook (it would only add blacklisted nouveau + ~110 MB of its firmware; splash stays on simpledrm until nvidia-drm loads from root)"
            sed -i -E '/^[[:space:]]*MODULES=/ s/[[:space:]]*\b(nouveau|nvidia(_modeset|_uvm|_drm)?)\b\??//g' "${mkconf}" 2>/dev/null || true
            sed -i -E '/^[[:space:]]*HOOKS=/ s/[[:space:]]*\bkms\b//' "${mkconf}" 2>/dev/null \
                || warn "mkinitcpio HOOKS (kms) removal failed"
            ;;
        *)
            log "Early KMS: panel driver is '${_boot_gpu_drv:-unknown}' — keeping the 'kms' hook"
            if ! grep -qE '^[[:space:]]*HOOKS=\([^)]*\bkms\b' "${mkconf}"; then
                # Canonical Arch position: right after `microcode`, before `modconf`.
                if grep -qE '^[[:space:]]*HOOKS=\([^)]*\bmodconf\b' "${mkconf}"; then
                    sed -i -E '/^[[:space:]]*HOOKS=/ s/\bmodconf\b/kms modconf/' "${mkconf}" 2>/dev/null \
                        && log "added 'kms' hook (early KMS: splash and LUKS prompt on the real GPU)" \
                        || warn "mkinitcpio HOOKS (kms) insert failed"
                else
                    warn "mkinitcpio HOOKS has no 'modconf' anchor — 'kms' not inserted, early KMS is OFF"
                fi
            fi
            ;;
    esac

    if ! grep -q 'plymouth' "${mkconf}"; then
        # Fallback only — Calamares' initcpiocfg already appends plymouth in the right
        # place when it detects it. plymouth must come AFTER `kms` (it needs the DRM
        # driver to draw on the real GPU) and BEFORE `encrypt` (which calls
        # `plymouth ask-for-password` for the passphrase box). Anchor on `encrypt`,
        # which satisfies both; only fall back to the udev position if that is absent.
        if grep -qE '^[[:space:]]*HOOKS=\([^)]*\bencrypt\b' "${mkconf}"; then
            sed -i -E '/^[[:space:]]*HOOKS=/ s/\bencrypt\b/plymouth encrypt/' "${mkconf}" 2>/dev/null \
                || warn "mkinitcpio HOOKS (plymouth) edit failed"
        else
            sed -i -E '/^[[:space:]]*HOOKS=/ s/\budev\b/udev plymouth/' "${mkconf}" 2>/dev/null \
                || warn "mkinitcpio HOOKS (plymouth) edit failed"
        fi
    fi
    # LUKS passphrase prompt — THE thing that makes the box appear. The busybox
    # `encrypt` hook is what stops the initramfs and calls `plymouth
    # ask-for-password` (see /usr/lib/initcpio/hooks/encrypt), which drives the
    # Maze theme's password dialog. If `encrypt` is MISSING from HOOKS, root never
    # unlocks and NO password box ever shows: the splash logo comes up and boot
    # just hangs there. That is exactly what happens when the live archiso.conf
    # drop-in (HOOKS without encrypt) overrides the main config, or when
    # initcpiocfg didn't add it. The drop-in is removed below, but don't rely on
    # any single layer — for a LUKS root, force `encrypt` (and `keyboard`, so the
    # passphrase can actually be typed) into HOOKS here, idempotently.
    #
    # `plymouth` is already inserted right after `udev` above — well before the
    # late `encrypt` hook — so plymouthd is up when the prompt fires. (There is NO
    # `plymouth-encrypt` hook in current mkinitcpio; only `encrypt`/`sd-encrypt`,
    # so swapping to it would make `mkinitcpio -P` fail and leave root unbootable.)
    if [[ "${ROOT_IS_LUKS}" -eq 1 ]] && grep -qE '^[[:space:]]*HOOKS=' "${mkconf}"; then
        if ! grep -qE 'HOOKS=\([^)]*\bencrypt\b' "${mkconf}"; then
            if grep -qE 'HOOKS=\([^)]*\bfilesystems\b' "${mkconf}"; then
                # Correct position: just before `filesystems` (after block).
                sed -i -E '/^[[:space:]]*HOOKS=/ s/\bfilesystems\b/encrypt filesystems/' "${mkconf}" \
                    2>/dev/null || warn "could not insert encrypt hook into HOOKS"
            else
                sed -i -E '/^[[:space:]]*HOOKS=/ s/\)([[:space:]]*)$/ encrypt)\1/' "${mkconf}" \
                    2>/dev/null || warn "could not append encrypt hook to HOOKS"
            fi
            log "LUKS: forced 'encrypt' hook into HOOKS (it was missing — root would not have prompted)"
        fi
        # `keyboard` must precede `encrypt` or the passphrase can't be typed.
        if ! grep -qE 'HOOKS=\([^)]*\bkeyboard\b' "${mkconf}"; then
            sed -i -E '/^[[:space:]]*HOOKS=/ s/\bencrypt\b/keyboard encrypt/' "${mkconf}" 2>/dev/null || true
        fi
    fi
fi

# 4b) Initramfs build settings — undo the live medium's leakage. unpackfs copied
# the whole live root, including /etc/mkinitcpio.conf.d/archiso.conf, which is a
# mkinitcpio DROP-IN: it overrides the main config with the archiso HOOKS and,
# critically, COMPRESSION="xz" (-9e). xz decompresses ~5x slower than zstd, so on
# top of a large NVIDIA+firmware initramfs that drop-in turns boot into a long
# black screen before Plymouth. A normal Arch install never sees this because it
# has no such drop-in. Remove the live drop-in and pin zstd on the target so the
# installed system builds a fast-to-read, fast-to-decompress image (like Arch).
rm -f "${TARGET}/etc/mkinitcpio.conf.d/archiso.conf" 2>/dev/null || true
if [[ -f "${mkconf}" ]]; then
    # Delete every COMPRESSION line — active OR commented — then write exactly one.
    # (Rewriting matches in place instead would turn each of the stock config's
    # commented examples — #COMPRESSION="gzip", "bzip2", "lzma", "xz", "lzop", "lz4",
    # "zstd" — into its own ACTIVE COMPRESSION="zstd" line, leaving ~7 duplicates in
    # the file. mkinitcpio honours the last one, so the build was still zstd, but the
    # config was a mess and re-running the deploy kept adding to it.)
    sed -i -E '/^[[:space:]]*#?[[:space:]]*COMPRESSION=/d' "${mkconf}" 2>/dev/null || true
    printf 'COMPRESSION="zstd"\n' >> "${mkconf}"
    # Drop any xz-style COMPRESSION_OPTIONS that would no longer apply to zstd.
    sed -i -E 's|^[[:space:]]*COMPRESSION_OPTIONS=.*|COMPRESSION_OPTIONS=()|' "${mkconf}" 2>/dev/null || true
fi
