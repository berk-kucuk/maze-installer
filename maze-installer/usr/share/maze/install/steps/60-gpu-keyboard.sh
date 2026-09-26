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

