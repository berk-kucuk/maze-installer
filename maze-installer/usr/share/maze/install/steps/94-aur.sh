# @title      AUR applications
# @title.tr   AUR uygulamaları
# @timeout    7200
# @weight     30

# 11) FINALLY, install the third-party AUR packages (slowest/most fragile step —
#     done last so everything above is guaranteed to be applied even if this
#     struggles).
install_aur_packages

# SECURITY: belt-and-braces removal of the build-time NOPASSWD sudoers. The
# function deletes it itself and clears its EXIT trap; this line is what covers
# the case where the function returned early or its cleanup did not run.
rm -f "${TARGET}/etc/sudoers.d/99-maze-build" 2>/dev/null || true
if [[ -e "${TARGET}/etc/sudoers.d/99-maze-build" ]]; then
    critical "could not remove the build-time passwordless sudo rule ${TARGET}/etc/sudoers.d/99-maze-build — delete it before first boot"
fi

# Apps unticked on the Options page: the ISO ships most of them prebuilt, so
# unpackfs already copied them onto the target — leaving them out means
# removing that copy (with what only they pulled in). Nothing here needs the
# network, so this works even when the AUR step above could not.
for _app in "${MAZE_AUR_REMOVE[@]}"; do
    in_chroot pacman -Qq "${_app}" >/dev/null 2>&1 || continue
    if in_chroot pacman -Rns --noconfirm "${_app}" >/dev/null 2>&1; then
        log "Removed ${_app} (unticked on the Options page)"
    else
        warn "could not remove ${_app} (unticked on the Options page); remove it with: sudo pacman -Rns ${_app}"
    fi
done
