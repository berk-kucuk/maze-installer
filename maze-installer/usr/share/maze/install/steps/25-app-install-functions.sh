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
    # Fully synced system first — never install onto a partially upgraded one.
    if ! sync_upgrade_target; then
        warn "skipping [mazelinux] app install (run 'maze-aur-setup' after first boot)"
        return 0
    fi
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

    # makepkg -s resolves build/runtime deps from the repos: only on a fully
    # synced system (see sync_upgrade_target). Checked BEFORE the temporary
    # sudoers rule exists, so bailing out here leaves nothing behind.
    if ! sync_upgrade_target; then
        warn "skipping the AUR builds (run 'maze-aur-setup' after first boot)"
        return 0
    fi

    # Temporary passwordless sudo for the build user (makepkg calls sudo pacman).
    local sudoers="${TARGET}/etc/sudoers.d/99-maze-build"
    # env_keep: the build script's `sudo pacman -U` must inherit SNAP_PAC_SKIP
    # from in_chroot (sudo's env_reset would drop it and snap-pac would fire).
    printf 'Defaults env_keep += "SNAP_PAC_SKIP"\n%s ALL=(ALL) NOPASSWD: ALL\n' "${build_user}" > "${sudoers}"
    chmod 440 "${sudoers}"
    trap 'rm -f "'"${sudoers}"'"' EXIT

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
    # off the ISO (e.g. onlyoffice-bin for size) — or missing from an ISO built
    # without them, such as paru — actually reach the makepkg path below. Installed apps stay at the
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
        if retry 2 timeout 1800 bash -c 'cd "$1" && makepkg -s --noconfirm --needed' _ "$tmp/$pkg"; then
            # Install the built package(s) ourselves. No --overwrite: a file
            # conflict means the package would clobber a file another package
            # owns (or an untracked system file), and that must fail loudly
            # rather than be silently overwritten on a fresh install.
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
                if retry 2 sudo pacman -U --noconfirm --needed "${pkgfiles[@]}"; then
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

