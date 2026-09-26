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
            critical "could not lock root: anyone at a TTY can log in as root WITHOUT a password (fix: sudo passwd -l root)"
        fi
        ;;
    *)
        log "root password field is set (locked or hashed)"
        ;;
esac

