# 3b) GPU: configure the NVIDIA proprietary driver if the installer added it ---
NVIDIA_PARAMS=""
if in_chroot pacman -Qq nvidia nvidia-dkms nvidia-open nvidia-open-dkms nvidia-lts 2>/dev/null | grep -q .; then
    log "Configuring NVIDIA proprietary driver (modeset + early KMS)"
    cat > "${TARGET}/etc/modprobe.d/nvidia.conf" <<'EOF'
# DRM kernel mode setting + framebuffer console handover (clean splash, no
# vendor-fbdev flicker) and GPU System Processor firmware for Turing+ cards.
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_EnableGpuFirmware=1
# Keep VRAM contents across suspend so the desktop comes back without corruption
# (works together with the nvidia-suspend/resume services below). Maze suspends
# to RAM only — see the nvidia-hibernate note further down.
options nvidia NVreg_PreserveVideoMemoryAllocations=1
# Use the Page Attribute Table for memory mappings (better GPU throughput).
options nvidia NVreg_UsePageAttributeTable=1

blacklist nouveau
options nouveau modeset=0
EOF
    # NOTE: the nvidia modules are deliberately NOT forced into MODULES=() here.
    #
    # mkinitcpio bundles the firmware of every module it includes, and the nvidia
    # modules drag in the WHOLE /lib/firmware/nvidia/ tree — the GSP blobs for every
    # supported GPU generation, not just this machine's (~214 MB). Firmware ships as
    # individually-zstd'd .bin.zst, so it does not recompress: it lands ~1:1 in the
    # image and pushed the signed UKI to ~240 MB. That is paid on EVERY boot twice
    # over — shim has to hash the whole binary for the Secure Boot signature check
    # (measured: ~6 s in the "loader" phase) and the kernel then unpacks it — all of
    # it BEFORE Plymouth or the LUKS prompt can appear.
    #
    # Nothing needed to MOUNT root lives on the GPU: root is LUKS + btrfs, driven by
    # the encrypt/block/filesystems hooks. So nvidia is left out of the initramfs and
    # loads normally from the real root, with `nvidia-drm.modeset=1` (set below) still
    # giving KMS once it is up.
    #
    # NOTE the interaction with the `kms` HOOK (kept in HOOKS further down, step 4):
    # `kms` pulls the DRM driver `autodetect` finds, which on an NVIDIA box before
    # the proprietary driver is installed is NOUVEAU — and nouveau drags in the same
    # /lib/firmware/nvidia/ tree this block avoids (measured on a Raptor Lake + MX550
    # machine: 20 MB initramfs without `kms`, 138 MB with, of which 106 MB is that
    # firmware). Step 4 now settles this per machine: when the panel is on the iGPU
    # (every hybrid laptop) `kms` is dropped and only that iGPU driver goes into
    # MODULES, so neither nouveau nor nvidia ever reaches the UKI. maze-gpu-driver
    # no longer adds the nvidia modules to MODULES either — the driver loads from
    # the real root, and nvidia-drm.modeset=1 gives KMS from that point on.
    #
    # Strip the modules idempotently so re-running the deploy on a system installed by
    # an older Maze (which did add them) also shrinks its UKI.
    mkc="${TARGET}/etc/mkinitcpio.conf"
    if [[ -f "${mkc}" ]] && grep -qE '^MODULES=\(.*nvidia' "${mkc}"; then
        # The trailing \?? also strips the OPTIONAL-module suffix maze-gpu-driver
        # writes (`nvidia?`). Without it a re-deploy over a system that already ran
        # maze-gpu-driver would remove the name but leave the '?' behind, giving
        # MODULES=(? ? ? ?) — four entries mkinitcpio cannot resolve.
        sed -i -E '/^MODULES=\(/ s/[[:space:]]*\bnvidia(_modeset|_uvm|_drm)?\b\??//g' "${mkc}" 2>/dev/null \
            && log "NVIDIA: removed nvidia modules from initramfs MODULES (keeps the UKI small; driver loads from root)" \
            || warn "mkinitcpio MODULES (nvidia) cleanup failed"
    fi
    # Preserve-VRAM needs these to actually save/restore the framebuffer on sleep.
    #
    # nvidia-hibernate.service is deliberately NOT enabled: this system cannot
    # hibernate and never could. partition.conf offers only "none" and "file" for
    # swap (the RAM-sized swap PARTITION choice breaks the install on LUKS — see
    # the note there), so Calamares' initcpiocfg never adds the `resume` hook,
    # nothing puts `resume=` on the kernel cmdline, and the everyday swap is zram,
    # which lives in RAM and can never hold a hibernation image. Enabling the unit
    # only advertises a capability that is not there. Suspend-to-RAM, which does
    # work, is covered by the two units below.
    in_chroot systemctl enable nvidia-suspend.service nvidia-resume.service \
        >/dev/null 2>&1 || warn "could not enable nvidia suspend/resume services"
    NVIDIA_PARAMS=" nvidia-drm.modeset=1 nvidia-drm.fbdev=1"
