#!/usr/bin/env bash
#
# deploy-to-target.sh — Make an installed Maze Linux system match the live ISO.
#
# Called by Calamares (shellprocess_mazedeploy module) with the target
# mountpoint as $1 (e.g. /mnt). It runs in the LIVE environment, so the live
# system's own Maze configuration is the source for everything it copies.
#
# It is intentionally best-effort: every step is guarded so a single failure
# never aborts the installation. Re-runnable.
#
set -uo pipefail

TARGET="${1:?usage: deploy-to-target.sh <target-mountpoint> [security-csv]}"
# Everything below reads, writes and DELETES under $TARGET — the pacman keyring,
# /home/*, mkinitcpio.conf, the ESP. Calamares runs this with dontChroot: true,
# so those paths are resolved on the LIVE system: if ${ROOT} ever arrived empty
# or as "/" (a failed mount, a hand-run command, a Calamares variable that did
# not expand) the script would take the running installer apart instead of the
# machine being installed. `${1:?}` above only catches unset/empty, so bar "/"
# explicitly. Stripping a trailing slash first also turns a bare "/" into "",
# which this same test then rejects.
TARGET="${TARGET%/}"
if [[ -z "${TARGET}" || "${TARGET}" == "/" ]]; then
    echo "deploy-to-target.sh: refusing to operate on '/' — that is the live system, not the install target." >&2
    exit 1
fi
if [[ ! -d "${TARGET}" ]]; then
    echo "deploy-to-target.sh: target '${TARGET}' is not a directory." >&2
    exit 1
fi
# SECURITY: clear any leftover build-time sudoers from a PREVIOUS run of this
# script. install_aur_packages() grants the build user NOPASSWD:ALL for the
# duration of the AUR phase and removes it again both explicitly and via an EXIT
# trap — but neither runs if that phase is SIGKILLed or the installer is torn
# down under it, and the AUR phase is the longest, most fragile step in the whole
# install. Left behind, the file is permanent passwordless root on the installed
# system. Sweep it here (catches a re-run over a half-finished install) and again
# unconditionally after the AUR phase.
rm -f "${TARGET}/etc/sudoers.d/99-maze-build" 2>/dev/null || true

# Maze apps are on the live ISO (copied by unpackfs) — always install all.
MAZE_APPS_CSV="all"
# Comma-separated list of selected extra packages (AUR + qemu).
# Extras packagechooser page was REMOVED — never install extras.
EXTRAS_CSV="none"

# VMware was removed from the installer entirely — vmware-workstation is an AUR
# package that never builds in the offline/chroot install. It is installed on
# demand post-install via the `maze-install-vmware` command (maze-tools).

# Comma-separated list of selected security features (from the installer's
# Security section). Empty/unset means "all" (handled below).
SECURITY_CSV="${2:-}"
# Curated AUR apps that ship with the Maze desktop — filtered by the user's
# selection on the Extras packagechooser page (EXTRAS_CSV). All are included
# when the selection file is missing (backward compatibility with direct calls).
#
# 'paru' is built FROM SOURCE (not paru-bin) on purpose: a source build compiles
# against the target's own pacman/libalpm, so it can never hit the ABI mismatch
# that makes the precompiled paru-bin break after a pacman soname bump. It is
# listed first so the AUR helper is in place early.
CURATED_AUR_TEMPLATE=(paru upscayl-bin session-desktop-bin joplin-bin onlyoffice-bin claude-code)
CURATED_AUR=()
if [[ -z "${EXTRAS_CSV}" ]]; then
    # No selection file (legacy/direct call): install everything.
    CURATED_AUR=("${CURATED_AUR_TEMPLATE[@]}")
else
    for pkg in "${CURATED_AUR_TEMPLATE[@]}"; do
        # Match the pkg name against the comma-separated CSV.
        if [[ ",${EXTRAS_CSV}," == *",${pkg},"* ]]; then
            CURATED_AUR+=("${pkg}")
        fi
    done
fi
# These must be present on EVERY installed system regardless of the (removed)
# Extras page selection — otherwise EXTRAS_CSV="none" leaves CURATED_AUR empty
# and neither would ever be installed:
#   - paru: the AUR helper. No AUR helper ships on the ISO; built from source
#     here so it matches the target's libalpm ABI (unlike paru-bin, which breaks
#     after a pacman soname bump).
#   - onlyoffice-bin: deliberately kept OFF the ISO for size, so it must be
#     installed here (needs network at install time).
# NOTE the reversed order: this loop PREPENDS, so iterating onlyoffice-bin first
# leaves paru at the head of the list. Written the other way round (paru first)
# it produced "onlyoffice-bin paru" — the exact opposite of the intent above, and
# onlyoffice-bin is a ~350 MB download with a 30-minute build ceiling and one
# retry, so a slow mirror could hold the AUR helper back for an hour.
for _always in onlyoffice-bin paru; do
    if ! printf '%s\n' "${CURATED_AUR[@]}" | grep -qx "${_always}"; then
        CURATED_AUR=("${_always}" "${CURATED_AUR[@]}")
    fi
done
# Maze's OWN applications, shipped from the [mazelinux] repo. Calamares (the
# only caller of this script) always passes the keyword "all", installing the
# whole set below.
#
# NOT listed, on purpose — and this list must agree with maze-meta's depends:
# linux-chan-ai and sentinai. Both can send data to Google Gemini (Linux Chan
# has no offline mode at all). A distribution whose promise is that nothing
# leaves the machine by default cannot install them without asking; they stay
# one `pacman -S` away in [mazelinux]. Until 2.0.0-22 they WERE in this list,
# so every install got them while maze-meta and the docs said otherwise.
DEFAULT_MAZE_APPS=(entropy-shield qlam maze-guard hazedrop haze maze-ai maze-connect maze-cloak)

log()  { printf '[maze-deploy] %s\n' "$*"; }
warn() { printf '[maze-deploy] WARNING: %s\n' "$*" >&2; }

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

# Copy a path from the live system to the same path on the target.
copy_to_target() {
    local src="$1"
    [[ -e "${src}" || -L "${src}" ]] || { warn "missing source ${src}"; return 0; }
    local dst="${TARGET}${src}"
    mkdir -p "$(dirname "${dst}")"
    # -T (--no-target-directory) is REQUIRED here: plain `cp -a src dst` only copies
    # src AS dst when dst does not exist. When dst is an existing DIRECTORY it copies
    # src INTO it instead, producing a nested duplicate —
    # /usr/share/sddm/themes/maze-oled/maze-oled, /etc/skel/.config/.config, and so on
    # for every directory this function handles. dst practically always exists,
    # because unpackfs has already copied the whole live root (including the very
    # files the maze-* packages installed) to the target before this runs, so the bug
    # hit all nine directory copies. -T makes dst the destination NAME unconditionally,
    # merging over whatever is there.
    cp -aT "${src}" "${dst}" 2>/dev/null || warn "could not copy ${src}"
}

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
#    The third-party apps (joplin, upscayl, paru, ...) are built with makepkg and
#    installed with pacman -U inside the target chroot, as the installer-created
#    user. 'paru' is built from source as part of that set so the installed
#    system has a working AUR helper for future updates (built from source, it
#    matches the target's libalpm ABI, unlike the precompiled paru-bin). The AUR
#    builds intentionally avoid a pinned local repo so the packages stay on the
#    latest version and can receive normal updates afterwards.

# 2) Desktop look, tools and branding (copied from the live system) --------
log "Copying Maze desktop configuration and tools"
# /etc/skel — KDE layout, theme, oh-my-zsh, etc.
copy_to_target /etc/skel/.config
copy_to_target /etc/skel/.local
copy_to_target /etc/skel/.oh-my-zsh
# Scrub any display/output state from the target skel so users created LATER
# (post-install) also start with a clean, auto-detected monitor/primary setup.
strip_display_state "${TARGET}/etc/skel"
# our zsh config is staged outside /etc/skel on the live medium (grml conflict)
if [[ -f /usr/local/share/maze/skel-zshrc ]]; then
    cp -a /usr/local/share/maze/skel-zshrc "${TARGET}/etc/skel/.zshrc" 2>/dev/null || warn "skel .zshrc failed"
fi
# Branding assets and shared data
# All Maze wallpaper packages (Maze, Maze1..Maze9, MazeOLED) — not just the
# default one, so the full set shows up in the Plasma wallpaper picker.
for _wp in /usr/share/wallpapers/Maze*; do
    [[ -d "${_wp}" ]] && copy_to_target "${_wp}"
