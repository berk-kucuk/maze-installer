# @library    sourced at the start of every step (idempotent)

# Library: the panel/browser helpers 30-panel-browser and 50-user-homes share.
# Defines functions only — it changes nothing on the target by itself.

# Remove the "Install Maze Linux" launcher from a Plasma appletsrc.
strip_installer_launcher() {
    local appletsrc="$1"
    [[ -f "${appletsrc}" ]] || return 0
    # Drop the Calamares installer .desktop entry from any 'launchers=' list.
    sed -i -E 's#applications:maze-calamares\.desktop,?##g'  "${appletsrc}" 2>/dev/null || true
}

# 2b-ter) Firefox as the default browser on the installed system -------------
# Firefox is Maze's browser. maze-plasma-config (>= 1.2.1-5) ships both the
# skel's mimeapps.list and the SYSTEM-WIDE /etc/xdg/mimeapps.list (the fallback
# for accounts created later, outside skel) already pointing at it, so on a
# current ISO this step finds nothing to do. It stays as a guard for an image
# built with an older package, and for existing homes (50-user-homes).
# Rewrites ONLY the web handler keys; mailto/message-rfc822 (Thunderbird) and
# anything else in the file are preserved. Creates the file, and any missing
# section, when absent.
#
# A file that is already right is left byte-for-byte alone. Rewriting it
# anyway reordered its lines, so every installed system reported the
# package-owned skel file as modified (pacman -Qkk maze-plasma-config).
_browser_is_firefox() {
    local f="$1" k
    [[ -f "${f}" ]] || return 1
    for k in x-scheme-handler/http x-scheme-handler/https text/html application/xhtml+xml; do
        awk -v key="${k}=firefox.desktop" '
            /^\[/ { d = ($0 == "[Default Applications]") }
            d && $0 == key { found = 1 }
            END { exit !found }' "${f}" || return 1
    done
    return 0
}
set_default_browser() {
    local f="$1" tmp
    [[ -n "${f}" ]] || return 0
    _browser_is_firefox "${f}" && return 0
    mkdir -p "$(dirname "${f}")" 2>/dev/null || true
    [[ -f "${f}" ]] || : > "${f}"
    tmp="${f}.maze-tmp"
    awk '
        BEGIN {
            n = split("x-scheme-handler/http x-scheme-handler/https x-scheme-handler/about \
                       x-scheme-handler/unknown x-scheme-handler/chrome text/html \
                       application/xhtml+xml", k, /[ \t\n]+/)
        }
        # Drop every pre-existing web-handler line, wherever it sits.
        { for (i = 1; i <= n; i++) if (index($0, k[i] "=") == 1) next }
        /^\[Default Applications\]/ {
            print; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop"; d = 1; next
        }
        /^\[Added Associations\]/ {
            print; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop;"; a = 1; next
        }
        { print }
        END {
            if (!d) { print "[Default Applications]"; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop" }
            if (!a) { print ""; print "[Added Associations]"; for (i = 1; i <= n; i++) print k[i] "=firefox.desktop;" }
        }
    ' "${f}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${f}" 2>/dev/null \
        || { rm -f "${tmp}" 2>/dev/null; warn "default browser: could not update ${f}"; return 0; }
    chmod 644 "${f}" 2>/dev/null || true
}
# KDE keeps its OWN default-browser key in kdeglobals ([General]
# BrowserApplication) and several KDE apps consult it before mimeapps.list, so a
# stale value there would win over everything above. Rewrite it when present;
# when the key is absent (the case on a current ISO) KDE falls back to
# mimeapps.list, which is already correct, so there is nothing to add.
set_kde_browser() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    grep -qE '^BrowserApplication=' "${f}" || return 0
    grep -qx 'BrowserApplication=firefox.desktop' "${f}" && return 0
    sed -i -E 's#^BrowserApplication=.*$#BrowserApplication=firefox.desktop#' "${f}" 2>/dev/null \
        || warn "default browser: could not update ${f}"
}