fi

# 3c) Keyboard quirks — per machine, never globally --------------------------
# Some Lenovo laptops need i8042.dumbkbd=1 (the kernel stops sending commands
# to the internal keyboard; found and verified on the ThinkPad E16 Gen 1). It
# is a workaround, not a default: on a healthy keyboard it disables the Caps
# Lock LED and typematic-rate control, so it is keyed on the DMI product family
# and must stay that way. i8042 is built into the Arch kernel, so this can only
# be a kernel parameter — modprobe.d never sees it. This script runs on the
# live medium, on the very hardware being installed, so /sys/class/dmi is the
# target machine's.
KBD_PARAMS=""
_dmi_family="$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)"
case "${_dmi_family}" in
    "ThinkPad E16 Gen 1")
        log "Keyboard quirk for '${_dmi_family}': adding i8042.dumbkbd=1"
        KBD_PARAMS=" i8042.dumbkbd=1"
        ;;
esac


# 3d) Broadcom wl only where there is Broadcom wireless -----------------------
# broadcom-wl-dkms is on the ISO so the live session has Wi-Fi on the BCM43xx
# chips only `wl` drives, and unpackfs carries it onto every install. There it is
# pure cost: DKMS compiles it for every installed kernel on every kernel update
# (two builds per update with linux-lts), which is also what keeps dkms and both
# header packages (~130 MB per update) on the machine. Keep it only when this
# machine — the live medium runs on the target hardware — has a Broadcom
# network controller of class 0x0280 (wireless).
_pci="${MAZE_PCI_DEVICES:-/sys/bus/pci/devices}"
_bcm_wifi=0
for _pd in "${_pci}"/*; do
    [[ "$(cat "${_pd}/vendor" 2>/dev/null)" == "0x14e4" ]] || continue
    [[ "$(cat "${_pd}/class" 2>/dev/null)" == 0x0280* ]] && { _bcm_wifi=1; break; }
done
if in_chroot pacman -Qq broadcom-wl-dkms >/dev/null 2>&1; then
    if [[ "${_bcm_wifi}" -eq 1 ]]; then
        log "Broadcom wireless present — keeping broadcom-wl-dkms and the headers it builds against"
        # Explicit, so removing orphans can never take away what wl builds
        # against. One at a time: -D fails as a whole on a missing name.
        for _p in linux-headers linux-lts-headers; do
            in_chroot pacman -Qq "${_p}" >/dev/null 2>&1 || continue
            in_chroot pacman -D --asexplicit "${_p}" >/dev/null 2>&1 || true
        done
    elif in_chroot pacman -Rns --noconfirm broadcom-wl-dkms >/dev/null 2>&1; then
        log "No Broadcom wireless — removed broadcom-wl-dkms (no DKMS build on every kernel update)"
        # Nothing left for DKMS to build: its toolchain goes too. One package
        # per call, so one that something still requires (an older maze-meta
        # depends on linux-lts-headers) cannot block the others.
        if [[ -z "$(in_chroot dkms status 2>/dev/null)" ]]; then
            for _p in dkms linux-headers linux-lts-headers; do
                in_chroot pacman -Qq "${_p}" >/dev/null 2>&1 || continue
                in_chroot pacman -Rns --noconfirm "${_p}" >/dev/null 2>&1 \
                    && log "  removed ${_p} (no DKMS module left)" \
                    || log "  kept ${_p} (still required by another package)"
            done
        fi
    else
        warn "could not remove broadcom-wl-dkms (it will keep building on kernel updates)"
    fi
fi
