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
# page was removed and EXTRAS_CSV is hardcoded to "none" at the top of this
# script — so the gate could never open and the code (plus the matching
# `systemctl enable libvirtd`) was dead on every single install. Removed rather
# than left to look like a feature that runs.

# VMware is no longer installed here — the user runs `maze-install-vmware`
# (maze-tools) on demand, which pulls vmware-workstation + open-vm-tools via paru.

log "Enabling base Maze services"
for svc in ollama acpid power-profiles-daemon smartd fstrim.timer bluetooth cups \
           tor systemd-oomd fwupd-refresh.timer reflector.timer maze-flatpak-setup.service \
           maze-guardd.service maze-sentinel-setup.service maze-sentinel.service; do
    in_chroot systemctl enable "${svc}" >/dev/null 2>&1 || true
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
# installed desktop. sshd is the important one: the live ISO enables it for
# remote installs, so without this every installed Maze boots with an SSH server
# listening — an attack surface a privacy desktop should not expose by default.
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
for svc in sshd vboxservice \
           hv_kvp_daemon hv_vss_daemon hv_fcopy_daemon \
           vmtoolsd vmware-vmblock-fuse \
           choose-mirror livecd-talk \
           cloud-init-local cloud-init-network cloud-init-main cloud-config cloud-final; do
    in_chroot systemctl disable "${svc}" >/dev/null 2>&1 || true
done

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

# Resolve the selected security features (empty selection => all of them).
sec_selected() {
    local key="$1"
    # Empty OR the literal "all" both mean "every security feature is on".
    # Calamares invokes this script with the security CSV as "all" for the
    # default install. Without the "all" case, sec_selected would treat "all" as
    # a feature name matching nothing, so EVERY real feature (apparmor, firewalld,
    # fail2ban, opensnitch, macchanger, …) would read as unselected — silently
    # not enabling them, wrongly stripping MAC randomization, and deleting the
    # opensnitch tray autostart (the visible symptom).
    [[ -z "${SECURITY_CSV}" || "${SECURITY_CSV}" == "all" ]] && return 0
    case ",${SECURITY_CSV}," in
        *",${key},"*) return 0 ;;
        *) return 1 ;;
    esac
}

log "Applying Security selection: ${SECURITY_CSV:-<all>}"
sec_selected apparmor   && in_chroot systemctl enable apparmor          >/dev/null 2>&1 || true
sec_selected firewalld  && in_chroot systemctl enable firewalld         >/dev/null 2>&1 || true
sec_selected auditd     && in_chroot systemctl enable auditd            >/dev/null 2>&1 || true
sec_selected clamav     && in_chroot systemctl enable clamav-freshclam  >/dev/null 2>&1 || true
# MAC randomization is owned exclusively by maze-guard now (its privileged helper
# manages the interface's MAC). There is no NetworkManager drop-in or mac-changer
# service to toggle here anymore — those were removed because a second randomiser
# fought maze-guard and made its MAC feature fail. maze-guard honours the user's
# choice inside its own UI, so the installer's "macchanger" security toggle no
# longer does anything at deploy time.

# OpenSnitch: daemon always enabled but starts in allow-all (passive) mode.
# GUI autostarts so user sees it in the tray; they can activate interception manually.
if sec_selected opensnitch; then
    in_chroot systemctl enable opensnitchd >/dev/null 2>&1 || true
else
    rm -f "${TARGET}/etc/skel/.config/autostart/opensnitch_ui.desktop" 2>/dev/null || true
    for home in "${TARGET}"/home/*; do
        [[ -d "${home}" ]] && rm -f "${home}/.config/autostart/opensnitch_ui.desktop" 2>/dev/null || true
    done
fi

if sec_selected firewalld; then
    in_chroot firewall-offline-cmd --add-service=ssh          >/dev/null 2>&1 || true
    in_chroot firewall-offline-cmd --add-service=kdeconnect   >/dev/null 2>&1 || true
    # maze-connect (TCP+UDP 38271) — BACKSTOP only. Owning this rule is the
    # maze-connect package's job and its scriptlet does it properly now; this line
    # exists because the failure mode is silent (the app runs, shows its address,
    # and simply never links) and the rule has to survive a long chain to get here:
    # scriptlet in the ISO's pacstrap chroot -> zone file in the airootfs ->
    # unpackfs copy. Re-adding it is idempotent and costs nothing. Referenced by
    # SERVICE NAME, so a port change in maze-connect's XML needs no edit here.
    in_chroot firewall-offline-cmd --add-service=maze-connect >/dev/null 2>&1 || true
fi

