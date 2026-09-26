log()  { printf '[maze-deploy] %s\n' "$*"; }
# Every warning is also collected (with the step it came from) so the driver can
# list them all at the end — one place to look, instead of a line lost somewhere
# in a thousand lines of output. MAZE_WARNINGS/MAZE_CRITICAL/MAZE_STEP are set up
# by deploy-to-target.sh; the defaults keep a step usable when sourced alone.
warn() {
    printf '[maze-deploy] WARNING: %s\n' "$*" >&2
    MAZE_WARNINGS+=("[${MAZE_STEP:-?}] $*")
}
# A problem that makes the installed system unsafe or unbootable. Recorded, the
# remaining steps still run (so the logs and the target are as complete as they
# can be), and then the driver exits non-zero: Calamares shows the install as
# FAILED rather than letting someone reboot into it trusting a "done".
critical() {
    printf '[maze-deploy] CRITICAL: %s\n' "$*" >&2
    MAZE_CRITICAL+=("[${MAZE_STEP:-?}] $*")
}

# stdin from /dev/null so a chroot command (e.g. chsh's PAM prompt) can never
# block the whole install waiting on input that will never arrive.
#
# SNAP_PAC_SKIP=y: snap-pac's pacman hooks call snapper for every transaction
# run in here (removing maze-installer, installing the Maze apps, the AUR
# builds). Inside arch-chroot snapper cannot resolve users and there is no
# snapper config yet (maze-snapshots-setup creates it on the first boot), so
# each hook only printed "fatal library error, lookup self" into pacman.log.
# snap-pac honours this variable and skips cleanly.
in_chroot() { arch-chroot "${TARGET}" env SNAP_PAC_SKIP=y "$@" </dev/null; }

