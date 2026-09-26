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
# 'paru' normally ships on the ISO (MazeLinux/packages.x86_64, built from
# source by tools/build-aur.sh against the ISO's own libalpm), so the AUR step
# finds it installed and skips it. It stays in this list as the fallback: an
# ISO built without it still gets paru, compiled here FROM SOURCE (never
# paru-bin, which breaks after a pacman soname bump). Listed first so the AUR
# helper is in place early.
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
#   - paru: the AUR helper. Normally already on the target (shipped on the ISO);
#     otherwise built from source here so it matches the target's libalpm ABI
#     (unlike paru-bin, which breaks after a pacman soname bump).
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

