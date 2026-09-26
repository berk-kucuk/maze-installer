# ---------------------------------------------------------------------------
log "Deploying Maze configuration to ${TARGET}"

# DNS inside the chroot needs no setup here: arch-chroot bind-mounts the live
# system's /etc/resolv.conf onto the target's before running the command (see
# chroot_add_resolv_conf in arch-chroot), so every in_chroot step below resolves
# names. The `cp -L /etc/resolv.conf` this used to do could never work anyway —
# the target's resolv.conf is a symlink to /run/systemd/resolve/stub-resolv.conf
# and the target's /run is a fresh tmpfs, so the copy wrote through the symlink
# to a path that does not exist and failed silently every single time.

# 1) Applications come from two sources, both handled near the end of this
#    script. Maze's OWN apps (entropy-shield, qlam, maze, ...) install from the
#    official [mazelinux] pacman repo with 'pacman -S' (see install_maze_repo_apps).
#    The third-party apps (joplin, upscayl, paru, ...) are prebuilt into the ISO
#    and arrive with unpackfs; only the ones kept off the ISO (onlyoffice-bin,
#    for size) — or missing from it — are built with makepkg and installed with
#    pacman -U inside the target chroot, as the installer-created user. paru is
#    always built from source (on the ISO or here), so it matches the libalpm
#    ABI it runs against, unlike the precompiled paru-bin.

# 2) Desktop look, tools and branding (copied from the live system) --------
log "Copying Maze desktop configuration and tools"
# Nothing is COPIED here any more. This block used to re-copy ~50 paths from
# the live system (skel, wallpapers, Plymouth/SDDM themes, the Maze tools,
# sysctl/zram/oomd/audit/ssh config) — every one of them already on the target:
# unpackfs copies the whole live root and excludes only the API filesystems
# (/proc /sys /run /dev), and since 2026-09 all of those files are owned by a
# package (maze-branding, maze-plasma-config, maze-tools, maze-hardening,
# maze-secureboot) that is installed in the live image. What remains is what
# genuinely differs between the live medium and an installed system.
#
# Scrub display/output state from the target skel so users created LATER
# (post-install) also start with a clean, auto-detected monitor/primary setup.
strip_display_state "${TARGET}/etc/skel"
# our zsh config is staged outside /etc/skel on the live medium (grml conflict)
if [[ -f /usr/local/share/maze/skel-zshrc ]]; then
    cp -a /usr/local/share/maze/skel-zshrc "${TARGET}/etc/skel/.zshrc" 2>/dev/null || warn "skel .zshrc failed"
fi

# Branded os-release. The source of truth is maze-branding's copy
# (/usr/share/maze/os-release, >= 1.6.1-2); the live medium's airootfs copy is
# only a fallback for an ISO built with an older maze-branding.
_osrel=""
for _c in /usr/share/maze/os-release /usr/local/share/maze/os-release; do
    [[ -f "${_c}" ]] && { _osrel="${_c}"; break; }
done
if [[ -n "${_osrel}" ]]; then
    cp -f "${_osrel}" "${TARGET}/usr/lib/os-release" 2>/dev/null || warn "os-release failed"
    ln -sf ../usr/lib/os-release "${TARGET}/etc/os-release" 2>/dev/null || true
    # /usr/lib/os-release is owned by the `filesystem` package, so every
    # filesystem upgrade silently puts Arch's copy back (maze-doctor then reports
    # "os-release does not identify as Maze"). maze-branding >= 1.6.1-2 ships a
    # pacman hook that re-applies it — on this machine and on every existing
    # one. Only when the target's maze-branding predates that hook, install an
    # equivalent one here. Written BEFORE any package phase, so the upgrade this
    # script itself runs is covered too.
    if [[ ! -f "${TARGET}/usr/share/libalpm/hooks/zz-maze-os-release.hook" ]]; then
        install -Dm644 "${_osrel}" "${TARGET}/usr/local/share/maze/os-release" 2>/dev/null \
            || warn "could not stage os-release for the pacman hook"
        install -Dm644 /dev/stdin "${TARGET}/etc/pacman.d/hooks/maze-os-release.hook" <<'OSRELHOOK' \
            || warn "could not install the os-release pacman hook"
# Maze Linux: re-apply the Maze os-release after the `filesystem` package
# (which owns /usr/lib/os-release) is installed or upgraded. Superseded by
# maze-branding's zz-maze-os-release.hook once that package is upgraded.
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = filesystem

[Action]
Description = Re-applying Maze Linux branding to /usr/lib/os-release...
When = PostTransaction
Depends = coreutils
Exec = /usr/bin/cp -f /usr/local/share/maze/os-release /usr/lib/os-release
OSRELHOOK
    fi
fi

# Ship the AUR installer as a manual retry helper (run it after login if the
# build below hit a transient network/build error).
install -Dm755 /usr/share/maze/target-firstboot/maze-aur-setup \
    "${TARGET}/usr/local/bin/maze-aur-setup" 2>/dev/null || warn "maze-aur-setup copy failed"

