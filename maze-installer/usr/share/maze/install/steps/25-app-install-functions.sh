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

    # No sudo for the build user — not even temporarily. This used to write
    # /etc/sudoers.d/99-maze-build with "<user> ALL=(ALL) NOPASSWD: ALL" so that
    # `makepkg -s` and the final `pacman -U` could run, and then execute a
    # PKGBUILD freshly cloned from AUR HEAD as that user. Whoever controlled that
    # PKGBUILD (a maintainer, an adopter of an orphaned package, a stolen
    # account) got a passwordless-root shell on every new install, for the whole
    # build. The privileged steps are now done by THIS script, as root, around
    # an unprivileged build:
    #   1. clone (as the user) — at a reviewed commit if aur-pins lists one,
    #   2. read the dependencies from .SRCINFO (as the user) and install the
    #      missing ones from the official repos (as root, pacman only),
    #   3. makepkg WITHOUT -s (as the user, no sudo available),
    #   4. pacman -U the result (as root).
    # The PKGBUILD's own code still runs during step 3 and the package's
    # install scriptlet runs in step 4 — inherent to installing from the AUR —
    # but the build no longer holds root, and a pin turns "whatever HEAD is
    # today" into "the commit someone reviewed".
    local helper="${TARGET}${build_home}/.maze-aur-build.sh"
    local helper_in_chroot="${build_home}/.maze-aur-build.sh"
    cat > "${helper}" <<'MAKEPKG'
#!/usr/bin/env bash
# Unprivileged half of the AUR install. Called by the installer (root) as the
# build user, one subcommand at a time; it never has, or asks for, sudo.
set -u
exec </dev/null
VLOG="${HOME:-/tmp}/.maze-aur-verbose.log"
[[ -w "${VLOG}" || ! -e "${VLOG}" ]] || VLOG=/dev/null

retry() {
    local tries="$1"; shift
    local n=1
    while true; do
        "$@" >>"${VLOG}" 2>&1 && return 0
        (( n >= tries )) && return 1
        echo "   ...attempt ${n}/${tries} failed, retrying in $((n*5))s"
        sleep $((n*5)); ((n++))
    done
}

cmd="${1:-}"; shift || true
case "${cmd}" in
    clone)      # clone PKG DIR [COMMIT]
        pkg="$1" dir="$2" pin="${3:-}"
        if [[ -n "${pin}" ]]; then
            retry 3 git clone "https://aur.archlinux.org/${pkg}.git" "${dir}" || exit 1
            git -C "${dir}" -c advice.detachedHead=false checkout --quiet --detach "${pin}" >>"${VLOG}" 2>&1 || exit 1
            [[ "$(git -C "${dir}" rev-parse HEAD)" == "${pin}"* ]] || { echo "   -> pinned commit mismatch for ${pkg}"; exit 1; }
        else
            retry 3 git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "${dir}" || exit 1
        fi
        ;;
    srcinfo)    # srcinfo DIR -> dependency specs on stdout, one per line
        cd "$1" || exit 1
        makepkg --printsrcinfo 2>>"${VLOG}" \
            | sed -nE 's/^[[:space:]]*(make|check)?depends(_x86_64)? = (.+)$/\3/p' | sort -u
        ;;
    build)      # build DIR (no -s: dependencies were installed by root already)
        retry 2 timeout 1800 bash -c 'cd "$1" && makepkg --noconfirm' _ "$1" || exit 1
        ;;
    *) echo "usage: $0 clone|srcinfo|build ..." >&2; exit 2 ;;
