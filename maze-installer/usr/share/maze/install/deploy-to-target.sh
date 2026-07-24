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
CURATED_AUR_TEMPLATE=(paru brave-origin-bin upscayl-bin session-desktop-bin joplin-bin onlyoffice-bin claude-code)
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
for _always in paru onlyoffice-bin; do
    if ! printf '%s\n' "${CURATED_AUR[@]}" | grep -qx "${_always}"; then
        CURATED_AUR=("${_always}" "${CURATED_AUR[@]}")
    fi
done
# Maze's OWN applications, shipped from the [mazelinux] repo. Calamares (the
# only caller of this script) always passes the keyword "all", installing the
# whole set below.
DEFAULT_MAZE_APPS=(entropy-shield qlam maze-guard hazedrop haze linux-chan-ai sentinai)

log()  { printf '[maze-deploy] %s\n' "$*"; }
warn() { printf '[maze-deploy] WARNING: %s\n' "$*" >&2; }

# stdin from /dev/null so a chroot command (e.g. chsh's PAM prompt) can never
# block the whole install waiting on input that will never arrive.
in_chroot() { arch-chroot "${TARGET}" "$@" </dev/null; }

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
    cp -a "${src}" "${dst}" 2>/dev/null || warn "could not copy ${src}"
}

# Remove machine-specific DISPLAY / OUTPUT state from a config tree so a freshly
# installed machine NEVER inherits the build host's monitor layout or primary-
# screen choice. KDE/KWin must re-detect outputs (and pick the primary) per
# hardware on first login. Without this, the skel (which was captured from a
# multi-monitor build host) drags that host's screen state onto every install,
# which is why the wrong monitor showed up as "Primary".
#   $1 = home-like dir (its .config / .local live underneath)
strip_display_state() {
    local h="$1"
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

# DNS inside the chroot, set up ONCE up front so every later in_chroot step that
# needs the network works — the AUR builds (step 11) git clone from the AUR.
cp -L /etc/resolv.conf "${TARGET}/etc/resolv.conf" 2>/dev/null || true

# 1) Applications come from two sources, both handled near the end of this
#    script. Maze's OWN apps (entropy-shield, qlam, maze, ...) install from the
#    official [mazelinux] pacman repo with 'pacman -S' (see install_maze_repo_apps).
#    The third-party apps (brave, joplin, paru, ...) are built with makepkg and
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
# Breeze greeter override (the default SDDM theme) — puts the Maze wallpaper
# behind Breeze. Breeze itself ships with plasma; this only adds the override.
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
copy_to_target /usr/local/bin/maze-guard
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
# Kernel/network hardening, zram swap and hardened Firefox policy. These live in
# /etc, which (unlike /etc/skel) is not copied wholesale.
copy_to_target /etc/sysctl.d/99-maze-hardening.conf
copy_to_target /etc/systemd/zram-generator.conf
copy_to_target /etc/firefox/policies/policies.json
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
    # DNS for pacman to reach the Maze repo / mirrors (also set up front above).
    cp -L /etc/resolv.conf "${TARGET}/etc/resolv.conf" 2>/dev/null || true
    local _try
    # Refresh databases (retried) so a transient mirror/repo hiccup does not drop
    # the whole set.
    for _try in 1 2 3; do
        in_chroot pacman -Sy --noconfirm && break
        warn "pacman -Sy failed (attempt ${_try}/3); retrying in 5s"
        sleep 5
    done
    # Drop any package that is not actually in a synced repo before installing.
    # pacman -S aborts the ENTIRE transaction on a single "target not found"
    # (e.g. a renamed/absent 'maze' package), which would take the real apps —
    # already present from the ISO — down with it and spam retries. Filter first
    # so one missing name never blocks the rest.
    local _avail=() _p
    for _p in "${pkgs[@]}"; do
        if in_chroot pacman -Si "${_p}" >/dev/null 2>&1; then
            _avail+=("${_p}")
        else
            warn "repo package '${_p}' not found in synced repos — skipping"
        fi
    done
    pkgs=("${_avail[@]}")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log "No installable Maze repo packages remain after filtering; skipping"
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
# splash, wallpaper, Breeze greeter, services — is ALWAYS applied first and can
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

    # DNS inside the chroot so git can reach the AUR and pacman the mirrors.
    cp -L /etc/resolv.conf "${TARGET}/etc/resolv.conf" 2>/dev/null || true
    # Temporary passwordless sudo for the build user (makepkg calls sudo pacman).
    local sudoers="${TARGET}/etc/sudoers.d/99-maze-build"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${build_user}" > "${sudoers}"
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
# gets just short, human-readable status lines ("Installing brave-bin from the
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
    # ship on the live ISO (brave-origin-bin, upscayl-bin, session-desktop-bin,
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
            local pkgfiles=("$tmp/$pkg"/*.pkg.tar.*)
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

    # The build script prints only short status lines ("Installing brave-bin from
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
    in_chroot pacman -S --needed --noconfirm sbsigntools mokutil efitools systemd-ukify >/dev/null 2>&1 || true

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

    # 2) The signer script. kernel-install (layout=uki) already built the real
    #    Unified Kernel Image under $ESP/EFI/Linux/ — this script finds it, signs
    #    it with the per-machine MOK key, and installs it as grubx64.efi — the
    #    second stage shim chainloads by that exact name. The shim ALWAYS
    #    verifies its second stage via its own shim_lock protocol (MOK-backed),
    #    so strict firmware (MSI/ASUS) that ignores MOK for loose kernels and
    #    only checks db no longer rejects the boot. The kernel is embedded
    #    inside the UKI, so no separate firmware LoadImage() of vmlinuz ever
    #    happens.
    install -Dm755 /dev/stdin "${TARGET}/usr/local/bin/maze-sb-sign" <<'SBSIGN'
#!/bin/sh
# Managed by Maze Linux. Signs the kernel-install-built Unified Kernel Image
# (layout=uki) that shim chainloads as grubx64.efi. Idempotent.
# Usage: maze-sb-sign [ESP_MOUNTPOINT] [--force-bootloader]
set -eu

KEYDIR=/var/lib/maze-secureboot
KEY="$KEYDIR/MOK.key"
CRT="$KEYDIR/MOK.crt"
CER="$KEYDIR/MOK.cer"

[ -r "$KEY" ] && [ -r "$CRT" ] || { echo "maze-sb-sign: no MOK key, skipping" >&2; exit 0; }

# Serialize all invocations. This script is triggered from up to three
# independent, overlapping sources for a single kernel update — the
# 85-maze-kernel-install.hook -> kernel-install add -> 95-maze-sb-sign.install
# plugin, the zz-maze-secureboot.hook (same pacman transaction), and the
# maze-sb-resign.path unit reacting to the new UKI file appearing under
# $ESP/EFI/Linux. Without a lock, two concurrent instances can both sign the
# same file to the same fixed temp name (sign_inplace's "$f.maze-signed" /
# the grubx64.efi temp below) and race each other's write, producing a
# truncated/corrupt result on disk. Confirmed in production: overlapping
# maze-sb-resign.service runs 0 seconds apart left a 63%-truncated UKI and a
# kernel panic ("No working init found") on next boot. The lock makes every
# invocation, regardless of trigger, run one at a time.
LOCKFILE=/run/lock/maze-sb-sign.lock
# /run/lock can be absent when /run is a fresh tmpfs (e.g. some chroot setups
# mount their own /run) — without this, exec 9> fails and set -eu aborts the
# whole signing run.
mkdir -p /run/lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "maze-sb-sign: another instance is running, waiting..." >&2
    flock 9
fi

ESP=""
force_bootloader=0
for arg in "$@"; do
    case "$arg" in
        --force-bootloader) force_bootloader=1 ;;
        *) ESP="$arg" ;;
    esac
done

if [ -z "$ESP" ]; then
    ESP="$(bootctl --print-esp-path 2>/dev/null || true)"
    [ -n "${ESP:-}" ] && [ -d "$ESP" ] || ESP=/efi
    [ -d "$ESP" ] || ESP=/boot
fi
if [ ! -d "$ESP" ]; then
    echo "maze-sb-sign: ESP path '$ESP' does not exist" >&2
    exit 1
fi

status_ok=1

install_if_diff() {
    [ -f "$1" ] || return 0
    cmp -s "$1" "$2" 2>/dev/null && return 0
    install -m644 "$1" "$2"
}

sign_inplace() {
    f="$1"
    [ -e "$f" ] || return 0
    if sbverify --cert "$CRT" "$f" >/dev/null 2>&1; then
        echo "maze-sb-sign: OK     $f"
        return 0
    fi
    if sbsign --key "$KEY" --cert "$CRT" --output "$f.maze-signed" "$f" 2>/dev/null; then
        mv -f "$f.maze-signed" "$f"
        echo "maze-sb-sign: SIGNED $f"
    else
        rm -f "$f.maze-signed"
        echo "maze-sb-sign: FAIL   $f" >&2
        status_ok=0
    fi
}

BOOTDIR="$ESP/EFI/BOOT"
mkdir -p "$BOOTDIR"
install_if_diff "$KEYDIR/shimx64.efi" "$BOOTDIR/BOOTX64.EFI"
install_if_diff "$KEYDIR/mmx64.efi"   "$BOOTDIR/mmx64.efi"
install_if_diff "$CER"                "$ESP/MOK.cer"

# --- Sign the UKI and install as grubx64.efi (shim's second stage) ---
# /etc/kernel/install.conf ships `layout=uki`, so `kernel-install add` (run by
# Calamares' bootloader module, and again below by deploy-to-target.sh) already
# built a real UKI (kernel + initramfs + /etc/kernel/cmdline + systemd PE stub,
# via kernel-install's own ukify plugin) at $ESP/EFI/Linux/<machine-id>-<kver>.efi.
# No manual `ukify build` needed here — just sign that file and install it as
# grubx64.efi, the exact name shim chainloads. This makes the boot chain
# portable across ALL UEFI firmware (shim verifies its second stage via
# shim_lock/MOK, never via db).
GRUB="$BOOTDIR/grubx64.efi"
UKI="$(ls -t "$ESP"/EFI/Linux/*.efi 2>/dev/null | head -1)"

if [ -n "$UKI" ]; then
    # Sign to a temp file and rename into place — never write $GRUB directly.
    # sbsign dying partway (disk full, killed mid-transaction) must not leave
    # a truncated/corrupt grubx64.efi with no working fallback, since it is the
    # ONLY thing shim chainloads.
    if sbsign --key "$KEY" --cert "$CRT" --output "$GRUB.maze-signed" "$UKI" 2>/dev/null; then
        mv -f "$GRUB.maze-signed" "$GRUB"
        echo "maze-sb-sign: SIGNED $GRUB (from $UKI)"
    else
        rm -f "$GRUB.maze-signed"
        echo "maze-sb-sign: FAIL signing $UKI as $GRUB" >&2
        status_ok=0
    fi
else
    echo "maze-sb-sign: WARNING — no kernel-install UKI found under $ESP/EFI/Linux" >&2
    # Fallback: sign any existing grubx64.efi in place (best-effort)
    sign_inplace "$GRUB"
fi

# Also sign any loose kernels/UKIs on the ESP as a safety net (in case the
# firmware boots via a different path). These are NOT the primary boot path —
# the UKI as grubx64.efi is — but keeping them signed is harmless.
boot_path="$(bootctl --print-boot-path 2>/dev/null || true)"
dirs="$ESP"
for d in "$boot_path" /boot /efi; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    case " $dirs " in *" $d "*) ;; *) dirs="$dirs $d" ;; esac
done
for d in $dirs; do
    for f in "$d"/EFI/Linux/*.efi "$d"/vmlinuz-* "$d"/*/*/linux; do
        sign_inplace "$f"
    done
done

if [ "$status_ok" = 1 ]; then
    echo "maze-sb-sign: done (ESP=$ESP)"
else
    echo "maze-sb-sign: WARNING - some boot files are NOT validly signed (ESP=$ESP)" >&2
    exit 1
fi
SBSIGN

    # THE MISSING LINK: `/etc/kernel/install.conf` ships `layout=uki`, but that
    # only takes effect when `kernel-install` actually RUNS. On a stock Arch
    # install (and on the "de-archiso'd" preset calamares-mount-api.sh writes,
    # see its `default_image=` preset) an ordinary `linux` package upgrade is
    # handled ENTIRELY by mkinitcpio's own pacman hook
    # (`/usr/share/libalpm/hooks/90-mkinitcpio-install.hook`, shipped by the
    # mkinitcpio package), which reads the preset and calls `mkinitcpio -P`
    # directly — it NEVER calls `kernel-install`. Without this hook,
    # `kernel-install add` is only ever invoked once, manually, by this very
    # script at install time — every kernel update after that leaves the UKI at
    # $ESP/EFI/Linux/ stale (still the OLD kernel version, whose
    # /usr/lib/modules/<ver> pacman has since deleted). The system keeps
    # booting that stale UKI until it fails to find its own modules (e.g.
    # `vfat`/`nvidia_uvm`) at boot. Neither the kernel-install plugin below nor
    # the .path self-heal unit can help — they only react to kernel-install
    # actually being invoked, which is exactly the step missing here.
    install -Dm755 /dev/stdin "${TARGET}/usr/local/bin/maze-kernel-install-add" <<'KIADD'
#!/bin/sh
# Managed by Maze Linux. Invoked by the 85-maze-kernel-install.hook pacman
# hook (NeedsTargets) for every usr/lib/modules/*/vmlinuz install/upgrade.
# Runs `kernel-install add` so layout=uki actually rebuilds the Unified Kernel
# Image on the ESP for the new kernel — mkinitcpio's own preset-driven pacman
# hook only ever produces loose /boot/initramfs-*.img and never calls
# kernel-install itself. Reads NUL-free paths (one per line) from stdin.
set -eu
while IFS= read -r f; do
    case "$f" in
        usr/lib/modules/*/vmlinuz)
            kver="${f#usr/lib/modules/}"
            kver="${kver%/vmlinuz}"
            [ -d "/usr/lib/modules/$kver" ] || continue
            kernel-install add "$kver" "/usr/lib/modules/$kver/vmlinuz" \
                || echo "maze-kernel-install-add: kernel-install add failed for $kver" >&2
            ;;
    esac
done
KIADD

    # Named `85-` so it runs BEFORE both mkinitcpio's own `90-...` hook and the
    # `zz-...` re-sign hook below: kernel-install add here (and the
    # 95-maze-sb-sign.install plugin it triggers, further down) must build and
    # sign the fresh UKI before zz-maze-secureboot.hook does its idempotent
    # re-check/re-sign pass.
    install -Dm644 /dev/stdin "${TARGET}/etc/pacman.d/hooks/85-maze-kernel-install.hook" <<'KIHOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Building Unified Kernel Image via kernel-install (Maze)...
When = PostTransaction
Exec = /usr/local/bin/maze-kernel-install-add
NeedsTargets
KIHOOK

    # BELT-AND-SUSPENDERS layer: re-signs the systemd-boot/shim BINARY (and is a
    # fallback kernel re-sign) after anything that touches the bootloader/kernel,
    # in case the 85- hook above or the kernel-install plugin below did not run
    # (e.g. `kernel-install` missing at the time, or `reinstall-kernels` run
    # manually outside any pacman transaction — the .path self-heal unit further
    # down covers that case too).
    #
    # Named `zz-` so it is the last PostTransaction hook (after mkinitcpio/systemd).
    # Remove any earlier-named copy so an in-place upgrade does not run both.
    rm -f "${TARGET}/etc/pacman.d/hooks/95-maze-secureboot.hook" 2>/dev/null || true
    install -Dm644 /dev/stdin "${TARGET}/etc/pacman.d/hooks/zz-maze-secureboot.hook" <<'SBHOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz
Target = usr/lib/systemd/boot/efi/*
Target = boot/vmlinuz-*
Target = boot/initramfs-*.img

[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = nvidia
Target = nvidia-dkms
Target = nvidia-open
Target = nvidia-open-dkms
Target = nvidia-lts
Target = nvidia-utils
Target = dkms
Target = mkinitcpio
Target = systemd

[Action]
Description = Signing bootloader and kernels for Secure Boot (Maze)...
When = PostTransaction
Exec = /usr/local/bin/maze-sb-sign --force-bootloader
SBHOOK

    # kernel-install plugin — rebuilds + re-signs the UKI (grubx64.efi) inline
    # during kernel-install. Since the installed system boots via shim → UKI (not
    # shim → systemd-boot → BLS kernel), every kernel update must rebuild the UKI.
    # This fires for EVERY kernel write — pacman, manual reinstall-kernels, a
    # systemd/kernel-install upgrade — so the UKI on the ESP is always current and
    # signed. (`add` only; `remove` has nothing to do.)
    install -Dm755 /dev/stdin "${TARGET}/etc/kernel/install.d/95-maze-sb-sign.install" <<'KISIGN'
#!/bin/sh
# Managed by Maze Linux. Rebuilds + signs the UKI (grubx64.efi) after every
# kernel-install add, so the shim chain stays current and signed.
set -eu
[ "${1:-}" = "add" ] || exit 0

KEYDIR=/var/lib/maze-secureboot
[ -r "$KEYDIR/MOK.key" ] && [ -r "$KEYDIR/MOK.crt" ] || exit 0
command -v ukify >/dev/null 2>&1 || exit 0
command -v sbsign >/dev/null 2>&1 || exit 0

# Delegate to the full signer script — it finds the UKI kernel-install just
# built under $ESP/EFI/Linux/, signs it with the MOK key, and installs it as
# grubx64.efi on the ESP. Using the full script (instead of duplicating the
# find/sbsign logic here) keeps a single source of truth.
/usr/local/bin/maze-sb-sign --force-bootloader >/dev/null 2>&1 || true
exit 0
KISIGN

    # systemd .path unit + once-per-boot service: self-heal for kernel writes that
    # happen with no pacman transaction (manual `kernel-install`/`reinstall-kernels`,
    # a manual `mkinitcpio -P`). The kernel-install plugin above is the primary
    # inline signer; this watches loader/entries (and EFI/Linux) so a freshly
    # written BLS kernel/UKI still gets re-signed even when the plugin is bypassed.
    install -Dm644 /dev/stdin "${TARGET}/etc/systemd/system/maze-sb-resign.service" <<'SBSVC'
[Unit]
Description=Re-sign bootloader and kernels for Secure Boot (Maze)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/maze-sb-sign

[Install]
WantedBy=multi-user.target
SBSVC
    install -Dm644 /dev/stdin "${TARGET}/etc/systemd/system/maze-sb-resign.path" <<'SBPATH'
[Unit]
Description=Watch for regenerated kernels/UKIs and re-sign them (Maze Secure Boot)

[Path]
# Every `kernel-install add` (layout=uki) writes the UKI straight to
# $ESP/EFI/Linux/<machine-id>-<kver>.efi, so watching that directory reliably
# catches an out-of-band kernel write (manual reinstall-kernels / kernel-install
# with no pacman transaction) — whereas watching /boot itself does NOT, since
# adding a file under a sub-directory leaves /boot's own mtime untouched. The
# loader/entries paths are kept as a defensive fallback in case layout ever
# reverts to bls. Both ESP mount points (/boot and /efi) are listed; systemd
# waits for whichever exists.
PathChanged=/boot/loader/entries
PathChanged=/efi/loader/entries
PathChanged=/boot/EFI/Linux
PathChanged=/efi/EFI/Linux
Unit=maze-sb-resign.service

[Install]
WantedBy=paths.target
SBPATH
    in_chroot systemctl enable maze-sb-resign.path maze-sb-resign.service >/dev/null 2>&1 \
        || warn "Secure Boot: could not enable maze-sb-resign units"
    # Mask systemd's own boot updater: `bootctl update` would overwrite the shim at
    # EFI/BOOT/BOOTX64.EFI with an unsigned systemd-boot and break the chain.
    in_chroot systemctl mask systemd-boot-update.service >/dev/null 2>&1 || true

    # 3) Sign now (explicit ESP — bootctl is unreliable in the install chroot).
    if in_chroot /usr/local/bin/maze-sb-sign --force-bootloader "${esp_rel}"; then
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
    local bn
    for bn in $(in_chroot efibootmgr -v 2>/dev/null \
                  | grep -i 'systemd-bootx64\.efi' \
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
# 4. The Calamares installer launcher itself.
rm -f "${TARGET}/usr/local/bin/maze-calamares" 2>/dev/null || true
rm -f "${TARGET}/usr/share/applications/maze-calamares.desktop" 2>/dev/null || true
# 5. The live-user build helper (harmless but live-only).
rm -f "${TARGET}/usr/local/share/maze/setup-live-user.sh" 2>/dev/null || true
# 5b. The live medium's /etc/motd ("...live and install medium", "run maze-install",
#     "default user is root no password") must not greet an installed system.
rm -f "${TARGET}/etc/motd" 2>/dev/null || true
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
#     the hostname to the local network. Remove both live-only resolved drop-ins;
#     maze-hardening provides its own NetworkManager-based DNS config instead.
rm -f "${TARGET}/etc/systemd/resolved.conf.d/archiso.conf" 2>/dev/null || true
rm -f "${TARGET}/etc/systemd/resolved.conf.d/maze-dns.conf" 2>/dev/null || true
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

# 3b) GPU: configure the NVIDIA proprietary driver if the installer added it ---
NVIDIA_PARAMS=""
if in_chroot pacman -Qq nvidia nvidia-dkms nvidia-open nvidia-open-dkms nvidia-lts 2>/dev/null | grep -q .; then
    log "Configuring NVIDIA proprietary driver (modeset + early KMS)"
    cat > "${TARGET}/etc/modprobe.d/nvidia.conf" <<'EOF'
# DRM kernel mode setting + framebuffer console handover (clean splash, no
# vendor-fbdev flicker) and GPU System Processor firmware for Turing+ cards.
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_EnableGpuFirmware=1
# Keep VRAM contents across suspend/hibernate so the desktop comes back without
# corruption (works together with the nvidia-suspend/resume services below).
options nvidia NVreg_PreserveVideoMemoryAllocations=1
# Use the Page Attribute Table for memory mappings (better GPU throughput).
options nvidia NVreg_UsePageAttributeTable=1

blacklist nouveau
options nouveau modeset=0
EOF
    mkc="${TARGET}/etc/mkinitcpio.conf"
    if [[ -f "${mkc}" ]] && ! grep -q 'nvidia' "${mkc}"; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "${mkc}" 2>/dev/null \
            || warn "mkinitcpio MODULES (nvidia) edit failed"
    fi
    # Preserve-VRAM needs these to actually save/restore on sleep & hibernate.
    in_chroot systemctl enable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service \
        >/dev/null 2>&1 || warn "could not enable nvidia suspend/resume services"
    NVIDIA_PARAMS=" nvidia-drm.modeset=1 nvidia-drm.fbdev=1"
fi

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
    if ! grep -q 'plymouth' "${mkconf}"; then
        # Not in hooks yet — add right after kms (GPU up = clean splash), or after udev.
        if grep -qE 'HOOKS=\([^)]*\bkms\b' "${mkconf}"; then
            sed -i -E 's/(HOOKS=\([^)]*\bkms\b)/\1 plymouth/' "${mkconf}" 2>/dev/null || warn "mkinitcpio HOOKS edit failed"
        else
            sed -i 's/\(HOOKS=([^)]*udev\)/\1 plymouth/' "${mkconf}" 2>/dev/null || warn "mkinitcpio HOOKS edit failed"
        fi
    elif grep -qE '\bkms\b' "${mkconf}" && ! grep -qE '\bkms\b[[:space:]]+\bplymouth\b' "${mkconf}"; then
        # Plymouth already in hooks but not right after kms — reposition it.
        sed -i -E 's/[[:space:]]*\bplymouth\b//' "${mkconf}" 2>/dev/null || true
        sed -i -E 's/(HOOKS=\([^)]*\bkms\b)/\1 plymouth/' "${mkconf}" 2>/dev/null || warn "mkinitcpio plymouth reposition failed"
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
    # `plymouth` is already inserted right after `kms` above — well before the
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
    if grep -qE '^[[:space:]]*#?[[:space:]]*COMPRESSION=' "${mkconf}"; then
        sed -i -E 's|^[[:space:]]*#?[[:space:]]*COMPRESSION=.*|COMPRESSION="zstd"|' "${mkconf}" 2>/dev/null || true
    else
        printf 'COMPRESSION="zstd"\n' >> "${mkconf}"
    fi
    # Drop any xz-style COMPRESSION_OPTIONS that would no longer apply to zstd.
    sed -i -E 's|^[[:space:]]*COMPRESSION_OPTIONS=.*|COMPRESSION_OPTIONS=()|' "${mkconf}" 2>/dev/null || true
fi
# 5) Kernel command line — must be written BEFORE mkinitcpio so UKI picks it up.
log "Adding kernel parameters (quiet splash bgrt_disable + AppArmor${NVIDIA_PARAMS:+ + NVIDIA})"
# The full set of params Maze wants on every boot. NONE of these is root=/
# rootflags=/rootfstype= — those belong to the installer and must never be
# duplicated by us.
EXTRA_PARAMS="quiet splash bgrt_disable logo.nologo lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1 security=apparmor${NVIDIA_PARAMS}"

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
    _enc_ok=0
    for _img in "${TARGET}"/boot/initramfs-*.img; do
        [[ -f "${_img}" ]] || continue
        case "${_img}" in *fallback*) continue ;; esac
        if in_chroot lsinitcpio -a "/boot/$(basename "${_img}")" 2>/dev/null | grep -qw encrypt; then
            _enc_ok=1
            log "LUKS: verified 'encrypt' hook in $(basename "${_img}") — the passphrase box will appear at boot"
        else
            warn "LUKS: 'encrypt' hook MISSING from $(basename "${_img}") — root will not unlock / no password box. HOOKS=$(grep -E '^HOOKS=' "${mkconf}" 2>/dev/null)"
        fi
    done
    [[ "${_enc_ok}" -eq 0 ]] && warn "LUKS: no plain /boot/initramfs-*.img to verify; ensure HOOKS in ${mkconf} contains 'encrypt'"
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
            warn "LUKS: could not persist allow-discards on ${_luks_name}"
        fi
    fi
fi

# 6) Enable services on the target -----------------------------------------
# Non-security services are always enabled. Security services are enabled only
# if the user kept them in the installer's Security section (empty = all).
# zram-generator drives the compressed RAM swap configured above; install it on
# the target if we can reach the network (best-effort, skipped offline).
in_chroot pacman -S --needed --noconfirm zram-generator >/dev/null 2>&1 \
    || warn "zram-generator not installed (offline?); /etc/systemd/zram-generator.conf is in place for later"

# Virtualization stack — deliberately NOT on the live ISO (see packages.x86_64:
# qemu-full alone added ~2 GB of foreign-arch emulators/firmware to the image),
# so it is installed HERE, on the target, over the network. qemu-desktop is the
# x86/KVM subset virt-manager actually uses. Gated on the Extras packagechooser
# selection: skipped if the user deselected "qemu-virt". Best-effort: offline
# installs just skip it (libvirtd enable below then no-ops) and the user can
# install it later.
if [[ -z "${EXTRAS_CSV}" || ",${EXTRAS_CSV}," == *",qemu-virt,"* ]]; then
    log "Installing virtualization stack on the target (qemu-desktop + libvirt + virt-manager)"
    if in_chroot pacman -S --needed --noconfirm qemu-desktop libvirt virt-manager edk2-ovmf vde2 dnsmasq >/dev/null 2>&1; then
        for _h in "${TARGET}"/home/*; do
            [[ -d "${_h}" ]] || continue
            _u="$(basename "${_h}")"
            in_chroot id "${_u}" >/dev/null 2>&1 || continue
            for _g in libvirt kvm; do
                in_chroot getent group "${_g}" >/dev/null 2>&1 \
                    && in_chroot usermod -aG "${_g}" "${_u}" >/dev/null 2>&1 || true
            done
        done
    else
        warn "virtualization stack not installed (offline?); install later with: pacman -S qemu-desktop libvirt virt-manager edk2-ovmf"
    fi
else
    log "QEMU virtualization deselected — skipping"
fi

# VMware is no longer installed here — the user runs `maze-install-vmware`
# (maze-tools) on demand, which pulls vmware-workstation + open-vm-tools via paru.

log "Enabling base Maze services"
for svc in ollama acpid power-profiles-daemon smartd fstrim.timer bluetooth cups \
           tor systemd-oomd fwupd-refresh.timer reflector.timer maze-flatpak-setup.service \
           maze-guardd.service maze-sentinel-setup.service maze-sentinel.service; do
    in_chroot systemctl enable "${svc}" >/dev/null 2>&1 || true
done
# libvirtd only makes sense when the virtualization stack was installed.
if [[ -z "${EXTRAS_CSV}" || ",${EXTRAS_CSV}," == *",qemu-virt,"* ]]; then
    in_chroot systemctl enable libvirtd >/dev/null 2>&1 || true
fi

# Disable LIVE-only services that unpackfs carried over but must NOT run on an
# installed desktop. sshd is the important one: the live ISO enables it for
# remote installs, so without this every installed Maze boots with an SSH server
# listening — an attack surface a privacy desktop should not expose by default.
# (The Maze sshd hardening drop-in stays in place, so if the user enables sshd
# later it is already hardened.) The VM guest agents are harmless on real
# hardware but pointless to keep enabled.
log "Disabling live-only services on the target (sshd, VM guest agents)"
# choose-mirror + livecd-talk are condition-gated (kernel cmdline) so they never
# actually run on the target, but disable them anyway so `systemctl` output on
# the installed system carries no live-medium leftovers.
for svc in sshd vboxservice \
           hv_kvp_daemon hv_vss_daemon hv_fcopy_daemon \
           vmtoolsd vmware-vmblock-fuse \
           choose-mirror livecd-talk; do
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
    in_chroot firewall-offline-cmd --add-service=ssh        >/dev/null 2>&1 || true
    in_chroot firewall-offline-cmd --add-service=kdeconnect >/dev/null 2>&1 || true
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
# the curated third-party AUR apps (brave-origin-bin, upscayl-bin, joplin-bin,
# session-desktop-bin, claude-code, paru, …): while those names still resolve to a
# sync repo, pacman treats them as native packages and `paru -Syu` — which only
# reconciles *foreign* (`pacman -Qm`) packages against the AUR — never offers their
# updates. Dropping the section makes them foreign again so paru keeps them current
# from the AUR. (Maze's OWN apps stay in [mazelinux] and update from the Maze repo.)
tconf="${TARGET}/etc/pacman.conf"
if [[ -f "${tconf}" ]] && grep -q '^\[maze-aur\]' "${tconf}"; then
    log "Removing build-only [maze-aur] localrepo from target pacman.conf"
    sed -i '/^\[maze-aur\]/,/^Server/d' "${tconf}" 2>/dev/null || true
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
    sed -i '/^\[blackarch\]/,/^Include.*blackarch/d' "${tconf}" 2>/dev/null || true
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

# entropy-shield.install tries to auto-add the installing user to the
# 'entropy-shield' group via $SUDO_USER/logname, and maze.install's
# _setup_group() does not even try (it just prints a manual "sudo usermod"
# instruction). Neither works here: pacman runs inside a non-interactive
# arch-chroot (install_maze_repo_apps -> in_chroot pacman -S), so there is no
# SUDO_USER/logname/tty session to detect the desktop user from. Same class of
# bug as the libvirt/kvm fix above: fix it the same way, after the packages
# (and their groups) exist.
for _h in "${TARGET}"/home/*; do
    [[ -d "${_h}" ]] || continue
    _u="$(basename "${_h}")"
    in_chroot id "${_u}" >/dev/null 2>&1 || continue
    for _g in entropy-shield maze; do
        in_chroot getent group "${_g}" >/dev/null 2>&1 \
            && in_chroot usermod -aG "${_g}" "${_u}" >/dev/null 2>&1 || true
    done
done

# 11) FINALLY, install the third-party AUR packages (slowest/most fragile step —
#     done last so everything above is guaranteed to be applied even if this
#     struggles).
install_aur_packages

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
        in_chroot /usr/local/bin/maze-sb-sign --force-bootloader "${MAZE_SB_ESP}" \
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
