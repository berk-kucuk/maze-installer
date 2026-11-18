# @title      System services and firewall
# @title.tr   Sistem servisleri ve güvenlik duvarı
# @timeout    900
# @weight     2

# 6) Enable services on the target -----------------------------------------
# Non-security services are always enabled. Security services are enabled only
# if the user kept them in the installer's Security section (empty = all).
# zram-generator drives the compressed RAM swap configured above; install it on
# the target if we can reach the network (best-effort, skipped offline).
# zram-generator is listed in packages.x86_64, so unpackfs has already put it on
# the target — check before reaching for the network. The old unconditional
# `pacman -S` ran BEFORE the target keyring is initialised (step 8b, further
# down), so it failed on a perfectly fine install and warned "offline?", which
# is exactly the wrong thing to send someone chasing. Only warn when the package
# is genuinely absent.
if ! in_chroot pacman -Qq zram-generator >/dev/null 2>&1; then
    in_chroot pacman -S --needed --noconfirm zram-generator >/dev/null 2>&1 \
        || warn "zram-generator is not installed and could not be fetched; /etc/systemd/zram-generator.conf is in place for later"
fi

# Virtualization is NOT set up at install time — by design, and no longer even
# attempted here. The stack was ~2 GB (qemu-full alone) so it never went on the
# live ISO, and installing it from the target chroot needs a working network in
# the middle of an otherwise offline install. Maze ships `maze-install-vmware`
# (maze-tools) instead: the user runs it once, post-install, and paru builds
# VMware Workstation + open-vm-tools and enables its services. Anyone who wants
# the KVM stack instead is one command away:
#     sudo pacman -S qemu-desktop libvirt virt-manager edk2-ovmf
#
# The old block here was gated on the Extras packagechooser selection, but that
# page was removed and EXTRAS_CSV was hardcoded to "none" at the top of this
# script — so the gate could never open and the code (plus the matching
# `systemctl enable libvirtd`) was dead on every single install. Removed rather
# than left to look like a feature that runs.

# VMware is no longer installed here — the user runs `maze-install-vmware`
# (maze-tools) on demand, which pulls vmware-workstation + open-vm-tools via paru.

log "Enabling base Maze services"
for svc in acpid power-profiles-daemon smartd fstrim.timer \
           systemd-oomd fwupd-refresh.timer reflector.timer maze-flatpak-setup.service \
           maze-switchd.service maze-sentinel-setup.service maze-sentinel.service; do
    in_chroot systemctl enable "${svc}" >/dev/null 2>&1 || true
done

# The services the Options page lets the user leave out (all on by default).
# Unticked ones are DISABLED, not just left alone: the live medium may have
# enabled them, and unpackfs copied that.
for _o in ollama:ollama tor:tor cups:cups bluetooth:bluetooth; do
    _name="${_o%%:*}"; _unit="${_o#*:}"
    if maze_option "${_name}" on; then
        in_chroot systemctl enable "${_unit}" >/dev/null 2>&1 || true
    else
        in_chroot systemctl disable "${_unit}" >/dev/null 2>&1 || true
        log "Service ${_unit} left off (unticked on the Options page)"
    fi
done

# Monthly btrfs scrub of the root filesystem (btrfs-progs' own timer; `/` is the
# instance "-", and scrubbing it covers every subvolume and snapshot). btrfs
# checksums every block but only notices a bad one when something reads it, so
# silent corruption — a RAM bit flip while a large package was being written was
# found this way on a test machine — would otherwise surface only when that file
# is next used. Idle I/O class, Nice 19, catches up after downtime.
if [[ "$(findmnt -no FSTYPE "${TARGET}" 2>/dev/null)" == btrfs ]]; then
    if in_chroot systemctl enable btrfs-scrub@-.timer >/dev/null 2>&1; then
        log "Enabled the monthly btrfs scrub of / (btrfs-scrub@-.timer)"
    else
        warn "could not enable btrfs-scrub@-.timer (monthly integrity check of /)"
    fi
fi

