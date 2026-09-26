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
# No `exit` here: the driver prints the summary and decides the exit code
# (non-zero when a step recorded a CRITICAL problem).
