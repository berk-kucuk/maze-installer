# 3) Apply the desktop config to the user(s) created by the installer -------
log "Applying Maze defaults to user home directories"
for home in "${TARGET}"/home/*; do
    [[ -d "${home}" ]] || continue
    user=$(basename "${home}")
    owner_uid=$(stat -c '%u' "${home}")
    owner_gid=$(stat -c '%g' "${home}")
    # Maze Guard gates its privileged-helper control socket (/run/maze/maze.sock)
    # on the `maze` group — members drive the firewall / MAC randomiser without a
    # root prompt. TWO things must be true, and BOTH were broken before:
    #   1) The group must EXIST. removeuser (userdel -r maze) deletes the live
    #      `maze` user AND its same-named primary group, so by the time we run the
    #      group is GONE — recreate it (maze-guard's sysusers.d normally ships it).
    #      This is exactly what reinstalling maze-guard did to fix it by hand.
    #   2) The new user must be a MEMBER — add them.
    # Skipping (1) is why the earlier "add user to maze" alone silently no-op'd
    # (gpasswd on a non-existent group) and maze-guard kept asking for root.
    in_chroot getent group maze >/dev/null 2>&1 || in_chroot groupadd -r maze >/dev/null 2>&1 || true
    in_chroot gpasswd -a "${user}" maze >/dev/null 2>&1 || true
    # Same optional groups the live user gets in setup-live-user.sh: wireshark
    # (packet capture without root — wireshark-qt ships on every install),
    # kvm/libvirt (only exist once virtualisation is installed, then the user
    # should not have to log out and back in to use it). Skipped when absent.
    for _og in wireshark kvm libvirt; do
        in_chroot getent group "${_og}" >/dev/null 2>&1 \
            && in_chroot gpasswd -a "${user}" "${_og}" >/dev/null 2>&1 || true
    done
    cp -an "${TARGET}/etc/skel/." "${home}/" 2>/dev/null || warn "skel copy to ${home} failed"
    # FORCE the Maze .zshrc over whatever the home already has. grml-zsh-config
    # ships its OWN /etc/skel/.zshrc, so Calamares seeds the home with grml's
    # version at account-creation; the no-clobber copy above then can't replace it
    # and the user loses the Maze oh-my-zsh prompt + fastfetch banner. Overwrite
    # it explicitly. Same for .oh-my-zsh (must be the Maze one).
    if [[ -f "${TARGET}/etc/skel/.zshrc" ]]; then
        cp -f "${TARGET}/etc/skel/.zshrc" "${home}/.zshrc" 2>/dev/null || true
    fi
    [[ -d "${TARGET}/etc/skel/.oh-my-zsh" ]] && cp -an "${TARGET}/etc/skel/.oh-my-zsh" "${home}/" 2>/dev/null || true
    # Scrub display/output state from THIS user's home. useradd already seeded the
    # home from skel with cp -an (no-clobber) at account-creation time, so the
    # stale config can survive the skel copy above — strip it directly so the
    # primary monitor is auto-detected for this machine, not inherited.
    strip_display_state "${home}"
    # Default avatar: register the Maze avatar logo with AccountsService so the
    # SDDM login screen and System Settings > Users show it as the account
    # picture (~/.face.icon, copied from skel above, is the fallback).
    if [[ -f "${MAZE_AVATAR_SRC}" ]]; then
        acc_icons="${TARGET}/var/lib/AccountsService/icons"
        acc_users="${TARGET}/var/lib/AccountsService/users"
        mkdir -p "${acc_icons}" "${acc_users}"
        cp -f "${MAZE_AVATAR_SRC}" "${acc_icons}/${user}" 2>/dev/null || warn "avatar copy for ${user} failed"
        cat > "${acc_users}/${user}" <<EOF
[User]
Icon=/var/lib/AccountsService/icons/${user}
SystemAccount=false
EOF
    fi
    # The live panel config hard-codes the live user's home (/home/maze) for the
    # video wallpaper; repoint it at this user's home so the wallpaper resolves.
    user_appletsrc="${home}/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "${user_appletsrc}" && "${user}" != "maze" ]]; then
        sed -i "s#/home/maze/#/home/${user}/#g" "${user_appletsrc}" 2>/dev/null || true
    fi
    # Drop the installer (maze-install / maze-calamares) launcher from THIS user's
    # dock too. useradd seeded the home from skel BEFORE skel was stripped, and the
    # cp -an above is no-clobber, so the installer pin survives here and must be
    # removed explicitly — otherwise the installed system keeps an installer icon.
    strip_installer_launcher "${user_appletsrc}"
    # Make sure this user's default browser is Firefox (the home was seeded from
    # skel before skel was patched, and the cp -an above is no-clobber).
    set_default_browser "${home}/.config/mimeapps.list"
    set_kde_browser     "${home}/.config/kdeglobals"
    chown -R "${owner_uid}:${owner_gid}" "${home}" 2>/dev/null || true
    # Private home: 700 (not world-readable). A desktop home holds keys, tokens
    # and history; a 755 home leaks all of it to every local account. (lynis
    # HOME-9304.)
    chmod 700 "${home}" 2>/dev/null || true
    # ~/.ssh explicitly: sshd/ssh silently refuse to read/write known_hosts,
    # authorized_keys or private keys the moment the directory or its files are
    # group/other-writable, or owned by anyone but the user (ssh does not warn
    # about known_hosts the way it does about private keys — it just silently
    # skips writing, which looks like "known_hosts never gets created"). The
    # broad chown -R/chmod 700 above already covers ownership, but assert the
    # exact modes explicitly here too — this is what actually broke on a real
    # machine after root-context maintenance (a chroot repair session) left
    # root-owned entries under ~/.ssh. Guarded: most fresh installs have no
    # ~/.ssh yet (not seeded by skel), so this is normally a no-op.
    if [[ -d "${home}/.ssh" ]]; then
        chmod 700 "${home}/.ssh" 2>/dev/null || true
        find "${home}/.ssh" -mindepth 1 -type d -exec chmod 700 {} \; 2>/dev/null || true
        find "${home}/.ssh" -mindepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true
    fi
    # Match the live medium: zsh as the login shell. usermod edits /etc/passwd
    # directly (no PAM), so it can never prompt/hang the way chsh can.
    in_chroot usermod -s /usr/bin/zsh "${user}" >/dev/null 2>&1 || true
done