# Bring the copied system up to date with the repos, ONCE, before anything is
# installed from them.
#
# The target is a snapshot of the ISO's package set. `pacman -Sy` followed by
# `pacman -S <pkg>` (or makepkg -s pulling build deps) against that snapshot is
# a PARTIAL UPGRADE — unsupported on Arch: new packages and their dependencies
# arrive linked against libraries newer than the ones installed, and whatever
# already depended on the old sonames can break. Refresh + full upgrade is the
# only consistent state to install into.
#
# The keyrings go first (Arch's documented procedure for an outdated system):
# the ISO's archlinux-keyring may predate the keys that signed today's packages.
# But only a keyring the repo has NEWER: `pacman -S <pkg>` installs the repo's
# version even when it is OLDER (--needed skips only an identical one), so a
# keyring the ISO shipped ahead of the repo was being downgraded here. -Su never
# downgrades, so packages the ISO carried NEWER than the repo (built from
# ./localrepo) are left exactly as shipped.
#
# Returns non-zero if the system could not be brought up to date; callers then
# skip their network installs instead of doing them on a half-synced system.
MAZE_TARGET_SYNCED=0
sync_upgrade_target() {
    [[ "${MAZE_TARGET_SYNCED}" -eq 1 ]] && return 0
    local _try _k _newer
    log "Bringing the installed system up to date with the repos (pacman -Syu)"
    for _try in 1 2 3; do
        _newer=()
        if in_chroot pacman -Sy --noconfirm; then
            # -Qu lists a package only when the synced repo has a newer version.
            for _k in archlinux-keyring mazelinux-keyring; do
                in_chroot pacman -Qqu "${_k}" >/dev/null 2>&1 && _newer+=("${_k}")
            done
        else
            warn "system update failed (attempt ${_try}/3): could not refresh the package databases; retrying in 5s"
            sleep 5
            continue
        fi
        if { [[ ${#_newer[@]} -eq 0 ]] || in_chroot pacman -S --noconfirm --needed "${_newer[@]}"; } \
           && in_chroot pacman -Su --noconfirm; then
            MAZE_TARGET_SYNCED=1
            log "Installed system is up to date"
            return 0
        fi
        warn "system update failed (attempt ${_try}/3); retrying in 5s"
        sleep 5
    done
    warn "could not bring the installed system up to date; network package installs are"
    warn "skipped to avoid a partial upgrade. After first boot run: sudo pacman -Syu && maze-aur-setup"
    return 1
}

# Rebuild the UKI for every installed kernel with `kernel-install add`.
# kernel-install output goes to /var/log/maze-kernel-install.log on the target;
# on failure its tail is also printed, because a failure here is the difference
# between a machine that boots and one that does not.
#   $1 = prefix for the failure warning (which install step this is)
MAZE_KI_LOG="${TARGET}/var/log/maze-kernel-install.log"
kernel_install_all() {
    local _label="$1" _krel _out _rc
    # A directory under /usr/lib/modules is an installed kernel only if it has
    # both `pkgbase` and `vmlinuz` (same rule as maze-initramfs-rebuild): a
    # kernel upgrade can leave the OLD version's directory behind holding only
    # DKMS-built modules, and kernel-install on that fails by definition.
    for _krel in $(in_chroot sh -c 'for d in /usr/lib/modules/*/; do
                       [ -f "${d}pkgbase" ] && [ -f "${d}vmlinuz" ] && basename "$d"
                   done; true' 2>/dev/null); do
        [[ -n "${_krel}" ]] || continue
        _out="$(in_chroot kernel-install add "${_krel}" "/usr/lib/modules/${_krel}/vmlinuz" 2>&1)"
        _rc=$?
        {
            printf '== %s: kernel-install add %s (%s) -> exit %s\n' "${_label}" "${_krel}" "$(date -Is)" "${_rc}"
            printf '%s\n' "${_out}"
        } >> "${MAZE_KI_LOG}" 2>/dev/null || true
        if [[ "${_rc}" -ne 0 ]]; then
            warn "${_label}: kernel-install add failed for ${_krel} (UKI on the ESP may be stale). Last lines:"
            printf '%s\n' "${_out}" | tail -n 20 | sed 's/^/    /' >&2
        fi
    done
}

# Firmware type of THIS install. Maze is UEFI-only — the ISO ships no BIOS
# bootmode (profiledef.sh), so the live medium only boots on UEFI and this is
# always "uefi" in practice. The check is kept as a safety net: the whole
# systemd-boot/UKI/Secure-Boot finalisation below (loader.conf, kernel-install
# add, shim signing) is UEFI-specific and guarded by is_uefi, so on the
# theoretical BIOS run it degrades to warnings instead of doing damage.
if [[ -d /sys/firmware/efi ]]; then
    MAZE_FIRMWARE="uefi"
else
    MAZE_FIRMWARE="bios"
fi
is_uefi() { [[ "${MAZE_FIRMWARE}" == "uefi" ]]; }
is_uefi || warn "Firmware is BIOS but Maze is UEFI-only — the installed system will not boot. Reboot the installer in UEFI mode."
log "Firmware detected: ${MAZE_FIRMWARE} (bootloader: systemd-boot)"

# Remove machine-specific DISPLAY / OUTPUT state from a config tree so a freshly
# installed machine NEVER inherits the build host's monitor layout or primary-
# screen choice. KDE/KWin must re-detect outputs (and pick the primary) per
# hardware on first login. Without this, the skel (which was captured from a
# multi-monitor build host) drags that host's screen state onto every install,
# which is why the wrong monitor showed up as "Primary".
#   $1 = home-like dir (its .config / .local live underneath)
strip_display_state() {
    local h="${1:-}"
    # This function deletes paths BELOW $h (rm -rf "${h}/.local/share/kscreen").
    # An empty or "/" argument would therefore aim those deletions at the LIVE
    # system running the installer, so refuse both outright instead of relying on
    # the ".config exists" test below to happen to be false.
    [[ -n "${h}" && "${h}" != "/" ]] || {
        warn "strip_display_state: refusing to run on an empty or root path"
        return 0
    }
    local cfg="${h}/.config"
    [[ -d "${cfg}" ]] || return 0
    # Wayland: the primary output is stored here as the output with "priority":1.
    # Entirely host-specific (keyed to the host's connectors/EDID) — must go.
    rm -f "${cfg}/kwinoutputconfig.json" 2>/dev/null || true
    # X11: per-output configs (incl. the primary flag) keyed by EDID hash.
    rm -rf "${h}/.local/share/kscreen" 2>/dev/null || true
    # kwinrc: drop [Tiling][<desktop-uuid>][<output-uuid>] blocks — they are
    # pinned to the build host's specific outputs and are dead weight elsewhere.
    local kwinrc="${cfg}/kwinrc"
    if [[ -f "${kwinrc}" ]] && grep -q '^\[Tiling\]' "${kwinrc}"; then
        awk '/^\[/{ drop = ($0 ~ /^\[Tiling\]/) } !drop { print }' \
            "${kwinrc}" > "${kwinrc}.maze.tmp" 2>/dev/null \
            && mv "${kwinrc}.maze.tmp" "${kwinrc}" || rm -f "${kwinrc}.maze.tmp"
    fi
    # appletsrc: blank any saved screen<->connector mapping and drop host-
    # resolution geometry keys so panels/desktops map onto THIS machine's screens.
    local appletsrc="${cfg}/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "${appletsrc}" ]]; then
        sed -i -E '/^ItemGeometries-[0-9]+x[0-9]+=/d' "${appletsrc}" 2>/dev/null || true
        sed -i -E 's/^(screenMapping|itemsOnDisabledScreens)=.*/\1=/' "${appletsrc}" 2>/dev/null || true
    fi
}