# Disable LIVE-only services that unpackfs carried over but must NOT run on an
# installed desktop. sshd is the important one: older live ISOs enabled it for
# remote installs (current ones no longer do), so without this every installed
# Maze could boot with an SSH server listening — an attack surface a privacy
# desktop should not expose by default.
# (The Maze sshd hardening drop-in stays in place, so if the user enables sshd
# later it is already hardened.) The VM guest agents are harmless on real
# hardware but pointless to keep enabled.
#
# cloud-init belongs in this list, not the boot-speed one below: on bare metal
# its own generator (cloud-init-generator) checks ds-identify and never even
# pulls in cloud-init.target, so it costs one shell script per boot and nothing
# else — but on a VM (VMware OVF, a NoCloud seed) ds-identify CAN find a
# datasource, and cloud-init is designed to rewrite the hostname, network config
# and user accounts of whatever it boots into. That is exactly the kind of
# live-medium behaviour that must not reach an installed desktop.
log "Disabling live-only services on the target (sshd, VM guest agents, cloud-init)"
# choose-mirror + livecd-talk are condition-gated (kernel cmdline) so they never
# actually run on the target, but disable them anyway so `systemctl` output on
# the installed system carries no live-medium leftovers.
for svc in vboxservice \
           hv_kvp_daemon hv_vss_daemon hv_fcopy_daemon \
           vmtoolsd vmware-vmblock-fuse \
           choose-mirror livecd-talk \
           cloud-init-local cloud-init-network cloud-init-main cloud-config cloud-final; do
    in_chroot systemctl disable "${svc}" >/dev/null 2>&1 || true
done
# sshd: off unless the user ticked "SSH server" on the Options page (the live
# medium enables it for remote installs; an installed privacy desktop should
# not listen on port 22 by default). Maze's sshd hardening drop-in is in place
# either way.
if maze_option sshd off; then
    in_chroot systemctl enable sshd >/dev/null 2>&1 \
        && log "SSH server enabled (ticked on the Options page)" \
        || warn "could not enable sshd"
else
    in_chroot systemctl disable sshd >/dev/null 2>&1 || true
fi

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


log "Applying Security selection: ${SECURITY_CSV:-<all>}"
# An unticked feature is disabled, not just left alone (the live medium may have
# enabled it, and unpackfs copied that).
for _s in apparmor:apparmor firewalld:firewalld auditd:auditd clamav:clamav-freshclam; do
    _key="${_s%%:*}"; _unit="${_s#*:}"
    if sec_selected "${_key}"; then
        in_chroot systemctl enable "${_unit}" >/dev/null 2>&1 || true
    else
        in_chroot systemctl disable "${_unit}" >/dev/null 2>&1 || true
        log "Security feature ${_key} left off (${_unit} disabled)"
    fi
done
# MAC randomization is owned exclusively by maze-guard now (its privileged helper
# manages the interface's MAC). There is no NetworkManager drop-in or mac-changer
# service to toggle here anymore — those were removed because a second randomiser
# fought maze-guard and made its MAC feature fail. maze-guard honours the user's
# choice inside its own UI, so the installer's "macchanger" security toggle no
# longer does anything at deploy time.

# OpenSnitch is no longer part of Maze (removed 2026-10): the ISO does not ship
# it, so there is no daemon to enable and no tray autostart to strip here.

if sec_selected firewalld; then
    in_chroot firewall-offline-cmd --add-service=ssh          >/dev/null 2>&1 || true
    # maze-connect (TCP+UDP 38271) — BACKSTOP only. Owning this rule is the
    # maze-connect package's job and its scriptlet does it properly now; this line
    # exists because the failure mode is silent (the app runs, shows its address,
    # and simply never links) and the rule has to survive a long chain to get here:
    # scriptlet in the ISO's pacstrap chroot -> zone file in the airootfs ->
    # unpackfs copy. Re-adding it is idempotent and costs nothing. Referenced by
    # SERVICE NAME, so a port change in maze-connect's XML needs no edit here.
    in_chroot firewall-offline-cmd --add-service=maze-connect >/dev/null 2>&1 || true
fi

