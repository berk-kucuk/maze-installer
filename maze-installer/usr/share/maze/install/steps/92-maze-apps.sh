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