done
copy_to_target /usr/share/plymouth/themes/maze
copy_to_target /usr/share/plymouth/themes/default.plymouth
copy_to_target /usr/share/pixmaps/maze-logo.png
copy_to_target /usr/share/pixmaps/maze-simple-logo.png
copy_to_target /usr/share/maze/fastfetch-logo.txt
# Branded distro logo for KDE's "About this System" (os-release LOGO=mazelinux).
copy_to_target /usr/share/icons/hicolor/128x128/apps/mazelinux.png
copy_to_target /usr/share/icons/hicolor/256x256/apps/mazelinux.png
copy_to_target /usr/share/icons/hicolor/512x512/apps/mazelinux.png
# Maze Plasma colour schemes (system-wide, so the greeter sees them too).
# Maze Dark + Maze Light schemes so the System Settings light/dark switch stays
# on-brand instead of falling back to Breeze.
copy_to_target /usr/share/color-schemes/MazeDark.colors
copy_to_target /usr/share/color-schemes/MazeLight.colors
# Maze OLED global theme (Plasma look-and-feel + splash) and the matching OLED
# SDDM login theme. The live autologin drop-in (10-maze-autologin.conf) is
# deliberately NOT copied.
copy_to_target /usr/share/plasma/look-and-feel/com.mazelinux.oled
# Matching light variant — without it the System Settings dark/light switch
# (DefaultLightLookAndFeel in kdeglobals) falls back to Breeze on the target.
copy_to_target /usr/share/plasma/look-and-feel/com.mazelinux.oled.light
copy_to_target /usr/share/sddm/themes/maze-oled
copy_to_target /etc/sddm.conf.d/20-maze-theme.conf
# Breeze greeter override — this is what BRANDS the login screen. Breeze is the
# default greeter (20-maze-theme.conf) and ships with plasma; theme.conf.user is
# our overlay on it, putting the Maze wallpaper behind the Breeze UI. SDDM merges
# theme.conf.user over the package's theme.conf, so a Plasma update refreshes the
# greeter without ever losing the branding. Copying this file is therefore not
# optional decoration: without it the installed system logs in on stock Breeze.
copy_to_target /usr/share/sddm/themes/breeze/theme.conf.user
# Maze CLI tools. NOTE: the installer itself (maze-install + its .desktop launcher)
# is intentionally NOT deployed — the system is already installed, so it must not
# appear in the menu or the dock.
copy_to_target /usr/local/bin/maze-gpu-driver
copy_to_target /usr/local/bin/maze-apply-wallpaper
# BlackArch repo enabler — the SAME tool the installer's contextualprocess step
# runs. Shipped on every installed system so a user who did NOT tick "Maze Linux
# + BlackArch" at install time can still add the repo later with a single
# `sudo maze-enable-blackarch`. (unpackfs already copies it; this is the explicit
# safety net, matching the pattern used for the other tools below.)
copy_to_target /usr/local/bin/maze-enable-blackarch
# NOTE: the old maze-tools MAC-changer helpers (mac_anonymizer.py, change-mac-now,
# mac-changer-logs) are gone — MAC randomisation is owned solely by maze-guard now.
# Maze Welcome app (first-boot greeter) + its menu entry.
copy_to_target /usr/local/bin/maze-welcome
copy_to_target /usr/share/applications/maze-welcome.desktop
# First-login helper: promote the best monitor to primary (see step below).
copy_to_target /usr/local/bin/maze-primary-screen
# Security / privacy hardening
copy_to_target /etc/fail2ban/jail.d/sshd.conf
copy_to_target /etc/ssh/sshd_config.d/00-maze-hardening.conf
# Flathub-on-first-boot helper (registers the remote when the network is up)
copy_to_target /usr/local/bin/maze-flatpak-setup
# Panic mode (Ctrl+Alt+P + tray), the Maze Sentinel security anomaly monitor, and
# the hardware privacy kill switches. The privileged work is brokered by maze-guardd (root
# daemon, wheel-only socket, fixed verb whitelist — NO pkexec/setuid), so the
# user-facing tools (maze-panic, maze-killswitch, maze-guard) hold no privilege.
# (unpackfs already copies these; the explicit copies here are a redundant
# safety net in case that ever changes.)
copy_to_target /usr/local/bin/maze-guardd
copy_to_target /usr/local/bin/maze-guardctl
copy_to_target /usr/local/bin/maze-panic
copy_to_target /usr/local/bin/maze-panic-restore
copy_to_target /usr/share/applications/maze-panic.desktop
# Panic tray is a Plasma WIDGET (plasmoid), not a Qt app — added to the system
# tray via skel; ship the plasmoid package.
copy_to_target /usr/share/plasma/plasmoids/com.mazelinux.panic
copy_to_target /usr/local/bin/maze-sentinel
copy_to_target /usr/local/bin/maze-sentinel-setup
copy_to_target /etc/maze/sentinel.conf
copy_to_target /usr/local/bin/maze-killswitch
copy_to_target /usr/local/bin/maze-hardware
copy_to_target /usr/share/applications/maze-hardware.desktop
# Maze Control Center + shared Python libs (maze_ui / maze_status) used by it
# and by maze-welcome — without these the welcome app fails to import.
copy_to_target /usr/local/bin/maze-control-center
copy_to_target /usr/share/applications/maze-control-center.desktop
copy_to_target /usr/local/lib/maze
# Kernel/network hardening and zram swap. These live in /etc, which (unlike
# /etc/skel) is not copied wholesale.
# NOTE: /etc/firefox/policies/policies.json is deliberately NOT copied — the
# live ISO's policy pins the Firefox homepage/first-run page to the Maze site,
# and an installed system should keep Firefox's own defaults instead.
copy_to_target /etc/sysctl.d/99-maze-hardening.conf
copy_to_target /etc/systemd/zram-generator.conf
# systemd-oomd tuning + baseline auditd rules.
copy_to_target /etc/systemd/oomd.conf.d/10-maze.conf
copy_to_target /etc/systemd/system/-.slice.d/10-oomd.conf
copy_to_target /etc/systemd/system/user@.service.d/10-oomd.conf
copy_to_target /etc/audit/rules.d/maze.rules

# Branded os-release (write directly; do not rely on package files)
if [[ -f /usr/local/share/maze/os-release ]]; then
    cp -f /usr/local/share/maze/os-release "${TARGET}/usr/lib/os-release" 2>/dev/null || warn "os-release failed"
    ln -sf ../usr/lib/os-release "${TARGET}/etc/os-release" 2>/dev/null || true
fi

# Ship the AUR installer as a manual retry helper (run it after login if the
# build below hit a transient network/build error).
install -Dm755 /usr/share/maze/target-firstboot/maze-aur-setup \
    "${TARGET}/usr/local/bin/maze-aur-setup" 2>/dev/null || warn "maze-aur-setup copy failed"

# Maze's OWN applications (entropy-shield, qlam, maze, ...) now ship from the
# official [mazelinux] pacman repo — added to the target's pacman.conf in step
# 7b — so they are installed with a plain 'pacman -S' instead of being built from
# the AUR. The user's installer-menu selection (MAZE_APPS_CSV) decides which ones.
# Fast and reliable, so this runs before the slow AUR builds below. Best-effort.
install_maze_repo_apps() {
    local pkgs=() a _selected=()
    if [[ "${MAZE_APPS_CSV}" == "all" ]]; then
        # "all" => the full default Maze app set (the Calamares path passes this).
        pkgs=("${DEFAULT_MAZE_APPS[@]}")
    else
        IFS=',' read -ra _selected <<< "${MAZE_APPS_CSV}"
        for a in "${_selected[@]}"; do [[ -n "${a}" ]] && pkgs+=("${a}"); done
    fi
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log "No Maze applications selected; skipping [mazelinux] install"
        return 0
    fi
    log "Installing Maze applications from the [mazelinux] repo: ${pkgs[*]}"
    local _try
    # Refresh databases (retried) so a transient mirror/repo hiccup does not drop
    # the whole set.
    for _try in 1 2 3; do
        in_chroot pacman -Sy --noconfirm && break
        warn "pacman -Sy failed (attempt ${_try}/3); retrying in 5s"
        sleep 5
    done
    # Only install what is MISSING. unpackfs has already put every app that was
    # on the ISO onto the target, so this step exists for the ones that were
    # not (a selection the ISO does not carry). It must never touch the rest:
    # `pacman -S --needed` only skips an EXACT version match — when the
    # installed copy is NEWER than the repo's (an ISO built from ./localrepo
    # with a package that is not published yet), pacman DOWNGRADES it to the
    # repo version. Seen on a real install, 14 Sep 2026: the ISO shipped haze
    # 2.11.2 and maze-cloak 1.2.1-2, the installed system ended up with 2.11.1
    # and 1.2.1-1. Anything already installed is left exactly as unpackfs
    # delivered it; updates are pacman -Syu's job after first boot.
    local _avail=() _p
    for _p in "${pkgs[@]}"; do
        if in_chroot pacman -Qq "${_p}" >/dev/null 2>&1; then
            log "  ${_p}: already on the target ($(in_chroot pacman -Q "${_p}" 2>/dev/null | cut -d' ' -f2)) — left as shipped"
            continue
        fi
        # Drop any package that is not actually in a synced repo. pacman -S
        # aborts the ENTIRE transaction on a single "target not found", which
        # would take every other app in the list down with it.
        if in_chroot pacman -Si "${_p}" >/dev/null 2>&1; then
            _avail+=("${_p}")
        else
            warn "repo package '${_p}' not found in synced repos — skipping"
        fi
    done
    pkgs=("${_avail[@]}")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log "Every selected Maze application is already on the target; nothing to install from [mazelinux]"
        return 0
    fi
    for _try in 1 2 3; do
        if in_chroot pacman -S --noconfirm --needed "${pkgs[@]}"; then
            log "Maze applications installed from [mazelinux]"
            return 0
        fi
        warn "Maze app install from [mazelinux] failed (attempt ${_try}/3); retrying in 5s"
        sleep 5
    done
    warn "could not install Maze applications from [mazelinux] (run 'maze-aur-setup' after login)"
    return 0
}

