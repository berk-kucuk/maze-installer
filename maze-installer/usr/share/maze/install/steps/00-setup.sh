# @library    sourced at the start of every step (idempotent)

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

# VMware was removed from the installer entirely — vmware-workstation is an AUR
# package that never builds in the offline/chroot install. It is installed on
# demand post-install via the `maze-install-vmware` command (maze-tools).

# Comma-separated list of selected security features (85-services). Empty or
# "all" means every feature; "none" means none. The Options page decides it
# (mazedeploy passes it here), otherwise Calamares passes "all".
SECURITY_CSV="${2:-}"

# maze_option NAME on|off — is option NAME ticked on the installer's Options
# page (netinstall@mazeoptions)? mazedeploy passes the ticked ids in
# MAZE_OPTIONS ("opt-apparmor opt-tor ..."). When it is not set at all — a
# direct run, the tests, a Calamares config without the page — the second
# argument decides, and every default here is the behaviour from before the
# page existed.
maze_option() {
    if [[ -z "${MAZE_OPTIONS+x}" ]]; then
        [[ "$2" == on ]]
        return
    fi
    [[ " ${MAZE_OPTIONS} " == *" opt-$1 "* ]]
}

# Third-party apps from the AUR.
#
# 'paru' always comes first and always stays: it is the AUR helper. It
# normally ships on the ISO (MazeLinux/packages.x86_64, built from source by
# tools/build-aur.sh against the ISO's own libalpm), so the AUR step finds it
# installed and skips it; otherwise it is built here FROM SOURCE (never
# paru-bin, which breaks after a pacman soname bump).
#
# onlyoffice-bin is deliberately kept OFF the ISO for size, so it is the one
# app actually downloaded and built during the install. joplin-bin,
# upscayl-bin, session-desktop-bin and claude-code are prebuilt on the ISO and
# arrive with unpackfs; listing them costs nothing (the AUR step skips what is
# installed) and builds them if an ISO ever lacks one.
#
# Each one can be unticked on the Options page: it is then neither built nor
# kept — 94-aur removes the copy unpackfs brought (MAZE_AUR_REMOVE). Without
# the page: paru + onlyoffice-bin, exactly as before.
CURATED_AUR=(paru)
MAZE_AUR_REMOVE=()
if [[ -z "${MAZE_OPTIONS+x}" ]]; then
    CURATED_AUR+=(onlyoffice-bin)
else
    for _app in onlyoffice-bin joplin-bin upscayl-bin session-desktop-bin claude-code; do
        if maze_option "app-${_app}" on; then
            CURATED_AUR+=("${_app}")
        else
            MAZE_AUR_REMOVE+=("${_app}")
        fi
    done
fi

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
DEFAULT_MAZE_APPS=(entropy-shield qlam maze-guard hazedrop haze maze-ai maze-connect maze-cloak maze-store)

