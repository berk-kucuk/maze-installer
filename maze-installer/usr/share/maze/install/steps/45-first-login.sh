# 2d) Maze wallpaper on the installed system --------------------------------
# Patch the Plasma defaults so "Maze" is the default wallpaper (covers fresh
# profiles / fallback when the live containment's plugin is unavailable).
if [[ -f /usr/local/share/maze/set-default-wallpaper.sh ]]; then
    install -Dm755 /usr/local/share/maze/set-default-wallpaper.sh \
        "${TARGET}/usr/local/share/maze/set-default-wallpaper.sh" 2>/dev/null || true
    in_chroot /usr/local/share/maze/set-default-wallpaper.sh >/dev/null 2>&1 \
        || warn "set-default-wallpaper on target failed"
fi

# 2e) Maze Welcome on the FIRST boot after install -------------------------
# Drop the welcome autostart into the target skel so each newly created user
# sees it once on first login. The app deletes this entry the first time it
# runs, so it never opens again. This lives only on the installed system (it is
# NOT in the live ISO's /etc/skel), so the live session never autostarts it.
if [[ -f /usr/share/maze/target-firstboot/maze-welcome-autostart.desktop ]]; then
    install -Dm644 /usr/share/maze/target-firstboot/maze-welcome-autostart.desktop \
        "${TARGET}/etc/skel/.config/autostart/maze-welcome.desktop" 2>/dev/null \
        || warn "welcome autostart install failed"
fi

# 2f) Best monitor as primary on the FIRST login ---------------------------
# Multi-monitor installs start with no saved screen state (it is stripped above
# so KWin re-detects per hardware), so KWin can make the wrong connector primary
# and the Maze panel — pinned to screen 0 — lands on the wrong monitor. The
# maze-primary-screen helper promotes the highest-resolution output to primary
# on first login, then drops a per-user marker so it never overrides the user's
# own Display-settings choices afterwards. Installed-system only (not live skel).
if [[ -f /usr/share/maze/target-firstboot/maze-primary-screen-autostart.desktop ]]; then
    install -Dm644 /usr/share/maze/target-firstboot/maze-primary-screen-autostart.desktop \
        "${TARGET}/etc/skel/.config/autostart/maze-primary-screen.desktop" 2>/dev/null \
        || warn "primary-screen autostart install failed"
fi

# 2f) Remove KDE's stock Plasma Welcome so only the Maze Welcome app appears.
# -Rdd ignores the plasma-meta dependency (harmless: meta-package only). Without
# the plasma-welcome binary, its autostart entry simply does nothing. We also
# keep the skel Hidden=true mask as a fallback in case an upgrade pulls it back.
if in_chroot pacman -Qq plasma-welcome >/dev/null 2>&1; then
    log "Removing KDE's stock Plasma Welcome (only Maze Welcome should run)"
    in_chroot pacman -Rdd --noconfirm plasma-welcome >/dev/null 2>&1 \
        || warn "could not remove plasma-welcome (Hidden=true mask still applies)"
fi

# 2g) Default account picture — the Maze maze-block logo --------------------
# Drop the logo into the skel as ~/.face.icon (KDE and SDDM use it as the user
# avatar). Each created user also gets an authoritative AccountsService entry in
# the per-user loop below, which is what the login screen and System Settings
# read first; ~/.face.icon is the fallback. Both point at the same image.
MAZE_AVATAR_SRC="/usr/share/pixmaps/maze-user-avatar.png"
if [[ -f "${MAZE_AVATAR_SRC}" ]]; then
    install -Dm644 "${MAZE_AVATAR_SRC}" "${TARGET}/etc/skel/.face.icon" 2>/dev/null \
        || warn "skel .face.icon install failed"
fi

