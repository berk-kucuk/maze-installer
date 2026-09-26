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

