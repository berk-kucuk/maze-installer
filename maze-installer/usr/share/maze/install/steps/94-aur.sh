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

