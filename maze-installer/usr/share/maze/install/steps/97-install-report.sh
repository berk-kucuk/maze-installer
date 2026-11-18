# @title      First-login installation report
# @title.tr   İlk girişte kurulum raporu
# @timeout    120
# @weight     1

# The installation summary (warnings, critical problems, per-step results) is
# written to /var/log/maze-install-summary.txt — where nobody looks unless
# something already went wrong. Tell the first person who logs in, ONCE per
# user, when the install had warnings or problems; a clean install says
# nothing. "Show" opens the summary.
#
# Written into the target here rather than shipped in a package: maze-installer
# is removed from the installed system (40-live-residue), and this belongs to
# the installation, not to any package. The summary itself is written after
# the last step; the script only reads it at login.
log "Installing the first-login installation report"
mkdir -p "${TARGET}/usr/local/lib/maze" "${TARGET}/etc/xdg/autostart"
cat > "${TARGET}/usr/local/lib/maze/install-report" <<'REPORT'
#!/bin/sh
# Maze Linux — tell this user, once, how the installation went (written by the
# installer; see /usr/share/maze/install/steps/97-install-report.sh on the ISO).
summary=${MAZE_INSTALL_SUMMARY:-/var/log/maze-install-summary.txt}
marker="${XDG_CONFIG_HOME:-$HOME/.config}/maze/install-report-shown"
[ -e "$marker" ] && exit 0
mkdir -p "${marker%/*}" && : > "$marker"
[ -r "$summary" ] || exit 0
warnings=$(sed -n 's/^Warnings (\([0-9][0-9]*\)):$/\1/p' "$summary")
critical=$(grep -c '^CRITICAL' "$summary")
[ -n "$warnings" ] || [ "$critical" -gt 0 ] || exit 0
case "${LANG:-}" in
    tr*) show="Göster"
         if [ "$critical" -gt 0 ]; then title="Kurulum sorunlarla tamamlandı"
         else title="Kurulum ${warnings} uyarıyla tamamlandı"; fi
         body="Ayrıntılar: $summary" ;;
    *)   show="Show"
         if [ "$critical" -gt 0 ]; then title="The installation finished with problems"
         else title="The installation finished with ${warnings} warning(s)"; fi
         body="Details: $summary" ;;
esac
icon=dialog-information
[ "$critical" -gt 0 ] && icon=dialog-warning
# Let the desktop finish starting, so the notification is not lost.
sleep "${MAZE_REPORT_DELAY:-20}"
action=$(notify-send --app-name="Maze Linux" --icon="$icon" --action=show="$show" \
             "$title" "$body" 2>/dev/null)
[ "$action" = show ] && exec xdg-open "$summary"
exit 0
REPORT
chmod 755 "${TARGET}/usr/local/lib/maze/install-report" \
    || warn "could not install the first-login installation report"
cat > "${TARGET}/etc/xdg/autostart/maze-install-report.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Maze installation report
Exec=/usr/local/lib/maze/install-report
NoDisplay=true
X-KDE-autostart-phase=2
DESKTOP
chmod 644 "${TARGET}/etc/xdg/autostart/maze-install-report.desktop" 2>/dev/null || true
