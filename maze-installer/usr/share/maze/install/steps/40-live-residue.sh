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
# maze-hardening (>= 1.0.0-8) ships it as /etc/sudoers.d/00-maze-wheel, so on a
# current ISO it is already there and package-owned; it is only written here —
# atomically, 0440 so sudo accepts it — for an image built with an older package.
_sudoers_dir="${TARGET}/etc/sudoers.d"
if [[ -f "${_sudoers_dir}/00-maze-wheel" ]]; then
    log "wheel sudo rule (password required) is provided by maze-hardening"
elif [[ -d "${_sudoers_dir}" ]]; then
    printf '# Maze Linux: members of group wheel may use sudo (password required).\n%%wheel ALL=(ALL:ALL) ALL\n' \
        > "${_sudoers_dir}/10-maze-wheel" 2>/dev/null \
        && chmod 0440 "${_sudoers_dir}/10-maze-wheel" 2>/dev/null \
        || warn "could not write target wheel sudoers"
fi

