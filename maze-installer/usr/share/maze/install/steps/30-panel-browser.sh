# @title      Panel and default browser
# @title.tr   Panel ve varsayılan tarayıcı
# @timeout    300
# @weight     1

# 2c) Installed system must not advertise the installer ---------------------
# Remove the "Install Maze Linux" launcher from the panel/dock in the skel that
# will be copied to each user (the live ISO keeps it; the installed system does
# not need it). The live skel was already copied above, so patch it here.
log "Removing the installer launcher from the panel (installed system)"
strip_installer_launcher "${TARGET}/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"

# Firefox as the default browser (helpers and the reasoning: 28-browser-functions).
log "Setting Firefox as the default browser"
# System-wide fallback (covers accounts created later that bypass skel) …
set_default_browser "${TARGET}/etc/xdg/mimeapps.list"
# … and the skel every new user is seeded from.
set_default_browser "${TARGET}/etc/skel/.config/mimeapps.list"
set_kde_browser     "${TARGET}/etc/skel/.config/kdeglobals"