esac
MAKEPKG
    chmod 755 "${helper}"
    in_chroot chown "${build_user}:${build_user}" "${helper_in_chroot}" 2>/dev/null || true

    # Optional review pins: "<pkg> <full commit hash>" per line, # comments.
    local pins_file="${MAZE_STEP_DIR:-$(dirname "${BASH_SOURCE[0]}")}/../aur-pins"
    declare -A _aur_pin=()
    if [[ -r "${pins_file}" ]]; then
        local _p _c
        while read -r _p _c _; do
            [[ -z "${_p}" || "${_p}" == \#* ]] && continue
            [[ "${_c}" =~ ^[0-9a-f]{40}$ ]] && _aur_pin["${_p}"]="${_c}"
        done < "${pins_file}"
    fi

    local aur_log="${TARGET}/var/log/maze-aur-install.log"
    : > "${aur_log}"
    _aur_user() { in_chroot sudo -u "${build_user}" -H bash "${helper_in_chroot}" "$@"; }

    # Root half of one package. Returns 0 on success.
    _aur_build_one() {
        local pkg="$1" tmp deps missing pkgfiles=() _pf
        if in_chroot pacman -Qq "${pkg}" >/dev/null 2>&1; then
            echo "   -> ${pkg} already installed (copied from the ISO); skipping AUR build."
            return 0
        fi
        # In the user's home, not /tmp: arch-chroot mounts a fresh tmpfs on
        # /tmp for every invocation, so a directory made there in one call is
        # gone in the next.
        tmp=$(in_chroot sudo -u "${build_user}" mktemp -d -p "${build_home}" .maze-aur.XXXXXX) || return 1
        local dir="${tmp}/${pkg}"
        [[ -n "${_aur_pin[${pkg}]:-}" ]] && echo "   (pinned to ${_aur_pin[${pkg}]:0:12})"
        if ! _aur_user clone "${pkg}" "${dir}" "${_aur_pin[${pkg}]:-}"; then
            in_chroot rm -rf "${tmp}"; return 1
        fi
        mapfile -t deps < <(_aur_user srcinfo "${dir}")
        if (( ${#deps[@]} )); then
            # pacman -T prints the specs that are NOT satisfied (versions and
            # provides honoured); install exactly those, from the repos only.
            mapfile -t missing < <(in_chroot pacman -T "${deps[@]}" 2>/dev/null | sed -E 's/[<>=].*$//')
            if (( ${#missing[@]} )); then
                if ! in_chroot pacman -S --needed --noconfirm --asdeps "${missing[@]}" >>"${aur_log}" 2>&1; then
                    echo "   -> could not install build dependencies for ${pkg}: ${missing[*]}"
                    in_chroot rm -rf "${tmp}"; return 1
                fi
            fi
        fi
        if ! _aur_user build "${dir}"; then
            in_chroot rm -rf "${tmp}"; return 1
        fi
        shopt -s nullglob
        for _pf in "${TARGET}${dir}"/*.pkg.tar.*; do
            # makepkg's default OPTIONS=(debug) also emits <pkg>-debug splits.
            case "$(basename "${_pf}")" in *-debug-*) continue ;; esac
            pkgfiles+=("${_pf#"${TARGET}"}")
        done
        shopt -u nullglob
        local ok=1
        # No --overwrite: a file conflict must fail loudly on a fresh install.
        if (( ${#pkgfiles[@]} )) && in_chroot pacman -U --noconfirm --needed "${pkgfiles[@]}" >>"${aur_log}" 2>&1; then
            ok=0
        fi
        in_chroot rm -rf "${tmp}"
        return "${ok}"
    }

    log "Installing AUR packages now — progress follows (full details in /var/log/maze-aur-install.log):"
    local _aur_rc=0 failed=() i=0 total=${#aur_list[@]} pkg
    for pkg in "${aur_list[@]}"; do
        ((i++))
        echo ":: (${i}/${total}) Installing ${pkg} from the AUR..." | tee -a "${aur_log}"
        if _aur_build_one "${pkg}"; then
            echo "   -> ${pkg} installed." | tee -a "${aur_log}"
        else
            echo "   -> ERROR: ${pkg} failed (see /var/log/maze-aur-install.log)." | tee -a "${aur_log}"
            _aur_rc=1; failed+=("${pkg}")
        fi
    done
    # AUR helper fallback: paru requested but missing -> try yay (also from source).
    if printf '%s\n' "${aur_list[@]}" | grep -qx paru && ! in_chroot pacman -Qq paru >/dev/null 2>&1; then
        echo ":: paru not installed — falling back to yay as the AUR helper..." | tee -a "${aur_log}"
        if _aur_build_one yay; then
            echo "   -> yay installed (paru fallback)." | tee -a "${aur_log}"
            local _kept=() _x
            for _x in "${failed[@]}"; do [[ "${_x}" == paru ]] || _kept+=("${_x}"); done
            failed=("${_kept[@]}")
            (( ${#failed[@]} == 0 )) && _aur_rc=0
        else
            echo "   -> ERROR: yay fallback also failed — no AUR helper installed." | tee -a "${aur_log}"
            failed+=(yay)
        fi
    fi

    local _vlog="${TARGET}${build_home}/.maze-aur-verbose.log"
    if [[ -f "${_vlog}" ]]; then
        { echo ""; echo "===== detailed build log ====="; cat "${_vlog}"; } >> "${aur_log}" 2>/dev/null || true
        rm -f "${_vlog}"
    fi
    if [[ "${_aur_rc}" -ne 0 ]]; then
        warn "AUR install had failures (${failed[*]}) — see /var/log/maze-aur-install.log (or run 'maze-aur-setup' after login)"
    fi
    rm -f "${helper}"
}