# The actual AUR build is the slowest, most failure-prone step (large downloads,
# building as the user), so it is deferred to the very END of this script via the
# function below. That way the fast, critical desktop config — Maze Plymouth
# splash, wallpaper, branded greeter, services — is ALWAYS applied first and can
# never be skipped because an AUR build was slow or got stuck.
install_aur_packages() {
    # Only the third-party curated apps are built from the AUR here. Maze's OWN
    # applications (the user's MAZE_APPS_CSV selection) now ship from the
    # [mazelinux] repo and are installed separately by install_maze_repo_apps().
    local aur_list=("${CURATED_AUR[@]}")

    log "Installing AUR packages from the AUR (makepkg): ${aur_list[*]:-<none>}"
    local build_user
    build_user=$(in_chroot awk -F: '$3>=1000 && $3<65000 {print $1; exit}' /etc/passwd 2>/dev/null)
    if [[ -z "${build_user}" || ${#aur_list[@]} -eq 0 ]]; then
        warn "no regular user found; skipping AUR install (run maze-aur-setup after login)"
        return 0
    fi
    # The build runs as ${build_user}; put the helper script in *their* home so
    # it is always readable/executable by them. /root (mode 700) and /tmp both
    # failed here before ("Permission denied", then "No such file or directory"
    # because arch-chroot does not share the live /tmp the way we assumed).
    local build_home
    build_home=$(in_chroot getent passwd "${build_user}" | cut -d: -f6)
    [[ -n "${build_home}" ]] || build_home="/home/${build_user}"
    log "AUR build user: ${build_user} (home ${build_home}; logging to /var/log/maze-aur-install.log on the target)"

    # Temporary passwordless sudo for the build user (makepkg calls sudo pacman).
    local sudoers="${TARGET}/etc/sudoers.d/99-maze-build"
    # env_keep: the build script's `sudo pacman -U` must inherit SNAP_PAC_SKIP
    # from in_chroot (sudo's env_reset would drop it and snap-pac would fire).
    printf 'Defaults env_keep += "SNAP_PAC_SKIP"\n%s ALL=(ALL) NOPASSWD: ALL\n' "${build_user}" > "${sudoers}"
    chmod 440 "${sudoers}"
    trap 'rm -f "'"${sudoers}"'"' EXIT

    # Refresh the package databases (retried): a transient mirror hiccup here
    # otherwise cascades into every makepkg dependency resolution failing.
    local _try
    for _try in 1 2 3; do
        in_chroot pacman -Sy --noconfirm && break
        warn "pacman -Sy failed (attempt ${_try}/3); retrying in 5s"
        sleep 5
    done

    # Write the build steps to a file in the build user's home and run it as the
    # user. A standalone script (instead of a heredoc piped through
    # arch-chroot+sudo) is far more reliable. stdin is /dev/null so any
    # unexpected prompt fails fast instead of hanging; each package gets a hard
    # timeout for the same reason.
    local buildscript="${TARGET}${build_home}/.maze-aur-build.sh"
    local buildscript_in_chroot="${build_home}/.maze-aur-build.sh"
    cat > "${buildscript}" <<'MAKEPKG'
#!/usr/bin/env bash
set -u
exec </dev/null
PKGS=("$@")
total=${#PKGS[@]}
rc=0
failed=()

# Verbose build output (git/makepkg/pacman) goes ONLY to this file; the terminal
# gets just short, human-readable status lines ("Installing onlyoffice-bin from the
# AUR..."). The file lives in the build user's home (always writable) and is
# folded into /var/log/maze-aur-install.log by the caller afterwards.
VLOG="${HOME:-/tmp}/.maze-aur-verbose.log"
: > "${VLOG}" 2>/dev/null || VLOG=/dev/null

# Retry a network-bound command a few times with a short backoff (its output goes
# to the verbose log), so a single unresponsive mirror/AUR no longer drops a
# package — which is how a transient clone/build failure used to drop an app.
retry() {
    local tries="$1"; shift
    local n=1
    while true; do
        "$@" >>"${VLOG}" 2>&1 && return 0
        if (( n >= tries )); then
            return 1
        fi
        echo "   ...attempt ${n}/${tries} failed, retrying in $((n*5))s"
        sleep $((n*5))
        ((n++))
    done
}

# Clone, build and install one AUR package by name. Returns 0 on success. Always
# clones fresh from the AUR so packages are the current upstream version with the
# latest PKGBUILD — never a stale snapshot frozen into the ISO. The chroot has
# working DNS (resolv.conf copied up front). Every network-bound step is retried
# so a momentarily unresponsive AUR/repo does not drop the package. All the noisy
# command output is sent to ${VLOG}; only short status lines reach the terminal.
build_one() {
    local pkg="$1" tmp ok=1
    # Already installed? Then there is nothing to build. The curated apps that
    # ship on the live ISO (upscayl-bin, session-desktop-bin,
    # joplin-bin, claude-code, ...) were prebuilt from the AUR into Maze's local
    # repo at ISO-build time, so unpackfs has already copied them onto the target
    # — fully built and pacman-registered. Re-cloning and re-building them here
    # over the network was pure redundant work and the single biggest reason a
    # fresh install took 30+ minutes. Skip them; only the apps deliberately kept
    # off the ISO (e.g. onlyoffice-bin for size, paru built from source for ABI
    # safety) actually reach the makepkg path below. Installed apps stay at the
    # ISO snapshot version; the user updates them later with pacman/paru.
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
        echo "   -> ${pkg} already installed (copied from the ISO); skipping AUR build."
        return 0
    fi
    tmp=$(mktemp -d)
    if retry 3 git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$tmp/$pkg"; then
        # Build only (-s installs build/runtime deps from the repos), with a
        # 30-minute ceiling so a stuck build can never block the install. The
        # whole makepkg run is retried because most build failures here are
        # transient source/dependency download errors, not real build breaks.
        if retry 2 timeout 1800 bash -c "cd '$tmp/$pkg' && makepkg -s --noconfirm --needed"; then
            # Install the built package(s) ourselves with --overwrite so leftover
            # files from a previous partial/retried run don't cause a
            # "conflicting files" failure (these apps ship a self-contained venv).
            shopt -s nullglob
            # makepkg's default OPTIONS=(debug) also emits <pkg>-debug split
            # packages; installing them left paru-debug on every machine. Skip
            # them — nobody debugs paru with gdb on a desktop install.
            local pkgfiles=() _pf
            for _pf in "$tmp/$pkg"/*.pkg.tar.*; do
                case "$(basename "${_pf}")" in *-debug-*) continue ;; esac
                pkgfiles+=("${_pf}")
            done
            shopt -u nullglob
            if [[ ${#pkgfiles[@]} -gt 0 ]]; then
                if retry 2 sudo pacman -U --noconfirm --needed --overwrite '*' "${pkgfiles[@]}"; then
                    ok=0
                fi
            fi
        fi
    fi
    rm -rf "$tmp"
    return "$ok"
}

i=0
for pkg in "${PKGS[@]}"; do
    ((i++))
    echo ":: (${i}/${total}) Installing ${pkg} from the AUR..."
    if build_one "$pkg"; then
        echo "   -> ${pkg} installed."
    else
        echo "   -> ERROR: ${pkg} failed (see /var/log/maze-aur-install.log)."
        rc=1; failed+=("$pkg")
    fi
done

# AUR helper fallback: if paru was requested but did not end up installed (e.g.
# its source build failed), try yay instead — also built from source so it
# matches this system's libalpm ABI — so the system still has a usable helper.
if printf '%s\n' "${PKGS[@]}" | grep -qx paru && ! pacman -Qq paru >/dev/null 2>&1; then
    echo ":: paru not installed — falling back to yay as the AUR helper..."
    if build_one yay; then
        echo "   -> yay installed (paru fallback)."
        # A working helper is present, so paru's earlier failure is no longer a
        # real problem — drop it from the failure list.
        _kept=()
        for _x in "${failed[@]}"; do [[ "$_x" == paru ]] || _kept+=("$_x"); done
        failed=("${_kept[@]}")
        (( ${#failed[@]} == 0 )) && rc=0
    else
        echo "   -> ERROR: yay fallback also failed — no AUR helper installed."
        failed+=(yay)
    fi
fi

echo ""
if (( ${#failed[@]} == 0 )); then
    echo ":: All AUR packages installed successfully."
else
    echo ":: Done with errors. Failed: ${failed[*]}"
    echo ":: Re-run 'maze-aur-setup' after login to retry the failed ones."
fi
exit "$rc"
MAKEPKG
    chmod 755 "${buildscript}"
    # Owned by the build user so they can read/execute it.
    in_chroot chown "${build_user}:${build_user}" "${buildscript_in_chroot}" 2>/dev/null || true

    # The build script prints only short status lines ("Installing onlyoffice-bin from
    # the AUR...") to stdout; post_install runs this with peek_output=True, so the
    # user sees those concise lines live instead of a frozen screen. The verbose
    # git/makepkg/pacman output is written to the build user's ~/.maze-aur-verbose.log
    # and folded into /var/log/maze-aur-install.log afterwards for debugging.
    log "Installing AUR packages now — progress follows (full details in /var/log/maze-aur-install.log):"
    in_chroot sudo -u "${build_user}" -H bash "${buildscript_in_chroot}" "${aur_list[@]}" 2>&1 \
        | tee "${TARGET}/var/log/maze-aur-install.log"
    local _aur_rc="${PIPESTATUS[0]}"
    # Append the detailed build transcript so the log has both the summary and the
    # full output, even though only the summary was shown on screen.
    local _vlog="${TARGET}${build_home}/.maze-aur-verbose.log"
    if [[ -f "${_vlog}" ]]; then
        { echo ""; echo "===== detailed build log ====="; cat "${_vlog}"; } \
            >> "${TARGET}/var/log/maze-aur-install.log" 2>/dev/null || true
        rm -f "${_vlog}"
    fi
    if [[ "${_aur_rc}" -ne 0 ]]; then
        warn "AUR install had failures — see /var/log/maze-aur-install.log (or run 'maze-aur-setup' after login)"
    fi

    rm -f "${buildscript}"
    rm -f "${sudoers}"
    trap - EXIT
}

# Secure Boot (shim + per-machine MOK) — ported from the archinstall installer so
# the Calamares path gets the SAME model:
#   firmware -> shim (Microsoft-signed) -> systemd-boot (Maze-signed as
#   grubx64.efi) -> kernel (Maze-signed).
# A per-machine key is generated (private half never leaves the target), shim is
# taken from the live system (shim-signed is AUR, preinstalled on the live ISO),
# the bootloader + kernels are signed, and a pacman hook + .path unit keep them
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
    local bn
    for bn in $(in_chroot efibootmgr -v 2>/dev/null \
                  | grep -iE 'systemd-boot(-fallback)?x64\.efi' \
                  | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p'); do
        in_chroot efibootmgr --bootnum "${bn}" --delete-bootnum >/dev/null 2>&1 \
            && log "Secure Boot: removed unsigned direct systemd-boot entry Boot${bn}" \
            || true
    done

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

# 2c) Installed system must not advertise the installer ---------------------
# Remove the "Install Maze Linux" launcher from the panel/dock in the skel that
# will be copied to each user (the live ISO keeps it; the installed system does
# not need it). The live skel was already copied above, so patch it here.
log "Removing the installer launcher from the panel (installed system)"
strip_installer_launcher() {
    local appletsrc="$1"
    [[ -f "${appletsrc}" ]] || return 0
    # Drop the Calamares installer .desktop entry from any 'launchers=' list.
    sed -i -E 's#applications:maze-calamares\.desktop,?##g'  "${appletsrc}" 2>/dev/null || true
}
strip_installer_launcher "${TARGET}/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"

# 2b-ter) Firefox as the default browser on the installed system -------------
# Firefox is Maze's browser. The skel's own mimeapps.list already points at it,
# but /etc/xdg/mimeapps.list — the SYSTEM-WIDE fallback that covers accounts
# created later, outside skel — does not exist on the ISO, so this is what puts
# it there. Rewrites ONLY the web handler keys; mailto/message-rfc822
# (Thunderbird) and anything else in the file are preserved. Creates the file,
# and any missing section, when absent.
set_default_browser() {
    local f="$1" tmp
    [[ -n "${f}" ]] || return 0
    mkdir -p "$(dirname "${f}")" 2>/dev/null || true
    [[ -f "${f}" ]] || : > "${f}"
    tmp="${f}.maze-tmp"
    awk '
        BEGIN {
            n = split("x-scheme-handler/http x-scheme-handler/https x-scheme-handler/about \
                       x-scheme-handler/unknown x-scheme-handler/chrome text/html \
                       application/xhtml+xml", k, /[ \t\n]+/)
        }
        # Drop every pre-existing web-handler line, wherever it sits.
        { for (i = 1; i <= n; i++) if (index($0, k[i] "=") == 1) next }
        /^\[Default Applications\]/ {
            print; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop"; d = 1; next
        }
        /^\[Added Associations\]/ {
            print; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop;"; a = 1; next
        }
        { print }
        END {
            if (!d) { print "[Default Applications]"; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop" }
            if (!a) { print ""; print "[Added Associations]"; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop;" }
        }
    ' "${f}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${f}" 2>/dev/null \
        || { rm -f "${tmp}" 2>/dev/null; warn "default browser: could not update ${f}"; return 0; }
    chmod 644 "${f}" 2>/dev/null || true
}
# KDE keeps its OWN default-browser key in kdeglobals ([General]
# BrowserApplication) and several KDE apps consult it before mimeapps.list, so a
# stale value there would win over everything above. Rewrite it when present;
# when the key is absent (the case on a current ISO) KDE falls back to
# mimeapps.list, which is already correct, so there is nothing to add.
set_kde_browser() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    sed -i -E 's#^BrowserApplication=.*$#BrowserApplication=firefox.desktop#' "${f}" 2>/dev/null \
        || warn "default browser: could not update ${f}"
}
log "Setting Firefox as the default browser"
# System-wide fallback (covers accounts created later that bypass skel) …
set_default_browser "${TARGET}/etc/xdg/mimeapps.list"
# … and the skel every new user is seeded from.
set_default_browser "${TARGET}/etc/skel/.config/mimeapps.list"
set_kde_browser     "${TARGET}/etc/skel/.config/kdeglobals"

# 2c-bis) Strip LIVE-ONLY files that the Calamares OFFLINE (unpackfs) install
# copies wholesale onto the target. The live medium is intentionally permissive
# (passwordless sudo/pkexec, autologin) so the installer can run unattended; NONE
# of that may reach the installed system. SECURITY: do not remove this block.
log "Stripping live-only files (autologin / passwordless sudo+pkexec / installers)"
# 1. Passwordless sudo for wheel (live only). Calamares' users module writes a
#    password-REQUIRED wheel sudoers file; we additionally guarantee one below.
rm -f "${TARGET}/etc/sudoers.d/10-maze" 2>/dev/null || true
# 2. Passwordless pkexec polkit rule that the live medium uses to elevate the
#    Calamares launcher silently — catastrophic if left on a real system.
rm -f "${TARGET}/etc/polkit-1/rules.d/49-maze-calamares.rules" 2>/dev/null || true
# 3. Console autologin (getty@tty1) and the SDDM autologin drop-in for 'maze'.
rm -f "${TARGET}/etc/systemd/system/getty@tty1.service.d/autologin.conf" 2>/dev/null || true
rmdir "${TARGET}/etc/systemd/system/getty@tty1.service.d" 2>/dev/null || true
rm -f "${TARGET}/etc/sddm.conf.d/10-maze-autologin.conf" 2>/dev/null || true
# 3b. The Firefox enterprise policy is LIVE-ONLY. It pins the homepage and the
#     first-run page to the Maze site, which is what the live session should
#     show — but an installed system's Firefox must come up with its own stock
#     defaults. unpackfs copies the whole live root, so the file is already on
#     the target and has to be deleted explicitly (the deploy no longer copies
#     it either). rmdir only removes the directories if nothing else lives there.
rm -f "${TARGET}/etc/firefox/policies/policies.json" 2>/dev/null || true
rmdir "${TARGET}/etc/firefox/policies" "${TARGET}/etc/firefox" 2>/dev/null || true
# 4. The Calamares installer launcher itself.
rm -f "${TARGET}/usr/local/bin/maze-calamares" 2>/dev/null || true
rm -f "${TARGET}/usr/share/applications/maze-calamares.desktop" 2>/dev/null || true

# Deleting the FILES is not enough: maze-installer stays registered in the
# target's pacman database, so every `pacman -Qkk` on the installed machine
# reports the files we just removed as missing, forever — and calamares plus
# xorg-xhost, pulled in only to run the installer, stay on the desktop.
#
# Remove the packages properly. This runs in the TARGET chroot, so the Calamares
# process driving this install (which lives on the LIVE medium) is untouched.
#
# calamares and xorg-xhost are named EXPLICITLY: packages.x86_64 lists both, so
# pacman marks them "explicitly installed" and `-Rns maze-installer` never
# touches them (the old comment here assumed it would; a real install kept
# calamares 3.4.2 on the desktop). Each name is checked first — a single
# missing target aborts the whole -Rns transaction.
_live_pkgs=()
for _lp in maze-installer calamares xorg-xhost; do
    in_chroot pacman -Qq "${_lp}" >/dev/null 2>&1 && _live_pkgs+=("${_lp}")
done
if [[ ${#_live_pkgs[@]} -gt 0 ]]; then
    if in_chroot pacman -Rns --noconfirm "${_live_pkgs[@]}" >/dev/null 2>&1; then
        log "Removed the live-only installer packages from the installed system: ${_live_pkgs[*]}"
    else
        warn "Could not remove ${_live_pkgs[*]} from the target; run 'sudo pacman -Rns ${_live_pkgs[*]}' after first boot"
    fi
fi
# 5. The live-user build helper (harmless but live-only).
rm -f "${TARGET}/usr/local/share/maze/setup-live-user.sh" 2>/dev/null || true
# 5a-bis. archiso/releng leftovers that nothing on an installed system uses.
#     unpackfs copies them all; they are harmless but they are also noise in
#     `systemctl list-unit-files`, /usr/local/bin and root's login. The reflector
#     config is NOT in this list: reflector.timer (enabled) reads it.
rm -f "${TARGET}/etc/systemd/system/choose-mirror.service" \
      "${TARGET}/etc/systemd/system/livecd-talk.service" \
      "${TARGET}/etc/systemd/system/livecd-alsa-unmuter.service" \
      "${TARGET}"/etc/systemd/system/*.wants/choose-mirror.service \
      "${TARGET}"/etc/systemd/system/*.wants/livecd-talk.service \
      "${TARGET}"/etc/systemd/system/*.wants/livecd-alsa-unmuter.service \
      "${TARGET}/usr/local/bin/choose-mirror" \
      "${TARGET}/usr/local/bin/Installation_guide" \
      "${TARGET}/usr/local/bin/livecd-sound" \
      "${TARGET}/root/.automated_script.sh" \
      "${TARGET}/root/.zlogin" \
      "${TARGET}/etc/systemd/network/20-ethernet.network" \
      "${TARGET}/etc/systemd/network/20-wlan.network" \
      "${TARGET}/etc/systemd/network/20-wwan.network" \
      "${TARGET}/etc/systemd/system/systemd-networkd-wait-online.service.d/wait-for-only-one-interface.conf" \
      2>/dev/null || true
rm -rf "${TARGET}/usr/local/share/livecd-sound" 2>/dev/null || true
rmdir "${TARGET}/etc/systemd/system/systemd-networkd-wait-online.service.d" 2>/dev/null || true
# 5b. The live medium's /etc/motd ("...live and install medium", "run maze-install",
#     "default user is root no password") must not greet an installed system.
rm -f "${TARGET}/etc/motd" 2>/dev/null || true
# ...and replace it with one that documents the UPDATE MODEL, because this is the
# single most surprising thing about the installed system.
#
# The third-party desktop apps (Joplin, Upscayl, Session, onlyoffice,
# claude-code) come from the AUR: they were built into Maze's build-time local
# repo and copied here by unpackfs, and that repo is deliberately dropped from
# this machine's pacman.conf (its Server is a build-host file:// path). So pacman
# has no repo that provides them — they are FOREIGN packages, and `pacman -Syu`
# silently leaves them at their install-time version forever. `paru -Syu` checks
# the AUR for exactly those packages and is what actually updates them. paru is
# installed for this reason (and maze-aur-setup re-runs on first boot, falling
# back to yay, if the install-time build did not finish).
cat > "${TARGET}/etc/motd" <<'TARGETMOTD'

  Maze Linux

  Updating this system:
    sudo pacman -Syu     official repos + [mazelinux]  (system, Maze packages)
    paru -Syu            the above PLUS the AUR desktop apps
                         (Joplin, Upscayl, Session, ...)

  The AUR apps are not in any pacman repo, so `pacman -Syu` alone will never
  update them. Use `paru -Syu` for a full update.

  mazelinux --help   Maze tools     maze-control-center   settings GUI

TARGETMOTD
chmod 644 "${TARGET}/etc/motd" 2>/dev/null || true
# 5b-bis. The archiso SSH drop-in allows root login with password (live only).
#     Remove it so the installed system respects 00-maze-hardening.conf's
#     PermitRootLogin no. (00-maze-hardening.conf is copied separately above.)
rm -f "${TARGET}/etc/ssh/sshd_config.d/10-archiso.conf" 2>/dev/null || true
# 5c. The live "never suspend/hibernate/lid" logind drop-in keeps an installed
#     LAPTOP from sleeping on lid-close and ignores the suspend/hibernate keys.
#     It is live-only — remove it so power management works on the real system.
rm -f "${TARGET}/etc/systemd/logind.conf.d/do-not-suspend.conf" 2>/dev/null || true
# 5d. The live journald drop-in forces Storage=volatile (right for a read-only
#     medium, WRONG for an installed system): left in place it silently wipes
#     the journal on every reboot, so auditing/troubleshooting history is lost.
#     Remove it so journald reverts to its persistent default (auto).
rm -f "${TARGET}/etc/systemd/journald.conf.d/volatile-storage.conf" 2>/dev/null || true
rmdir "${TARGET}/etc/systemd/journald.conf.d" 2>/dev/null || true
# 5e. The archiso resolved drop-in enables MulticastDNS — fine on a throwaway
#     live session, but on an installed privacy-focused desktop mDNS broadcasts
#     the hostname to the local network. Remove both live-only resolved drop-ins.
#     Removing archiso.conf is not enough on its own: resolved's compiled-in
#     default is ALSO MulticastDNS=yes (and LLMNR=yes), which is why
#     maze-hardening >= 1.0.0-4 ships resolved.conf.d/zz-maze-privacy.conf
#     (MulticastDNS=no, LLMNR=no) — that file stays. No DNS SERVER override is
#     shipped on purpose: a global resolver broke VPN/DHCP split-DNS and Tor
#     (see maze-hardening/PKGBUILD); DNS follows the connection.
rm -f "${TARGET}/etc/systemd/resolved.conf.d/archiso.conf" 2>/dev/null || true
rm -f "${TARGET}/etc/systemd/resolved.conf.d/maze-dns.conf" 2>/dev/null || true
# 5f. LAN silence, belt and braces with maze-hardening.install (which already
#     ran in the ISO build chroot and left its marker): passim (fwupd's LAN
#     firmware-cache sharing daemon) socket-activates avahi-daemon, and the two
#     together advertise the machine over mDNS. Mask both on the target.
in_chroot systemctl mask passim.service avahi-daemon.socket avahi-daemon.service >/dev/null 2>&1 || true
# NOTE: the live /home/maze leftover is purged EARLY by calamares-mount-api.sh
# (before the Calamares `users` module runs), NOT here — deleting it at this
# point would wipe the home of a real user who named THEIR OWN account 'maze'.

# Guarantee a password-REQUIRED sudoers rule for wheel on the target, regardless
# of whether Calamares' users module wrote its own (file name varies by version).
# Written atomically with 0440 so sudo accepts it.
_sudoers_dir="${TARGET}/etc/sudoers.d"
if [[ -d "${_sudoers_dir}" ]]; then
    printf '# Maze Linux: members of group wheel may use sudo (password required).\n%%wheel ALL=(ALL:ALL) ALL\n' \
        > "${_sudoers_dir}/10-maze-wheel" 2>/dev/null \
        && chmod 0440 "${_sudoers_dir}/10-maze-wheel" 2>/dev/null \
        || warn "could not write target wheel sudoers"
fi

# 2d) Maze wallpaper on the installed system --------------------------------
# Patch the Plasma defaults so "Maze" is the default wallpaper (covers fresh
# profiles / fallback when the live containment's plugin is unavailable).
if [[ -f /usr/local/share/maze/set-default-wallpaper.sh ]]; then
    install -Dm755 /usr/local/share/maze/set-default-wallpaper.sh \
        "${TARGET}/usr/local/share/maze/set-default-wallpaper.sh" 2>/dev/null || true
    in_chroot /usr/local/share/maze/set-default-wallpaper.sh >/dev/null 2>&1 \
        || warn "set-default-wallpaper on target failed"
fi

# 2e) Maze Welcome on the FIRST boot after install -------------------------
# Drop the welcome autostart into the target skel so each newly created user
# sees it once on first login. The app deletes this entry the first time it
# runs, so it never opens again. This lives only on the installed system (it is
# NOT in the live ISO's /etc/skel), so the live session never autostarts it.
if [[ -f /usr/share/maze/target-firstboot/maze-welcome-autostart.desktop ]]; then
    install -Dm644 /usr/share/maze/target-firstboot/maze-welcome-autostart.desktop \
        "${TARGET}/etc/skel/.config/autostart/maze-welcome.desktop" 2>/dev/null \
        || warn "welcome autostart install failed"
fi

# 2f) Best monitor as primary on the FIRST login ---------------------------
# Multi-monitor installs start with no saved screen state (it is stripped above
# so KWin re-detects per hardware), so KWin can make the wrong connector primary
# and the Maze panel — pinned to screen 0 — lands on the wrong monitor. The
# maze-primary-screen helper promotes the highest-resolution output to primary
# on first login, then drops a per-user marker so it never overrides the user's
# own Display-settings choices afterwards. Installed-system only (not live skel).
if [[ -f /usr/share/maze/target-firstboot/maze-primary-screen-autostart.desktop ]]; then
    install -Dm644 /usr/share/maze/target-firstboot/maze-primary-screen-autostart.desktop \
        "${TARGET}/etc/skel/.config/autostart/maze-primary-screen.desktop" 2>/dev/null \
        || warn "primary-screen autostart install failed"
fi

# 2f) Remove KDE's stock Plasma Welcome so only the Maze Welcome app appears.
# -Rdd ignores the plasma-meta dependency (harmless: meta-package only). Without
# the plasma-welcome binary, its autostart entry simply does nothing. We also
# keep the skel Hidden=true mask as a fallback in case an upgrade pulls it back.
if in_chroot pacman -Qq plasma-welcome >/dev/null 2>&1; then
    log "Removing KDE's stock Plasma Welcome (only Maze Welcome should run)"
    in_chroot pacman -Rdd --noconfirm plasma-welcome >/dev/null 2>&1 \
        || warn "could not remove plasma-welcome (Hidden=true mask still applies)"
fi

# 2g) Default account picture — the Maze maze-block logo --------------------
# Drop the logo into the skel as ~/.face.icon (KDE and SDDM use it as the user
# avatar). Each created user also gets an authoritative AccountsService entry in
# the per-user loop below, which is what the login screen and System Settings
# read first; ~/.face.icon is the fallback. Both point at the same image.
MAZE_AVATAR_SRC="/usr/share/pixmaps/maze-user-avatar.png"
if [[ -f "${MAZE_AVATAR_SRC}" ]]; then
    install -Dm644 "${MAZE_AVATAR_SRC}" "${TARGET}/etc/skel/.face.icon" 2>/dev/null \
        || warn "skel .face.icon install failed"
fi

# 3) Apply the desktop config to the user(s) created by the installer -------
log "Applying Maze defaults to user home directories"
for home in "${TARGET}"/home/*; do
    [[ -d "${home}" ]] || continue
    user=$(basename "${home}")
    owner_uid=$(stat -c '%u' "${home}")
    owner_gid=$(stat -c '%g' "${home}")
    # Maze Guard gates its privileged-helper control socket (/run/maze/maze.sock)
    # on the `maze` group — members drive the firewall / MAC randomiser without a
    # root prompt. TWO things must be true, and BOTH were broken before:
    #   1) The group must EXIST. removeuser (userdel -r maze) deletes the live
    #      `maze` user AND its same-named primary group, so by the time we run the
    #      group is GONE — recreate it (maze-guard's sysusers.d normally ships it).
    #      This is exactly what reinstalling maze-guard did to fix it by hand.
    #   2) The new user must be a MEMBER — add them.
    # Skipping (1) is why the earlier "add user to maze" alone silently no-op'd
    # (gpasswd on a non-existent group) and maze-guard kept asking for root.
    in_chroot getent group maze >/dev/null 2>&1 || in_chroot groupadd -r maze >/dev/null 2>&1 || true
    in_chroot gpasswd -a "${user}" maze >/dev/null 2>&1 || true
    # Same optional groups the live user gets in setup-live-user.sh: wireshark
    # (packet capture without root — wireshark-qt ships on every install),
    # kvm/libvirt (only exist once virtualisation is installed, then the user
    # should not have to log out and back in to use it). Skipped when absent.
    for _og in wireshark kvm libvirt; do
        in_chroot getent group "${_og}" >/dev/null 2>&1 \
            && in_chroot gpasswd -a "${user}" "${_og}" >/dev/null 2>&1 || true
    done
    cp -an "${TARGET}/etc/skel/." "${home}/" 2>/dev/null || warn "skel copy to ${home} failed"
    # FORCE the Maze .zshrc over whatever the home already has. grml-zsh-config
    # ships its OWN /etc/skel/.zshrc, so Calamares seeds the home with grml's
    # version at account-creation; the no-clobber copy above then can't replace it
    # and the user loses the Maze oh-my-zsh prompt + fastfetch banner. Overwrite
    # it explicitly. Same for .oh-my-zsh (must be the Maze one).
    if [[ -f "${TARGET}/etc/skel/.zshrc" ]]; then
        cp -f "${TARGET}/etc/skel/.zshrc" "${home}/.zshrc" 2>/dev/null || true
    fi
    [[ -d "${TARGET}/etc/skel/.oh-my-zsh" ]] && cp -an "${TARGET}/etc/skel/.oh-my-zsh" "${home}/" 2>/dev/null || true
    # Scrub display/output state from THIS user's home. useradd already seeded the
    # home from skel with cp -an (no-clobber) at account-creation time, so the
    # stale config can survive the skel copy above — strip it directly so the
    # primary monitor is auto-detected for this machine, not inherited.
    strip_display_state "${home}"
    # Default avatar: register the Maze avatar logo with AccountsService so the
    # SDDM login screen and System Settings > Users show it as the account
    # picture (~/.face.icon, copied from skel above, is the fallback).
    if [[ -f "${MAZE_AVATAR_SRC}" ]]; then
        acc_icons="${TARGET}/var/lib/AccountsService/icons"
        acc_users="${TARGET}/var/lib/AccountsService/users"
        mkdir -p "${acc_icons}" "${acc_users}"
        cp -f "${MAZE_AVATAR_SRC}" "${acc_icons}/${user}" 2>/dev/null || warn "avatar copy for ${user} failed"
        cat > "${acc_users}/${user}" <<EOF
[User]
Icon=/var/lib/AccountsService/icons/${user}
SystemAccount=false
EOF
    fi
    # The live panel config hard-codes the live user's home (/home/maze) for the
    # video wallpaper; repoint it at this user's home so the wallpaper resolves.
    user_appletsrc="${home}/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "${user_appletsrc}" && "${user}" != "maze" ]]; then
        sed -i "s#/home/maze/#/home/${user}/#g" "${user_appletsrc}" 2>/dev/null || true
    fi
    # Drop the installer (maze-install / maze-calamares) launcher from THIS user's
    # dock too. useradd seeded the home from skel BEFORE skel was stripped, and the
    # cp -an above is no-clobber, so the installer pin survives here and must be
    # removed explicitly — otherwise the installed system keeps an installer icon.
    strip_installer_launcher "${user_appletsrc}"
    # Make sure this user's default browser is Firefox (the home was seeded from
    # skel before skel was patched, and the cp -an above is no-clobber).
    set_default_browser "${home}/.config/mimeapps.list"
    set_kde_browser     "${home}/.config/kdeglobals"
    chown -R "${owner_uid}:${owner_gid}" "${home}" 2>/dev/null || true
    # Private home: 700 (not world-readable). A desktop home holds keys, tokens
    # and history; a 755 home leaks all of it to every local account. (lynis
    # HOME-9304.)
    chmod 700 "${home}" 2>/dev/null || true
    # ~/.ssh explicitly: sshd/ssh silently refuse to read/write known_hosts,
    # authorized_keys or private keys the moment the directory or its files are
    # group/other-writable, or owned by anyone but the user (ssh does not warn
    # about known_hosts the way it does about private keys — it just silently
    # skips writing, which looks like "known_hosts never gets created"). The
    # broad chown -R/chmod 700 above already covers ownership, but assert the
    # exact modes explicitly here too — this is what actually broke on a real
    # machine after root-context maintenance (a chroot repair session) left
    # root-owned entries under ~/.ssh. Guarded: most fresh installs have no
    # ~/.ssh yet (not seeded by skel), so this is normally a no-op.
    if [[ -d "${home}/.ssh" ]]; then
        chmod 700 "${home}/.ssh" 2>/dev/null || true
        find "${home}/.ssh" -mindepth 1 -type d -exec chmod 700 {} \; 2>/dev/null || true
        find "${home}/.ssh" -mindepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true
    fi
    # Match the live medium: zsh as the login shell. usermod edits /etc/passwd
    # directly (no PAM), so it can never prompt/hang the way chsh can.
    in_chroot usermod -s /usr/bin/zsh "${user}" >/dev/null 2>&1 || true
done

# 3a-bis) Lock the root account -----------------------------------------------
#
# The live ISO ships root with an EMPTY password (`root::` in airootfs/etc/shadow)
# so the live environment is usable, and Calamares is configured with
# `setRootPassword: false`, so it never touches root on the target. unpackfs
# copies /etc/shadow wholesale — which means, left alone, the installed system
# keeps a root account that anyone at a TTY can log into by typing "root" and
# pressing Enter. Nothing else in this script touched it.
#
# Locking is the right end state, not setting a password: Maze gives the first
# user wheel/sudo, so root is never logged into directly. `passwd -l` prefixes
# the hash with "!" — combined with an empty hash that leaves "!", which is a
# valid "no login" marker.
#
# The recovery half of this is in maze-secureboot: sulogin refuses an account
# with no usable password, so without a drop-in a locked root would also mean an
# unreachable emergency shell. That package ships SULOGIN_FORCE=1 for
# emergency.service and rescue.service, and the reasoning for why that is safe
# on a sealed-cmdline system is written out there.
log "Locking the root account (login is via the wheel user + sudo)"
if in_chroot passwd -l root >/dev/null 2>&1; then
    _root_state="$(in_chroot passwd -S root 2>/dev/null | awk '{print $2}' || true)"
    case "${_root_state}" in
        L|LK) log "root is locked" ;;
        *)    log "root password status: ${_root_state:-unknown}" ;;
    esac
else
    warn "passwd -l root failed; falling back to editing shadow directly"
fi

# `passwd -l` prefixes the existing hash with "!", and shadow-utils versions
# differ in how they treat an EMPTY field — the exact case that arrives from the
# live medium. The outcome here decides whether a stranger at a TTY is root, so
# it is verified rather than assumed, and repaired directly if the tool did not
# do it.
_root_field="$(in_chroot awk -F: '$1=="root" {print $2}' /etc/shadow 2>/dev/null || true)"
case "${_root_field}" in
    ""|":")
        warn "root still has an EMPTY password — locking it directly"
        if in_chroot sed -i 's/^root::/root:!:/' /etc/shadow 2>/dev/null \
           && [[ "$(in_chroot awk -F: '$1=="root" {print $2}' /etc/shadow 2>/dev/null)" == "!" ]]; then
            log "root locked"
        else
            warn "COULD NOT LOCK ROOT. The installed system allows passwordless"
            warn "root login at a TTY. Fix after first boot with: sudo passwd -l root"
        fi
        ;;
    *)
        log "root password field is set (locked or hashed)"
        ;;
esac

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
    # When the panel itself hangs off NVIDIA (no iGPU) there is no cheap option:
    # `kms` stays so the splash still comes up on the real GPU, firmware included.
    _boot_gpu_drv=""
    for _pd in /sys/bus/pci/devices/*; do
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

# Rebuild the initramfs with the FINAL HOOKS (encrypt + plymouth + nvidia). This
# is the image the installed system actually boots, so a SILENT failure here is
# precisely what leaves an encrypted root with no passphrase prompt (splash logo
# shows, boot hangs). Keep the build log, and for a LUKS root HARD-verify that the
# `encrypt` hook really made it into the produced image — never trust the build
# silently again.
if ! _mki_log="$(in_chroot mkinitcpio -P 2>&1)"; then
    warn "mkinitcpio rebuild failed:"
    printf '%s\n' "${_mki_log}" >&2
fi

# Re-run kernel-install so the UKI on the ESP is refreshed with the
# newly-built initramfs. `mkinitcpio -P` only produces the initramfs images; it
# does NOT copy them to the ESP (that is kernel-install's job — and with
# layout=uki it rebuilds the UKI itself from kernel+initramfs+cmdline). Without
# this, the ESP still carries the UKI from Calamares' bootloader step, which
# may be stale. kernel-install also triggers the 95-maze-sb-sign plugin
# (if setup_secure_boot already ran) — but at this point setup_secure_boot has
# NOT run yet, so the UKI lands on the ESP unsigned. setup_secure_boot below
# signs it; the final re-sign at the end is the safety net.
#
# UEFI only: a BIOS/GRUB install has no ESP and boots the loose
# /boot/vmlinuz-linux + initramfs (mkinitcpio -P above already produced them,
# and grub-mkconfig below picks them up), so kernel-install/UKI is skipped.
if is_uefi; then
    for _krel in $(in_chroot sh -c 'ls /usr/lib/modules/ 2>/dev/null | grep -v build' 2>/dev/null || true); do
        [[ -n "${_krel}" ]] || continue
        in_chroot kernel-install add "${_krel}" "/usr/lib/modules/${_krel}/vmlinuz" \
            >/dev/null 2>&1 || warn "kernel-install add failed for ${_krel} (UKI on ESP may be stale)"
    done
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
        warn "LUKS: 'encrypt' hook MISSING from HOOKS — root will not unlock / no password box. HOOKS=$(grep -E '^HOOKS=' "${mkconf}" 2>/dev/null)"
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

# 5c) Locale: make date/number formats follow the LANGUAGE -----------------
# Calamares can set the FORMAT locales (LC_TIME, LC_NUMERIC, ...) to the install
# LOCATION's country (e.g. Turkey -> tr_TR) even when the chosen language is
# English — so the clock/date show up in Turkish on an "English" system. Align
# everything to LANG: drop the LC_* overrides so the whole locale follows the
# language (the same clean setup a stock English machine has). Timezone is
# separate (/etc/localtime) and is left as the user chose it.
lconf="${TARGET}/etc/locale.conf"
if [[ -f "${lconf}" ]] && grep -q '^LANG=' "${lconf}"; then
    _lang="$(sed -n 's/^LANG=//p' "${lconf}" | tr -d '"' | head -1)"
    log "Aligning format locales to the language (${_lang})"
    sed -i '/^LC_/d' "${lconf}"
fi

# 5d) /etc/hosts: map the hostname so name resolution is clean (and lynis
# NAME-4404 stops warning). Add the loopback hostname line if missing.
_hn="$(cat "${TARGET}/etc/hostname" 2>/dev/null | head -1)"
if [[ -n "${_hn}" ]]; then
    [[ -f "${TARGET}/etc/hosts" ]] || printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n' > "${TARGET}/etc/hosts"
    grep -qE "[[:space:]]${_hn}([[:space:]]|\$)" "${TARGET}/etc/hosts" 2>/dev/null \
        || printf '127.0.1.1\t%s.localdomain %s\n' "${_hn}" "${_hn}" >> "${TARGET}/etc/hosts"
fi

# 5c) Encrypted root: enable TRIM/discard pass-through on the LUKS layer.
# Without this, fstrim / fstrim.timer cannot reach the SSD — dm-crypt silently
# drops discard requests — so on DRAM-less QLC drives the FTL free-block pool is
# never reclaimed and large writes collapse into multi-second I/O stalls / full
# freezes that only clear on reboot. Persisting the flag into the LUKS2 header
# makes every unlock (initramfs `encrypt` hook, crypttab, manual) honour it,
# independent of bootloader or kernel cmdline. Runs live (dontChroot) against the
# already-open target mapper; refresh re-uses the in-kernel key (no passphrase).
_root_src="$(findmnt -no SOURCE "${TARGET}" 2>/dev/null | sed 's/\[.*\]//')"
if [[ "${_root_src}" == /dev/mapper/* ]]; then
    _luks_name="${_root_src##*/}"
    if cryptsetup status "${_luks_name}" >/dev/null 2>&1; then
        if cryptsetup --allow-discards --persistent refresh "${_luks_name}" >/dev/null 2>&1; then
            log "LUKS: persisted allow-discards on ${_luks_name} (TRIM pass-through enabled)"
        else
            # Expected, and not a bug: per cryptsetup-refresh(8) the "mandatory
            # parameters are identical to those of an open action", i.e. refresh
            # wants the passphrase, which the installer deliberately does not
            # keep (and --persistent is LUKS2-only). TRIM is already handled by
            # the allow-discards flag written onto the kernel cmdline earlier, so
            # this is only the belt-and-braces header flag — report accordingly
            # instead of raising an alarm about something that is working.
            if [[ "${MAZE_LUKS_DISCARD_CMDLINE:-0}" -eq 1 ]]; then
                log "LUKS: header flag not persisted on ${_luks_name} (needs the passphrase) — not a problem, TRIM comes from the cmdline allow-discards."
                log "      To also store it in the LUKS2 header, run once on the installed system:"
                log "          sudo cryptsetup --allow-discards --persistent refresh ${_luks_name}"
            else
                warn "LUKS: TRIM pass-through is NOT enabled on ${_luks_name} — the cmdline route did not apply either."
                warn "      Run this once on the installed system:"
                warn "          sudo cryptsetup --allow-discards --persistent refresh ${_luks_name}"
                warn "      Verify with: sudo cryptsetup luksDump <device> | grep -i flags"
            fi
        fi
    fi
fi

# 6) Enable services on the target -----------------------------------------
# Non-security services are always enabled. Security services are enabled only
# if the user kept them in the installer's Security section (empty = all).
# zram-generator drives the compressed RAM swap configured above; install it on
# the target if we can reach the network (best-effort, skipped offline).
# zram-generator is listed in packages.x86_64, so unpackfs has already put it on
# the target — check before reaching for the network. The old unconditional
# `pacman -S` ran BEFORE the target keyring is initialised (step 8b, further
# down), so it failed on a perfectly fine install and warned "offline?", which
# is exactly the wrong thing to send someone chasing. Only warn when the package
# is genuinely absent.
if ! in_chroot pacman -Qq zram-generator >/dev/null 2>&1; then
    in_chroot pacman -S --needed --noconfirm zram-generator >/dev/null 2>&1 \
        || warn "zram-generator is not installed and could not be fetched; /etc/systemd/zram-generator.conf is in place for later"
fi

# Virtualization is NOT set up at install time — by design, and no longer even
# attempted here. The stack was ~2 GB (qemu-full alone) so it never went on the
# live ISO, and installing it from the target chroot needs a working network in
# the middle of an otherwise offline install. Maze ships `maze-install-vmware`
# (maze-tools) instead: the user runs it once, post-install, and paru builds
# VMware Workstation + open-vm-tools and enables its services. Anyone who wants
# the KVM stack instead is one command away:
#     sudo pacman -S qemu-desktop libvirt virt-manager edk2-ovmf
#
# The old block here was gated on the Extras packagechooser selection, but that
# page was removed and EXTRAS_CSV is hardcoded to "none" at the top of this
# script — so the gate could never open and the code (plus the matching
# `systemctl enable libvirtd`) was dead on every single install. Removed rather
# than left to look like a feature that runs.

# VMware is no longer installed here — the user runs `maze-install-vmware`
# (maze-tools) on demand, which pulls vmware-workstation + open-vm-tools via paru.

log "Enabling base Maze services"
for svc in ollama acpid power-profiles-daemon smartd fstrim.timer bluetooth cups \
           tor systemd-oomd fwupd-refresh.timer reflector.timer maze-flatpak-setup.service \
           maze-guardd.service maze-sentinel-setup.service maze-sentinel.service; do
    in_chroot systemctl enable "${svc}" >/dev/null 2>&1 || true
done

# Disable LIVE-only services that unpackfs carried over but must NOT run on an
# installed desktop. sshd is the important one: the live ISO enables it for
# remote installs, so without this every installed Maze boots with an SSH server
# listening — an attack surface a privacy desktop should not expose by default.
# (The Maze sshd hardening drop-in stays in place, so if the user enables sshd
# later it is already hardened.) The VM guest agents are harmless on real
# hardware but pointless to keep enabled.
#
# cloud-init belongs in this list, not the boot-speed one below: on bare metal
# its own generator (cloud-init-generator) checks ds-identify and never even
# pulls in cloud-init.target, so it costs one shell script per boot and nothing
# else — but on a VM (VMware OVF, a NoCloud seed) ds-identify CAN find a
# datasource, and cloud-init is designed to rewrite the hostname, network config
# and user accounts of whatever it boots into. That is exactly the kind of
# live-medium behaviour that must not reach an installed desktop.
log "Disabling live-only services on the target (sshd, VM guest agents, cloud-init)"
# choose-mirror + livecd-talk are condition-gated (kernel cmdline) so they never
# actually run on the target, but disable them anyway so `systemctl` output on
# the installed system carries no live-medium leftovers.
for svc in sshd vboxservice \
           hv_kvp_daemon hv_vss_daemon hv_fcopy_daemon \
           vmtoolsd vmware-vmblock-fuse \
           choose-mirror livecd-talk \
           cloud-init-local cloud-init-network cloud-init-main cloud-config cloud-final; do
    in_chroot systemctl disable "${svc}" >/dev/null 2>&1 || true
done

# Disable services the archiso LIVE medium enables but that only slow an
# INSTALLED desktop boot (they sat on the boot critical-chain for ~35s combined):
#   - pacman-init.service: live-medium pacman keyring init; pointless every boot
#     on an installed system where the keyring is already populated.
#   - systemd-time-wait-sync.service: blocks boot until NTP sync completes.
#     timesyncd still corrects the clock in the background without gating
#     graphical.target, so the desktop comes up ~30s sooner.
#   - livecd-alsa-unmuter.service: live-only ALSA unmuter; alsa-restore handles
#     audio state on an installed system, and it drags in the deprecated
#     systemd-udev-settle (~3s) as a dependency.
#   - NetworkManager-wait-online.service: gates network-online.target until full
#     connectivity, which is on the boot critical-chain (ollama.service pulls in
#     network-online.target) and cost ~7s here. NetworkManager still brings the
#     link up in the background; nothing on the desktop path needs to BLOCK on it.
log "Disabling live-only / boot-blocking services for a faster installed boot"
for svc in pacman-init.service systemd-time-wait-sync.service \
           livecd-alsa-unmuter.service NetworkManager-wait-online.service; do
    in_chroot systemctl disable "${svc}" >/dev/null 2>&1 || true
done

# Resolve the selected security features (empty selection => all of them).
sec_selected() {
    local key="$1"
    # Empty OR the literal "all" both mean "every security feature is on".
    # Calamares invokes this script with the security CSV as "all" for the
    # default install. Without the "all" case, sec_selected would treat "all" as
    # a feature name matching nothing, so EVERY real feature (apparmor, firewalld,
    # fail2ban, opensnitch, macchanger, …) would read as unselected — silently
    # not enabling them, wrongly stripping MAC randomization, and deleting the
    # opensnitch tray autostart (the visible symptom).
    [[ -z "${SECURITY_CSV}" || "${SECURITY_CSV}" == "all" ]] && return 0
    case ",${SECURITY_CSV}," in
        *",${key},"*) return 0 ;;
        *) return 1 ;;
    esac
}

log "Applying Security selection: ${SECURITY_CSV:-<all>}"
sec_selected apparmor   && in_chroot systemctl enable apparmor          >/dev/null 2>&1 || true
sec_selected firewalld  && in_chroot systemctl enable firewalld         >/dev/null 2>&1 || true
sec_selected fail2ban   && in_chroot systemctl enable fail2ban          >/dev/null 2>&1 || true
sec_selected auditd     && in_chroot systemctl enable auditd            >/dev/null 2>&1 || true
sec_selected clamav     && in_chroot systemctl enable clamav-freshclam  >/dev/null 2>&1 || true
# MAC randomization is owned exclusively by maze-guard now (its privileged helper
# manages the interface's MAC). There is no NetworkManager drop-in or mac-changer
# service to toggle here anymore — those were removed because a second randomiser
# fought maze-guard and made its MAC feature fail. maze-guard honours the user's
# choice inside its own UI, so the installer's "macchanger" security toggle no
# longer does anything at deploy time.

# OpenSnitch: daemon always enabled but starts in allow-all (passive) mode.
# GUI autostarts so user sees it in the tray; they can activate interception manually.
if sec_selected opensnitch; then
    copy_to_target /etc/opensnitchd/default-config.json
    in_chroot systemctl enable opensnitchd >/dev/null 2>&1 || true
else
    rm -f "${TARGET}/etc/skel/.config/autostart/opensnitch_ui.desktop" 2>/dev/null || true
    for home in "${TARGET}"/home/*; do
        [[ -d "${home}" ]] && rm -f "${home}/.config/autostart/opensnitch_ui.desktop" 2>/dev/null || true
    done
fi

if sec_selected firewalld; then
    in_chroot firewall-offline-cmd --add-service=ssh          >/dev/null 2>&1 || true
    in_chroot firewall-offline-cmd --add-service=kdeconnect   >/dev/null 2>&1 || true
    # maze-connect (TCP+UDP 38271) — BACKSTOP only. Owning this rule is the
    # maze-connect package's job and its scriptlet does it properly now; this line
    # exists because the failure mode is silent (the app runs, shows its address,
    # and simply never links) and the rule has to survive a long chain to get here:
    # scriptlet in the ISO's pacstrap chroot -> zone file in the airootfs ->
    # unpackfs copy. Re-adding it is idempotent and costs nothing. Referenced by
    # SERVICE NAME, so a port change in maze-connect's XML needs no edit here.
    in_chroot firewall-offline-cmd --add-service=maze-connect >/dev/null 2>&1 || true
fi

# 7) pacman tuning on the installed system (match the live medium) ---------
log "Tuning pacman on the target"
tconf="${TARGET}/etc/pacman.conf"
if [[ -f "${tconf}" ]]; then
    if grep -qE '^\s*#?\s*ParallelDownloads' "${tconf}"; then
        sed -i -E 's/^\s*#?\s*ParallelDownloads\s*=.*/ParallelDownloads = 15/' "${tconf}"
    else
        sed -i '/^\[options\]/a ParallelDownloads = 15' "${tconf}"
    fi
    sed -i -E 's/^\s*#\s*Color\s*$/Color/' "${tconf}"
    grep -qE '^\s*Color\s*$' "${tconf}" || sed -i '/^\[options\]/a Color' "${tconf}"
    grep -qE '^\s*VerbosePkgLists\s*$' "${tconf}" || sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "${tconf}"
    grep -qE '^\s*ILoveCandy\s*$' "${tconf}" || sed -i '/^Color$/a ILoveCandy' "${tconf}"
fi

# 7b) Maze Linux package repository on the target --------------------------
# Ship the official Maze repo so installed systems pull Maze packages and
# updates. Listed before the official repos so Maze's curated builds win.
# Packages signed with the Maze signing key (mazelinux-keyring).
# Idempotent: skip if the section was already inherited from the live medium's
# pacman.conf.
tconf="${TARGET}/etc/pacman.conf"
if [[ -f "${tconf}" ]] && ! grep -q '^\[mazelinux\]' "${tconf}"; then
    log "Adding Maze Linux repository to target pacman.conf"
    if grep -q '^\[core\]' "${tconf}"; then
        sed -i '/^\[core\]/i [mazelinux]\nSigLevel = Required DatabaseOptional\nServer = https://mazerepo.berkkucukk.com.tr/packages\n' "${tconf}"
    else
        printf '\n[mazelinux]\nSigLevel = Required DatabaseOptional\nServer = https://mazerepo.berkkucukk.com.tr/packages\n' >> "${tconf}"
    fi
fi

# 7c) Strip the build-only [maze-aur] localrepo inherited from the live medium
# The live ISO's pacman.conf carries a [maze-aur] repo whose Server is a file://
# path on the BUILD host (…/MazeLinux/localrepo). On the installed target that
# path does not exist, so the entry is dead weight — but worse, it keeps shadowing
# the curated third-party AUR apps (upscayl-bin, joplin-bin,
# session-desktop-bin, claude-code, paru, …): while those names still resolve to a
# sync repo, pacman treats them as native packages and `paru -Syu` — which only
# reconciles *foreign* (`pacman -Qm`) packages against the AUR — never offers their
# updates. Dropping the section makes them foreign again so paru keeps them current
# from the AUR. (Maze's OWN apps stay in [mazelinux] and update from the Maze repo.)
tconf="${TARGET}/etc/pacman.conf"
if [[ -f "${tconf}" ]] && grep -q '^\[maze-aur\]' "${tconf}"; then
    log "Removing build-only [maze-aur] localrepo from target pacman.conf"
    # Bounded to the section: everything from [maze-aur] up to (not including)
    # the next [section] header. The old `/^\[maze-aur\]/,/^Server/d` range
    # relied on a `Server` line existing inside it — with no match it would have
    # deleted to END OF FILE, taking [core]/[extra]/[multilib] with it.
    awk '/^\[maze-aur\]/{skip=1; next} /^\[/{skip=0} !skip' "${tconf}" \
        > "${tconf}.maze.tmp" 2>/dev/null \
        && mv -f "${tconf}.maze.tmp" "${tconf}" \
        || { rm -f "${tconf}.maze.tmp" 2>/dev/null; warn "could not strip [maze-aur] from target pacman.conf"; }
fi

# 8) Strip any STRAY BlackArch config inherited from the live medium ---------
# A half-configured [blackarch] (repo enabled but keyring untrusted) poisons
# EVERY pacman operation — "database 'blackarch' is not valid (PGP signature)"
# — which then fails all AUR installs. The base Maze system does NOT ship
# BlackArch, so scrub any stray [blackarch] section here for a clean slate.
#
# NOTE: This does NOT conflict with the OPTIONAL BlackArch install. When the user
# picks "Maze Linux + BlackArch" on the installer, Calamares runs strap.sh via
# the contextualprocess@blackarch-enable module AFTER this whole script finishes, so the
# repo is (re-)added cleanly on top of the finalised keyring — never left in the
# half-configured state this cleanup guards against.
tconf="${TARGET}/etc/pacman.conf"
if [[ -f "${tconf}" ]] && grep -q '^\[blackarch\]' "${tconf}"; then
    log "Removing stray BlackArch repo from target pacman.conf"
    # Bounded the same way as [maze-aur] above — the old range ended on
    # /^Include.*blackarch/, so a section written with `Server =` instead would
    # have deleted the rest of pacman.conf.
    awk '/^\[blackarch\]/{skip=1; next} /^\[/{skip=0} !skip' "${tconf}" \
        > "${tconf}.maze.tmp" 2>/dev/null \
        && mv -f "${tconf}.maze.tmp" "${tconf}" \
        || { rm -f "${tconf}.maze.tmp" 2>/dev/null; warn "could not strip [blackarch] from target pacman.conf"; }
fi
rm -f "${TARGET}/etc/pacman.d/blackarch-mirrorlist" 2>/dev/null || true

# 8b) Initialise the pacman keyring on the TARGET. Without this the installed
# system ships an empty keyring, so EVERY later `pacman -S` of a signed core/extra
# package fails with "required key missing from keyring" / "keyring is not
# writable". The archiso LIVE medium hides this because pacman-init.service runs
# --init/--populate on every live boot — but that's a live-only service (disabled
# on the installed system), so the keyring must be set up ONCE here, persistently.
# Runs before the app/AUR installs below, which pull signed core/extra deps.
log "Initialising pacman keyring on the target"
in_chroot pacman-key --init >/dev/null 2>&1 || warn "pacman-key --init failed"
in_chroot pacman-key --populate >/dev/null 2>&1 || warn "pacman-key --populate failed"

# 9) Refresh the icon cache so the branded "About this System" logo resolves.
in_chroot gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true

# 10) Install Maze's own applications from the [mazelinux] repo (fast, reliable).
install_maze_repo_apps

# THE REAL GAP, and it is not about groups at all.
#
# unpackfs copies the live filesystem onto the target — including
# /var/lib/pacman — so every Maze app arrives already "installed" as far as the
# target's package database is concerned. install_maze_repo_apps then runs
# `pacman -S --needed`, which correctly skips them all, and NOT ONE of their
# .install scriptlets ever executes against this machine.
#
# Most of what those scriptlets do survives the copy (files, venvs, units), but
# two things cannot: the users/groups declared in sysusers.d, and the ownership
# and modes declared in tmpfiles.d. maze-cloak is the clearest casualty — it
# declares `g maze -` and `d /etc/maze-cloak 0775 root maze`, so on a fresh
# install the group may not exist and its config directory is root:root, and the
# app fails with permission errors until the user reinstalls it by hand.
#
# systemd applies both at boot, but the group fixup below runs NOW and needs the
# groups to already exist, so apply them here first. Both tools are declarative
# and idempotent — running them early costs nothing and changes nothing that is
# already correct.
in_chroot systemd-sysusers >/dev/null 2>&1 \
    || warn "systemd-sysusers failed on the target; app groups may be missing"
in_chroot systemd-tmpfiles --create >/dev/null 2>&1 \
    || warn "systemd-tmpfiles --create failed on the target; app config dirs may have wrong ownership"

# Now the group memberships. The app scriptlets try to add "the installing user"
# via $SUDO_USER/logname, which cannot work from a non-interactive arch-chroot:
# there is no sudo session and no tty to detect a desktop user from. Do it here,
# where the real accounts exist.
#
# Derived from what the packages actually declare rather than a hardcoded pair,
# so a new Maze app that ships a sysusers.d group is covered the day it lands.
_maze_groups="$(in_chroot sh -c '
    for f in /usr/lib/sysusers.d/*.conf; do
        case "$f" in
            */maze*|*/entropy*|*/qlam*|*/haze*|*/sentin*) ;;
            *) continue ;;
        esac
        [ -r "$f" ] || continue
        awk "/^g /{print \$2}" "$f"
    done' 2>/dev/null | sort -u)"
[[ -n "${_maze_groups}" ]] || _maze_groups="entropy-shield maze"
log "Maze app groups: $(echo ${_maze_groups} | tr '\n' ' ')"

for _h in "${TARGET}"/home/*; do
    [[ -d "${_h}" ]] || continue
    _u="$(basename "${_h}")"
    in_chroot id "${_u}" >/dev/null 2>&1 || continue
    for _g in ${_maze_groups}; do
        in_chroot getent group "${_g}" >/dev/null 2>&1 \
            && in_chroot usermod -aG "${_g}" "${_u}" >/dev/null 2>&1 || true
    done
done

# 11) FINALLY, install the third-party AUR packages (slowest/most fragile step —
#     done last so everything above is guaranteed to be applied even if this
#     struggles).
install_aur_packages

# SECURITY: belt-and-braces removal of the build-time NOPASSWD sudoers. The
# function deletes it itself and clears its EXIT trap; this line is what covers
# the case where the function returned early or its cleanup did not run.
rm -f "${TARGET}/etc/sudoers.d/99-maze-build" 2>/dev/null || true
if [[ -e "${TARGET}/etc/sudoers.d/99-maze-build" ]]; then
    warn "SECURITY: could not remove ${TARGET}/etc/sudoers.d/99-maze-build — delete it by hand before first boot"
fi

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
        for _krel in $(in_chroot sh -c 'ls /usr/lib/modules/ 2>/dev/null | grep -v build' 2>/dev/null || true); do
            [[ -n "${_krel}" ]] || continue
            in_chroot kernel-install add "${_krel}" "/usr/lib/modules/${_krel}/vmlinuz" \
                >/dev/null 2>&1 || warn "Secure Boot: final kernel-install add failed for ${_krel} (UKI may be stale)"
        done
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

# 13) FINAL pacman keyring init. The earlier init (step 8b) runs on top of the
# /etc/pacman.d/gnupg that unpackfs copied from the LIVE medium, so re-running
# --init there does NOT regenerate the local master key and the installed system
# can boot with a keyring that rejects every signed package ("required key
# missing from keyring") until the user runs pacman-key by hand. Do it once more
# here, AFTER all package work, from a clean state so the booted system is ready:
# wipe the stale keyring, regenerate the master key, then import + locally sign
# the Arch keyring.
#
# 13a) First, purge the archiso live-only keyring units from the target. On the
# live medium etc-pacman.d-gnupg.mount puts a tmpfs OVER /etc/pacman.d/gnupg and
# pacman-init.service re-populates it on every boot. If either survives onto the
# installed system, the empty tmpfs shadows the real on-disk keyring at every
# boot and pacman breaks no matter how well the keyring below is initialised.
# Step 11's `systemctl disable` only removes the wants symlink — delete the unit
# FILES too so the tmpfs shadowing is impossible.
log "Removing archiso live-only keyring units from the target"
rm -f "${TARGET}/etc/systemd/system/etc-pacman.d-gnupg.mount" \
      "${TARGET}/etc/systemd/system/pacman-init.service" \
      "${TARGET}"/etc/systemd/system/*.wants/pacman-init.service 2>/dev/null || true

# 13b) Clean init + populate ALL shipped keyrings (archlinux, and any others in
# /usr/share/pacman/keyrings).
log "Finalising pacman keyring on the target (clean init + populate)"
rm -rf "${TARGET}/etc/pacman.d/gnupg" 2>/dev/null || true
in_chroot pacman-key --init       || warn "pacman-key --init (final) failed"
in_chroot pacman-key --populate   || warn "pacman-key --populate (final) failed"

# 13c) VERIFY the result and arm the boot-time backstop. A populated keyring's
# pubring.gpg carries the whole Arch keyring (~1 MB+); an initialised-but-empty
# one only holds the local master key (~2 KB). If verification fails, wipe the
# half-made keyring so maze-pacman-keyring.service (condition-gated on a missing
# pubring.gpg) rebuilds it from scratch on the first boot — that service runs in
# the REAL booted system (no chroot quirks), so pacman can never stay broken.
_kr="${TARGET}/etc/pacman.d/gnupg/pubring.gpg"
if [[ -f "${_kr}" && "$(stat -c %s "${_kr}" 2>/dev/null || echo 0)" -gt 10240 ]]; then
    log "pacman keyring VERIFIED on the target (populated pubring.gpg present)"
else
    warn "pacman keyring NOT verified — wiping it so maze-pacman-keyring.service re-initialises it on first boot"
    rm -rf "${TARGET}/etc/pacman.d/gnupg" 2>/dev/null || true
fi
in_chroot systemctl enable maze-pacman-keyring.service >/dev/null 2>&1 \
    || warn "could not enable maze-pacman-keyring.service"

log "Maze deployment finished"
exit 0
